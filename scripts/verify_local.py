# -*- coding: utf-8 -*-
"""MiniMap 專屬檢查：scripts/verify_mod.py（家族模板副本）第 19 項會呼叫；單獨跑 `python scripts/verify_local.py`。
2026-11-26 verify_mod.py 換成家族模板時，從舊副本原樣搬來模板沒有的檢查：
  - RoadPatch approval freshness — 生成的 MinidoracatMiniMapRoadPatches.lua 記的 approvals／generator／本體 sha256
    要和目前的 road_patch_approvals.json、gen_road_patches.py 一致；`--self-test-road-patch-freshness` 自驗
  - Lua 離線單元測試 — 缺 lua 時列 SKIP 而非 PASS（SKIP＝這條防線根本沒跑到）
  - Python 路網稽核／道路交叉檢查／停車場判定規則測試 — 要求 `<腳本>: OK` sentinel
"""
import hashlib
import os
import re
import shutil
import subprocess
import sys
import tempfile

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

passed, failed, skipped = [], [], []


def ok(label):
    passed.append(label)
    print(f"  PASS  {label}")


def fail(label, details=None):
    # 不讀 verify_ignore.txt，verify_mod.py 第 19 項也不對本檔輸出套用豁免：要豁免就在本檔處理
    details = details or []
    failed.append(label)
    print(f"  FAIL  {label}")
    for d in details:
        print(f"        {d}")


def skip(label, why):
    skipped.append(label)
    print(f"  SKIP  {label} — {why}")


def find_media():
    hits = []
    mod_root = os.path.join(REPO, "MOD")
    if os.path.isdir(mod_root):
        for folder in os.listdir(mod_root):
            p = os.path.join(mod_root, folder, "Contents", "mods")
            if not os.path.isdir(p):
                continue
            for inner in os.listdir(p):
                media = os.path.join(p, inner, "42", "media")
                if os.path.isdir(media):
                    hits.append(media)
    return hits


def iter_files(root, exts):
    for base, dirs, files in os.walk(root):
        dirs[:] = [d for d in dirs if d not in (".git",)]
        for name in files:
            if os.path.splitext(name)[1] in exts:
                yield os.path.join(base, name)


def road_patch_freshness(repo, lua_files):
    approval_files, generator_files = [], []
    for root_name in ("scripts", "MOD"):
        root = os.path.join(repo, root_name)
        if not os.path.isdir(root):
            continue
        for base, dirs, files in os.walk(root):
            dirs[:] = [d for d in dirs if d not in (".git", ".omc", "__pycache__")]
            for name in files:
                path = os.path.join(base, name)
                if name == "road_patch_approvals.json":
                    approval_files.append(path)
                if name == "gen_road_patches.py":
                    generator_files.append(path)
    generated = [f for f in lua_files
                 if os.path.basename(f) == "MinidoracatMiniMapRoadPatches.lua"]
    bad = []
    for label, files in (
        ("generated RoadPatch Lua", generated),
        ("road_patch_approvals.json", approval_files),
        ("gen_road_patches.py", generator_files),
    ):
        if len(files) != 1:
            bad.append(f"expected exactly 1 {label}, found {len(files)}")
    if bad:
        return bad
    with open(approval_files[0], "rb") as fh:
        approval_sha = hashlib.sha256(fh.read()).hexdigest()
    with open(generator_files[0], "rb") as fh:
        generator_sha = hashlib.sha256(fh.read()).hexdigest()
    with open(generated[0], encoding="utf-8") as fh:
        text = fh.read()
    approval_values = re.findall(r'approvalsSha256\s*=\s*"([0-9a-f]{64})"', text)
    generator_values = re.findall(r'generatorSha256\s*=\s*"([0-9a-f]{64})"', text)
    body_values = re.findall(
        r"^-- generated-body-sha256: ([0-9a-f]{64})$", text, re.MULTILINE
    )
    if len(approval_values) != 1 or approval_values[0] != approval_sha:
        bad.append("generated RoadPatch approvalsSha256 missing/duplicate/stale")
    if len(generator_values) != 1 or generator_values[0] != generator_sha:
        bad.append("generated RoadPatch generatorSha256 missing/duplicate/stale")
    if len(body_values) != 1:
        bad.append("generated RoadPatch body hash stamp missing/duplicate")
    else:
        body = re.sub(
            r"^-- generated-body-sha256: [0-9a-f]{64}\n", "", text,
            count=1, flags=re.MULTILINE,
        )
        if hashlib.sha256(body.encode("utf-8")).hexdigest() != body_values[0]:
            bad.append("generated RoadPatch body hash stale; rerun gen_road_patches.py")
    return bad


def self_test_road_patch_freshness():
    with tempfile.TemporaryDirectory() as root:
        scripts = os.path.join(root, "scripts")
        lua_dir = os.path.join(root, "MOD", "x")
        os.makedirs(scripts)
        os.makedirs(lua_dir)
        approval = os.path.join(scripts, "road_patch_approvals.json")
        generator = os.path.join(scripts, "gen_road_patches.py")
        generated = os.path.join(lua_dir, "MinidoracatMiniMapRoadPatches.lua")
        with open(approval, "wb") as fh:
            fh.write(b"{}\\n")
        with open(generator, "wb") as fh:
            fh.write(b"# generator\\n")
        approval_sha = hashlib.sha256(b"{}\\n").hexdigest()
        generator_sha = hashlib.sha256(b"# generator\\n").hexdigest()
        def write_generated(a_sha=approval_sha, g_sha=generator_sha):
            body = ("MinidoracatMiniMapRoadPatches={"
                    f'approvalsSha256="{a_sha}",generatorSha256="{g_sha}"'
                    "}\n")
            body_sha = hashlib.sha256(body.encode("utf-8")).hexdigest()
            with open(generated, "w", encoding="utf-8") as fh:
                fh.write(f"-- generated-body-sha256: {body_sha}\n" + body)
        write_generated()
        assert not road_patch_freshness(root, [generated])
        with open(generated, "a", encoding="utf-8") as fh:
            fh.write(f'approvalsSha256="{approval_sha}"\\n')
        assert road_patch_freshness(root, [generated])
        write_generated()
        assert road_patch_freshness(root, [])
        duplicate = os.path.join(lua_dir, "duplicate", "road_patch_approvals.json")
        os.makedirs(os.path.dirname(duplicate))
        with open(duplicate, "wb") as fh:
            fh.write(b"{}\\n")
        assert road_patch_freshness(root, [generated])
        os.remove(duplicate)
        write_generated("0" * 64, generator_sha)
        assert road_patch_freshness(root, [generated])
        write_generated()
        with open(generated, "a", encoding="utf-8") as fh:
            fh.write("-- body modified\n")
        assert road_patch_freshness(root, [generated])
        write_generated()
        with open(generator, "ab") as fh:
            fh.write(b"# modified\\n")
        assert road_patch_freshness(root, [generated])
    print("verify_mod RoadPatch freshness self-test: OK")


if __name__ == "__main__" and "--self-test-road-patch-freshness" in sys.argv:
    self_test_road_patch_freshness()
    sys.exit(0)


MEDIA_DIRS = find_media()
if not MEDIA_DIRS:
    print("找不到 MOD/*/Contents/mods/*/42/media，中止")
    sys.exit(2)

LUA_FILES = [f for m in MEDIA_DIRS for f in iter_files(os.path.join(m, "lua"), {".lua"})
             if os.path.isdir(os.path.join(m, "lua"))]

# ---- 1c. RoadPatch approval freshness ----
approval_bad = road_patch_freshness(REPO, LUA_FILES)
fail("RoadPatch approval freshness", approval_bad) if approval_bad else ok("RoadPatch approval freshness")

# ---- Lua 單元測試 ----
# _Skin.lua 是家族 UI 框架的 thin adapter：test_skin_adapter.lua 驗四態，缺同層
# framework repo 時腳本自印 SKIP（SKIP＝防線沒跑到，不能列 PASS）。
# test_admin_policy.lua 抽整份 Policy 原檔、只換 PZ 全域為假物件，驗 Java 真相源
# 優先、缺鍵退 SCHEMA 預設（舊伺服器＝旁路 fail-closed）、三把鑰匙與旁路白名單；
# 這條是「顯示層政策」的回歸，不是防作弊。其餘為 addon 設定 API、Settings Studio
# 與跨模組 server/client 守衛。
_lua_bin = shutil.which("lua")
_lua_tests = [
    ("test_skin_adapter.lua", "皮膚 adapter 四態", True),
    ("test_addon_settings.lua", "addon 設定 API", False),
    ("test_settings_studio.lua", "Map Display Settings", False),
    ("test_admin_policy.lua", "管理員政策 facade", False),
    ("test_livestock_visibility.lua", "牲畜／安全屋 per-slot 顯示", False),
    ("test_player_export.lua", "玩家匯出 Policy 權威", False),
    ("test_server_nav_share.lua", "伺服器導航分享 never-bypass", False),
    ("test_admin_view_marker.lua", "ADMIN VIEW 標記與 fallback", False),
    ("test_player_coords.lua", "座標列避開世界地圖按鈕列", False),
    ("test_player_facing.lua", "自己的朝向箭頭：投影方向、坐車、閘門、靠邊", False),
    ("test_street_backfill.lua", "街道資料補載 gate", False),
    ("test_street_names.lua", "純名稱翻譯與原始道路不變", False),
    ("test_street_repairs.lua", "獨立修路／顯示抑制與語系一致性", False),
    ("test_street_supplements.lua", "addon 補充道路掛載／搜尋／導航／作者更新退場", False),
    ("test_search_logic.lua", "原名／譯名搜尋共用道路錨點", False),
    ("test_nav_kick.lua", "導航冷啟動與退化街道隔離", False),
    ("test_road_sources.lua", "官方副本來源認證、舊版官方幾何載體與實體地圖覆蓋", False),
    ("test_carrier_display.lua", "已知翻譯載體顯示窗口（統一漢化舊版街換 42.21 幾何）", False),
    ("test_nav_route.lua", "導航路網與街道覆蓋邊界", False),
    ("test_nav_api.lua", "導航 API 與路線快取", False),
    ("test_worldmap_nav.lua", "世界地圖右鍵選單合併／開圖重包", False),
    ("test_feature_gate.lua", "功能閘門 registerFeatureGate／featureAllowed", False),
    ("test_title_status.lua", "小地圖標題列狀態 registerTitleStatus", False),
    ("test_scan_listener.lua", "定時掃描更新通知 registerScanListener", False),
    ("test_zombie_floors.lua", "殭屍點別層變淡：取樣記樓層、畫時比地圖的玩家", False),
    ("test_npc_dots.lua", "殭屍點裡的 NPC 換色：登記規則、只讀選進來的點、每個 MOD 一色、勾選與沙盒閘門", False),
    ("test_heat_void.lua", "殭屍熱度：視野碰到沒有地圖資料的格子就關（防引擎閃退）", False),
    ("test_nav_gate.lua", "addon 導航閘門／繪製唯讀／目標查詢", False),
    ("test_itinerary.lua", "多站行程權威與 token 擁有權", False),
    ("test_places.lua", "家／收藏點與一鍵回家", False),
    ("test_cleared.lua", "資源點去過／已清空：帳號檔、去過、容器掃描預算、翻過、自動門檻、再走進去比對、單機重新生成", False),
    ("test_itinerary_ui.lua", "行程 UI 確認、錯誤提示與頁面切換", False),
    ("test_itinerary_routes.lua", "剩餘行程預覽與活動路線分層", False),
    ("test_fog_of_war.lua", "深霧／薄霧與多人已知區域修復", False),
    ("test_remote_symbols.lua", "其他玩家標記：存檔、兩張地圖同步、作者清單可見規則、右鍵隱藏、篩選配 TwisTonFire 手繪", False),
    ("test_markers.lua", "addon marker provider 依 slot 名單繪製", False),
    ("test_chunk_grid.lua", "chunk 格線對齊／編號範圍／縮放封頂／stencil 配對", False),
    ("test_recreate_zorder.lua", "小地圖重建維持 UI 疊放順序", False),
    ("test_minimap_layout.lua", "小地圖位置記憶：自建登記、拖曳放開就存、收合 y 換算、舊檔相容、重建帶過位置；沙盒沒開小地圖時進遊戲自動建", False),
    ("test_zone_render.lua", "zone／資源點繪製、圖標名稱提示、地圖文字縮放與圖例資料", False),
    ("test_map_bounds.lua", "MOD 地圖框線：顯示在兩格、伺服器沙盒、預設白、名稱在最上方頂點", False),
    ("test_mapdir_gate.lua", "地圖影像掛載：基底只在載入原版時掛、mapDir 逐圖閘門、疊層跟隨地圖優先序", False),
    ("test_key_migration.lua", "一次性選項遷移：滑條、圖片化、整棟、圖層分地圖、框線分兩張地圖", False),
    ("test_ghost_gate.lua", "穿透模式 gate 契約與 applyGhost 清理", False),
    ("test_layer_tail.lua", "圖層尾端守恆與掛載自癒", False),
    ("test_minimap_size.lua", "小地圖首建尺寸：自訂＞倍率＞原版、夾下限", False),
    ("test_toolbar_plan.lua", "小地圖按鈕列收納：放不下的收進「更多」、不溢出、不重複不遺漏", False),
    ("test_poi_export.lua", "資源點區塊 poi_blocks.json 匯出格式", False),
    ("test_steamid_report.lua", "Steam64 回報：暫時未就緒不放棄", False),
    ("test_room_resources.lua", "資源點兩種版本、房間資料分批掃描與公開查詢 API", False),
    ("test_map_legend.lua", "世界地圖資源點圖例版面與顯示", False),
    ("test_road_draw.lua", "自訂道路三款畫法、繪製預算不掉路、開關、stencil、預覽與圖例列", False),
    ("test_road_codec.lua", "自訂道路檔案格式、備份與讀回驗證", False),
    ("test_roads_store.lua", "自訂道路資料層：存、改、停用、收到的路", False),
    ("test_nav_custom_roads.lua", "自訂道路併進路網、選路與 6000 段建圖", False),
    ("test_road_tool.lua", "道路工具：畫線、編輯、存檔表單", False),
    ("test_road_record.lua", "錄製道路：取樣、路寬路面、簡化與切分", False),
    ("test_road_share.lua", "道路分享：伺服器保存、收件人、同步", False),
    ("test_sketch_codec.lua", "手繪線檔案與封包格式、上限、伺服器作者檔", False),
    ("test_sketch_store.lua", "手繪線資料層：背景載入、局部擦除、防抖寫檔", False),
    ("test_sketch_draw.lua", "手繪線繪製：拉遠隱藏、線寬、候選快取、預算不丟筆、stencil", False),
    ("test_sketch_tool.lua", "手繪工具：要筆、取點、直線、平移、復原重做、手把", False),
    ("test_sketch_share.lua", "手繪線分享：伺服器保存、收件人、對帳、快照跨 tick", False),
    ("test_cleared_share.lua", "已清空分享：收件人、作者檔與索引、重新生成與重置清單、刷新推送", False),
]
for _script, _label, _may_skip in _lua_tests:
    _gate = f"Lua 單元測試（{_script}：{_label}）"
    if not _lua_bin:
        skip(_gate, "PATH 沒有 lua")
        continue
    _r = subprocess.run([_lua_bin, f"scripts/{_script}"], capture_output=True, cwd=REPO)
    _lines = [l for l in (_r.stdout or b"").decode("utf-8", "replace").splitlines()
              if l.strip()]
    _err_tail = (_r.stderr or b"").decode("utf-8", "replace").splitlines()[-3:]
    if _r.returncode != 0:
        fail(_gate, [f"退出碼 {_r.returncode}"] + _lines[-3:] + _err_tail)
    elif _may_skip and _lines and _lines[0].startswith("SKIP"):
        skip(_gate, _lines[0])
    else:
        fail(_gate, ["無輸出"]) if not _lines else ok(f"{_gate}：{_lines[-1]}")

# ---- Python 路網稽核與交叉檢查契約、停車場判定規則 ----
for _script, _label in (
        ("test_audit_streets", "路網稽核契約"),
        ("test_xcheck_street_patches", "道路交叉檢查資料安全"),
        ("test_gen_parking", "停車場判定規則")):
    _gate = f"{_label}測試（{_script}.py）"
    _sentinel = f"{_script}: OK"
    _r = subprocess.run(
        [sys.executable, os.path.join("scripts", "tests", _script + ".py")],
        capture_output=True, text=True, cwd=REPO)
    _lines = [line for line in (_r.stdout or "").splitlines() if line.strip()]
    _err_tail = (_r.stderr or "").splitlines()[-3:]
    if _r.returncode != 0:
        fail(_gate, [f"退出碼 {_r.returncode}"] + _lines[-3:] + _err_tail)
    elif not _lines or _lines[-1] != _sentinel:
        fail(_gate, ["缺少預期 sentinel：%s" % _sentinel] + _lines[-3:])
    else:
        ok("%s：%s" % (_gate, _sentinel))

print()
print(f"PASS {len(passed)} / FAIL {len(failed)} / SKIP {len(skipped)}")
sys.exit(1 if failed else 0)
