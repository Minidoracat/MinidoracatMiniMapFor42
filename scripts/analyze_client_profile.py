#!/usr/bin/env python3
"""分析固定 client GameProfiler A/B 錄製。

操作契約：開錄後站立 40 秒，約 t+41.3 秒按 M 開世界地圖。GameProfiler
`*_times.csv` 的 StartTime 是 frame 內相對偏移，不能建立 wall-clock 時間軸；
因此用 `(首個 Render ISWorldMap frame - 錄製首 frame) / 41.3s` 估站立段 fps。

輸出兩個可審計的 MainThread 窗：
- stand：M 錨前 2..27 秒，避開開錄與按鍵轉場。窗內出現任何 `Lua - OnKeyPressed`
  即 fail（站立段應零按鍵；有按鍵＝錄製污染，數字不可信——實測踩過：錨前雜
  按鍵讓 fps 估計看似合法實則全錯）。
- wmap-active：所有確實含 `Render ISWorldMap` span 的 frames；不推測 Escape/移動段。

另輸出同 UUID RenderThread 的 root、Wait、active=root-Wait 全 session 分布，
只作跨執行緒佐證，不拿來做 phase 差分。CSV、必要 span、UUID 與本工具追蹤的
span depth 任何不符都 fail-closed；批次目錄逐一報錯，任一失敗以非零碼結束。

交叉驗證：將本腳本列出的確切 `*_MainThread_header.csv` 傳給
`pz-performance-profiling/scripts/analyze_profile.py`；whole-session 的
GameWindow.frameStep 次數/中位與 Render ISMiniMapOuter 次數/非零中位必須一致。

用法：
  python scripts/analyze_client_profile.py <錄製目錄1> [<錄製目錄2> ...]
每個目錄必須只含一個 session UUID 的 main/MainThread GameProfiler CSV。
"""
import csv
import statistics
import sys
from pathlib import Path

MAP_OPEN_S = 41.3
MAIN_WANT = {
    "GameWindow.frameStep": "frame",
    "Render ISMiniMapOuter": "minimap",  # B 輪可缺：原版未建立小地圖 UI
    "Render ISWorldMap": "worldmap",
    "Lua - OnKeyPressed": "keypress",  # 站立窗污染檢查用；stand 窗內出現即 fail
    "Lua - OnRenderTick": "onrender",
    "Lua - OnTick": "ontick",
}
# keypress 必列（LaneClaude 抓漏）：合法錄製必有按鍵（M/Escape/W）→ header 必註冊
# 該 span；缺名時污染守衛會靜默 no-op（fail-open），故列 REQUIRED。
MAIN_REQUIRED = {"frame", "worldmap", "keypress", "onrender", "ontick"}
RENDER_WANT = {"RenderThread.renderStep": "root", "Wait": "wait"}


def percentile(values, q):
    ordered = sorted(values)
    if not ordered:
        return float("nan")
    if len(ordered) == 1:
        return ordered[0]
    pos = q * (len(ordered) - 1)
    low = int(pos)
    high = min(low + 1, len(ordered) - 1)
    return ordered[low] + (ordered[high] - ordered[low]) * (pos - low)


def _headers(directory):
    main_threads = list(directory.glob("*_GameProfiler_MainThread_header.csv"))
    renders = list(directory.glob("*_GameProfiler_main_header.csv"))
    if len(main_threads) != 1 or len(renders) != 1:
        raise ValueError(
            f"{directory}: expected one MainThread and one render header, "
            f"got {len(main_threads)} and {len(renders)}")
    main_thread = main_threads[0]
    prefix = main_thread.name[: -len("_GameProfiler_MainThread_header.csv")]
    expected_render = directory / f"{prefix}_GameProfiler_main_header.csv"
    if renders[0] != expected_render:
        raise ValueError(f"{directory}: main/MainThread UUID mismatch")
    return main_thread, expected_render


def _span_names(header):
    names = {}
    in_table = False
    for line in header.read_text(encoding="utf-8", errors="strict").splitlines():
        if line.strip() == "KeyNamesTable":
            in_table = True
            continue
        if not in_table or not line or line == "Index,Name":
            continue
        index, sep, name = line.partition(",")
        if sep and index.isdigit():
            names[index] = name
    if not names:
        raise ValueError(f"{header}: missing KeyNamesTable")
    return names


def _groups(header, contiguous):
    stem = header.name[: -len("_header.csv")]
    segments = sorted(header.parent.glob(f"{stem}_times_[0-9][0-9][0-9][0-9].csv"))
    if not segments:
        raise ValueError(f"{header.parent}: no span segment files for {stem}")
    for expected, segment in enumerate(segments):
        if segment.name != f"{stem}_times_{expected:04d}.csv":
            raise ValueError(
                f"{header.parent}: segment sequence broken at {segment.name} "
                f"(expected _times_{expected:04d}) — 錄製收割不完整")
    seen_frames = set()
    for segment in segments:
        with segment.open(encoding="utf-8", errors="strict", newline="") as fh:
            reader = csv.reader(fh, strict=True)
            for row in reader:
                if len(row) < 5 or (len(row) - 1) % 4:
                    raise ValueError(f"{segment}:{reader.line_num}: malformed span row")
                try:
                    frame = int(row[0])
                    groups = [(row[i], int(row[i + 1]), int(row[i + 2]), int(row[i + 3]))
                              for i in range(1, len(row), 4)]
                    for key, depth, start, length in groups:
                        int(key)
                        if depth < 0 or start < 0 or length < 0:
                            raise ValueError
                except ValueError as exc:
                    raise ValueError(f"{segment}:{reader.line_num}: invalid span field") from exc
                if frame in seen_frames:
                    raise ValueError(f"{segment}:{reader.line_num}: duplicate frame {frame}")
                seen_frames.add(frame)
                yield frame, groups
    if not seen_frames:
        raise ValueError(f"{header}: no frames in any segment")
    ordered = sorted(seen_frames)
    # frame 連續性只適用 MainThread（實據：Z'/Zpp3 兩輪 gaps=0）；RenderThread
    # 天生跳號（同兩輪 range >> 行數），由呼叫端關閉。
    if contiguous and ordered[-1] - ordered[0] + 1 != len(ordered):
        raise ValueError(
            f"{header}: frame sequence has gaps "
            f"({ordered[0]}..{ordered[-1]} spans {ordered[-1] - ordered[0] + 1}, "
            f"got {len(ordered)}) — 錄製截斷或缺行")


def _load_main(header):
    names = _span_names(header)
    keys = {index: MAIN_WANT[name] for index, name in names.items() if name in MAIN_WANT}
    missing = MAIN_REQUIRED - set(keys.values())
    if missing:
        raise ValueError(f"{header}: missing required spans {sorted(missing)}")
    frames = {}
    for frame, groups in _groups(header, contiguous=True):
        costs = {}
        counts = {}
        for key, depth, _start, length in groups:
            tag = keys.get(key)
            if not tag:
                continue
            counts[tag] = counts.get(tag, 0) + 1
            if tag == "frame":
                if depth != 0 or counts[tag] > 1:
                    raise ValueError(f"{header}: invalid frameStep at frame {frame}")
            elif depth <= 0:
                raise ValueError(f"{header}: {tag} at frame {frame} is outside frameStep")
            costs[tag] = costs.get(tag, 0.0) + length / 10000.0
        if counts.get("frame") != 1:
            raise ValueError(f"{header}: frame {frame} has no frameStep")
        frames[frame] = costs
    if not frames:
        raise ValueError(f"{header}: no frames")
    return frames


def _load_render(header):
    names = _span_names(header)
    keys = {index: RENDER_WANT[name] for index, name in names.items() if name in RENDER_WANT}
    if set(keys.values()) != set(RENDER_WANT.values()):
        raise ValueError(f"{header}: missing render root or Wait span")
    frames = []
    for frame, groups in _groups(header, contiguous=False):
        costs = {"root": 0.0, "wait": 0.0}
        root_count = 0
        for key, depth, _start, length in groups:
            tag = keys.get(key)
            if not tag:
                continue
            if tag == "root":
                # 同 frame 多個 depth-0 renderStep＝多 render pass，屬合法格式
                # （實據：Z' 輪 frame 19892），成本累加；只驗 depth 與至少一個。
                root_count += 1
                if depth != 0:
                    raise ValueError(f"{header}: invalid render root at frame {frame}")
            elif depth <= 0:
                raise ValueError(f"{header}: Wait at frame {frame} is outside render root")
            costs[tag] += length / 10000.0
        if root_count == 0 or costs["root"] <= 0:
            raise ValueError(f"{header}: frame {frame} has no render root cost")
        if costs["wait"] > costs["root"]:
            raise ValueError(f"{header}: frame {frame} Wait exceeds render root")
        costs["active"] = costs["root"] - costs["wait"]
        frames.append(costs)
    if not frames:
        raise ValueError(f"{header}: no render frames")
    return frames


def _summary(values):
    return (f"n={len(values)} mean={statistics.fmean(values):.3f} "
            f"med={statistics.median(values):.3f} p95={percentile(values, 0.95):.3f} "
            f"max={max(values):.3f}ms")


def _phase(name, frames, selected):
    if not selected:
        raise ValueError(f"{name}: empty phase")
    count = len(selected)
    values = [frames[frame]["frame"] for frame in selected]
    amort = lambda tag: sum(frames[frame].get(tag, 0.0) for frame in selected) / count
    mini = [frames[frame]["minimap"] for frame in selected if frames[frame].get("minimap", 0) > 0]
    print(f"  {name:11} {_summary(values)} | mini amort={amort('minimap'):.3f} "
          f"rate={len(mini)/count:.2f} nzMed={statistics.median(mini) if mini else 0:.2f} | "
          f"wm amort={amort('worldmap'):.2f} | onRender={amort('onrender'):.4f} "
          f"onTick={amort('ontick'):.4f}")


def analyze(directory):
    main_header, render_header = _headers(directory)
    frames = _load_main(main_header)
    render = _load_render(render_header)
    ordered = sorted(frames)
    worldmap = [frame for frame in ordered if frames[frame].get("worldmap", 0) > 0]
    if not worldmap:
        raise ValueError(f"{directory}: no frame carries Render ISWorldMap")
    first_map = worldmap[0]
    fps = (first_map - ordered[0]) / MAP_OPEN_S
    if not 20 <= fps <= 1000:
        raise ValueError(f"{directory}: implausible standing fps estimate {fps:.3f}")
    seconds = lambda value: int(value * fps)
    standing = [frame for frame in ordered
                if first_map - seconds(27) <= frame < first_map - seconds(2)]
    # 按鍵事件閘（presence 用 "in" 而非成本>0：解析器接受 length=0 的合法 span）：
    # (1) 合法 SOP 輪必有按鍵（M/Escape/W 是腳本一部分）——整場零 OnKeyPressed
    #     ＝非 SOP 錄製；header 有名只代表 span 有註冊，不代表該場真的發生過。
    # (2) 首個按鍵必須落在 stand 窗尾之後——涵蓋開錄起點到窗尾的全段（含窗前
    #     0..14s 與窗內），任何早於此的按鍵＝站立段污染（實測踩過：錨前雜按鍵
    #     讓 fps 估計看似合法實則全錯）。
    keyed = [frame for frame in ordered if "keypress" in frames[frame]]
    if not keyed:
        raise ValueError(
            f"{directory}: no Lua - OnKeyPressed event in entire session — "
            f"錄製無按鍵事件，非 SOP 合法輪")
    stand_end = first_map - seconds(2)
    if keyed[0] < stand_end:
        raise ValueError(
            f"{directory}: stand window contaminated — first OnKeyPressed at "
            f"frame {keyed[0]}, before stand-window end {stand_end}（站立段有按鍵，錄製作廢）")

    whole_frames = [frames[frame]["frame"] for frame in ordered]
    whole_mini = [frames[frame]["minimap"] for frame in ordered
                  if frames[frame].get("minimap", 0) > 0]
    print(f"\n== {directory.name}  MainThread={main_header.name}  fps≈{fps:.0f}")
    print(f"   whole frame {_summary(whole_frames)}; "
          f"ISMiniMapOuter n={len(whole_mini)} "
          f"nzMed={statistics.median(whole_mini) if whole_mini else 0:.3f}ms")
    for tag in ("root", "wait", "active"):
        print(f"   RenderThread {tag:6} whole-session {_summary([item[tag] for item in render])}")
    _phase("stand", frames, standing)
    _phase("wmap-active", frames, worldmap)


def main(arguments):
    if not arguments:
        print(__doc__, file=sys.stderr)
        return 2
    failed = False
    for argument in arguments:
        try:
            analyze(Path(argument))
        except (OSError, ValueError, csv.Error) as exc:
            failed = True
            print(f"ERROR: {exc}", file=sys.stderr)
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
