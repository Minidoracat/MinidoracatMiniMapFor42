import importlib.util
from pathlib import Path

import pytest


SCRIPT = Path(__file__).parents[1] / "analyze_client_profile.py"
SPEC = importlib.util.spec_from_file_location("client_profile", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def write_header(path, names):
    path.write_text("KeyNamesTable\nIndex,Name\n" + "\n".join(
        f"{index},{name}" for index, name in enumerate(names)) + "\n", encoding="utf-8")


def make_fixture(root):
    prefix = "fixture"
    main_header = root / f"{prefix}_GameProfiler_MainThread_header.csv"
    render_header = root / f"{prefix}_GameProfiler_main_header.csv"
    write_header(main_header, ["GameWindow.frameStep", "Render ISMiniMapOuter",
                               "Render ISWorldMap", "Lua - OnRenderTick", "Lua - OnTick",
                               "Lua - OnKeyPressed"])
    write_header(render_header, ["RenderThread.renderStep", "Wait"])

    main_rows = []
    render_rows = []
    map_frame = int(MODULE.MAP_OPEN_S * 60)
    for frame in range(3300):
        groups = [(0, 0, 20000), (3, 2, 100), (4, 4, 500)]
        if frame < map_frame:
            groups.append((1, 5, 60000))
        elif frame < 3000:
            groups.append((2, 5, 30000))
        if frame == map_frame:
            groups.append((5, 3, 150))  # 合法輪必有的按鍵：M 本尊（錨幀、窗尾後）
        main_rows.append(str(frame) + "," + ",".join(
            f"{key},{depth},0,{length}" for key, depth, length in groups))
        render_rows.append(f"{frame},0,0,0,50000,1,3,0,10")
    split = 1650
    for suffix, start, end in (("0000", 0, split), ("0001", split, 3300)):
        (root / f"{prefix}_GameProfiler_MainThread_times_{suffix}.csv").write_text(
            "\n".join(main_rows[start:end]) + "\n", encoding="utf-8")
        (root / f"{prefix}_GameProfiler_main_times_{suffix}.csv").write_text(
            "\n".join(render_rows[start:end]) + "\n", encoding="utf-8")


def test_session_without_any_keypress_fails_closed(tmp_path):
    """整場零 OnKeyPressed＝非 SOP 錄製（腳本必按 M/Escape/W）；header 有名
    不代表事件發生過，必須 fail。"""
    make_fixture(tmp_path)
    for segment in tmp_path.glob("*_GameProfiler_MainThread_times_*.csv"):
        text = segment.read_text(encoding="utf-8")
        segment.write_text(text.replace(",5,3,0,150", ""), encoding="utf-8")

    with pytest.raises(ValueError, match="no Lua - OnKeyPressed"):
        MODULE.analyze(tmp_path)


def test_analyze_fixed_contract(tmp_path, capsys):
    make_fixture(tmp_path)

    MODULE.analyze(tmp_path)

    output = capsys.readouterr().out
    assert "fps≈60" in output
    assert "ISMiniMapOuter n=2478 nzMed=6.000ms" in output
    assert "RenderThread active whole-session n=3300 mean=4.999" in output
    assert "stand       n=1500 mean=2.000" in output
    assert "wmap-active n=522 mean=2.000" in output


def test_standing_window_keypress_fails_closed(tmp_path):
    """站立窗（M 錨前 2..27 秒）內出現 OnKeyPressed＝錄製污染，必須 fail。
    實測踩過：錨前雜按鍵讓 fps 估計看似合法（20-1000 內）實則全錯。"""
    make_fixture(tmp_path)
    first = next(tmp_path.glob("*_GameProfiler_MainThread_times_0000.csv"))
    lines = first.read_text(encoding="utf-8").splitlines()
    # fixture fps=60、map_frame=2478：stand 窗=frame 858..2358；frame 1000 在窗內
    lines[1000] = lines[1000] + ",5,3,0,200"
    first.write_text("\n".join(lines) + "\n", encoding="utf-8")

    with pytest.raises(ValueError, match="stand window contaminated"):
        MODULE.analyze(tmp_path)


def test_keypress_outside_standing_window_is_ignored(tmp_path, capsys):
    """錨後（世界地圖操作段）的按鍵屬正常操作，不得誤傷。"""
    make_fixture(tmp_path)
    second = next(tmp_path.glob("*_GameProfiler_MainThread_times_0001.csv"))
    lines = second.read_text(encoding="utf-8").splitlines()
    lines[-1] = lines[-1] + ",5,3,0,200"
    second.write_text("\n".join(lines) + "\n", encoding="utf-8")

    MODULE.analyze(tmp_path)

    assert "stand       n=1500 mean=2.000" in capsys.readouterr().out


def test_zero_length_keypress_still_contaminates(tmp_path):
    """解析器接受 length=0 的合法 span；零長度 OnKeyPressed 事件同屬污染，不得繞過。"""
    make_fixture(tmp_path)
    first = next(tmp_path.glob("*_GameProfiler_MainThread_times_0000.csv"))
    lines = first.read_text(encoding="utf-8").splitlines()
    lines[1000] = lines[1000] + ",5,3,0,0"
    first.write_text("\n".join(lines) + "\n", encoding="utf-8")

    with pytest.raises(ValueError, match="stand window contaminated"):
        MODULE.analyze(tmp_path)


def test_missing_segment_fails_closed(tmp_path):
    """收割缺 segment（如 _times_0000 遺失）＝截斷錄製：起點位移會讓 fps 估計
    看似合法（實測反例 (2478-1650)/41.3≈20.05 恰過下限），必須 fail。"""
    make_fixture(tmp_path)
    next(tmp_path.glob("*_GameProfiler_MainThread_times_0000.csv")).unlink()

    with pytest.raises(ValueError, match="segment sequence broken"):
        MODULE.analyze(tmp_path)


def test_frame_gap_fails_closed(tmp_path):
    """segment 檔內缺行（frame 序列出現缺口）＝錄製截斷，必須 fail。
    實據：真實錄製 frame 嚴格連續（Z'/Zpp3 兩輪 gaps=0）。"""
    make_fixture(tmp_path)
    first = next(tmp_path.glob("*_GameProfiler_MainThread_times_0000.csv"))
    lines = first.read_text(encoding="utf-8").splitlines()
    del lines[500]
    first.write_text("\n".join(lines) + "\n", encoding="utf-8")

    with pytest.raises(ValueError, match="frame sequence has gaps"):
        MODULE.analyze(tmp_path)


def test_malformed_segment_fails_closed(tmp_path):
    make_fixture(tmp_path)
    segment = next(tmp_path.glob("*_GameProfiler_MainThread_times_0000.csv"))
    segment.write_text("0,0,0,0\n", encoding="utf-8")

    with pytest.raises(ValueError, match="malformed span row"):
        MODULE.analyze(tmp_path)


def test_worldmap_active_uses_only_frames_with_span(tmp_path, capsys):
    make_fixture(tmp_path)

    MODULE.analyze(tmp_path)

    assert "wmap-active n=522" in capsys.readouterr().out


def test_missing_worldmap_frames_fails_closed(tmp_path):
    make_fixture(tmp_path)
    for segment in tmp_path.glob("*_GameProfiler_MainThread_times_*.csv"):
        text = segment.read_text(encoding="utf-8")
        segment.write_text(text.replace(",2,5,0,30000", ""), encoding="utf-8")

    with pytest.raises(ValueError, match="no frame carries Render ISWorldMap"):
        MODULE.analyze(tmp_path)


def test_duplicate_frame_across_segments_fails_closed(tmp_path):
    make_fixture(tmp_path)
    first = next(tmp_path.glob("*_GameProfiler_MainThread_times_0000.csv"))
    second = next(tmp_path.glob("*_GameProfiler_MainThread_times_0001.csv"))
    duplicate = first.read_text(encoding="utf-8").splitlines()[0]
    second.write_text(second.read_text(encoding="utf-8") + duplicate + "\n", encoding="utf-8")

    with pytest.raises(ValueError, match="duplicate frame"):
        MODULE.analyze(tmp_path)


def test_missing_keypress_span_name_fails_closed(tmp_path):
    """header 缺 Lua - OnKeyPressed 名時污染守衛會靜默 no-op——必須 fail-closed
    （合法錄製必有按鍵，該 span 必註冊）。"""
    make_fixture(tmp_path)
    header = next(tmp_path.glob("*_GameProfiler_MainThread_header.csv"))
    text = header.read_text(encoding="utf-8").replace("5,Lua - OnKeyPressed\n", "")
    header.write_text(text, encoding="utf-8")

    with pytest.raises(ValueError, match="missing required spans.*keypress"):
        MODULE.analyze(tmp_path)


def test_render_thread_frame_gap_allowed(tmp_path, capsys):
    """RenderThread 天生跳號（實據：Z'/Zpp3 range >> 行數），不得誤殺。"""
    make_fixture(tmp_path)
    segment = next(tmp_path.glob("*_GameProfiler_main_times_0000.csv"))
    lines = segment.read_text(encoding="utf-8").splitlines()
    del lines[500]
    segment.write_text("\n".join(lines) + "\n", encoding="utf-8")

    MODULE.analyze(tmp_path)

    assert "RenderThread active whole-session n=3299" in capsys.readouterr().out


def test_multiple_render_roots_accumulate(tmp_path, capsys):
    """同 frame 多個 depth-0 renderStep＝多 render pass，屬合法格式
    （實據：Z' 輪 frame 19892）；成本累加、不得誤殺。"""
    make_fixture(tmp_path)
    segment = next(tmp_path.glob("*_GameProfiler_main_times_0000.csv"))
    lines = segment.read_text(encoding="utf-8").splitlines()
    lines[10] = lines[10] + ",0,0,0,50000"
    segment.write_text("\n".join(lines) + "\n", encoding="utf-8")

    MODULE.analyze(tmp_path)

    # 3300 frame 之一多了 5ms root：mean 5.0 + 5/3300 ≈ 5.0015 → .3f 格式 5.002
    assert "RenderThread root   whole-session n=3300 mean=5.002" in capsys.readouterr().out


def test_batch_failure_returns_nonzero(tmp_path):
    assert MODULE.main([str(tmp_path / "missing")]) == 1


def test_percentile_matches_linear_interpolation():
    assert MODULE.percentile([0, 10], 0.95) == pytest.approx(9.5)

if __name__ == "__main__":
    # repo 守衛慣例是 `python scripts/tests/<file>.py` 直跑（見 test_kahlua_globals.py、
    # AGENTS.md 守衛呼叫式）；本檔依賴 pytest fixtures，直跑委派 pytest 以免靜默零斷言。
    raise SystemExit(pytest.main([__file__, "-q"]))

