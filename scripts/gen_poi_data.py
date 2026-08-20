#!/usr/bin/env python3
"""Bake poi_raw.json building data into MinidoracatMiniMapPOIData.lua.

Reads the flat building list in poi_raw.json v2 ({building_id, rooms:
[{name, level, rects: [[x, y, w, h], ...]}, ...], x, y, width, height,
level}, world square coordinates, per-room geometry) and the room->category
mapping in MinidoracatMiniMapPOICategories.lua, then emits ONE POI entry per
building: the dominant category per CATEGORY_PRIORITY, carrying that
category's trigger-room rects individually, largest first (v3 per-room
rects, 2026-08-06) -- the icon anchors at the largest coalesced rect (the
actual pharmacy corner of a mall, not the mall's centroid) and block mode draws
each room rect. Level does not gate CLASSIFICATION (gate math counts all
floors' area), but the drawn rects keep only the dominant level -- see
build_entries.

Each entry also carries the whole-building bbox as `b` -- the union of the
x/y/width/height of every raw record grouped into that building -- letting the
client draw one outline per building instead of per room. It is NOT derivable
from the room rects: the trigger rooms of a mall can occupy one corner, so
their union AABB and the building bbox differ by dozens of squares. Entries
built from records without bbox fields (test fixtures) omit `b`.

Grouping is two-stage: identical bbox, then records sharing a same-named room
rect (one building's basement and ground floor are separate .lotheader records
whose bboxes usually differ by a few squares) -- see build_entries.

Output is deterministic: entries are sorted by (cat, rects, bbox), so
re-running with unchanged inputs produces a byte-identical file.

Usage:
    python scripts/gen_poi_data.py [--raw PATH] [--out PATH]
"""
import argparse
import json
import re
from pathlib import Path

REPO_ROOT = Path(__file__).resolve().parent.parent
SHARED_LUA_DIR = (
    REPO_ROOT
    / "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42"
    / "42/media/lua/shared"
)
DEFAULT_RAW = REPO_ROOT / "scripts/poi_raw.json"
DEFAULT_CATEGORIES_LUA = SHARED_LUA_DIR / "MinidoracatMiniMapPOICategories.lua"
DEFAULT_OUT = SHARED_LUA_DIR / "MinidoracatMiniMapPOIData.lua"

# 只擷取 nameKey + rooms（key、rooms 內容）。rooms 收尾的 `},` 之後允許任意欄位
# （如 color = { r, g, b }），故 regex 在 rooms 結束即停，不要求 entry 立即收合——
# 對 entry 內註解仍脆弱（見 CATEGORIES 檔頭警告），數量對不上時硬性失敗。
CATEGORY_BLOCK_RE = re.compile(
    r'(\w+)\s*=\s*\{\s*nameKey\s*=\s*"[^"]*",\s*rooms\s*=\s*\{([^}]*)\}\s*,',
)
ROOM_LITERAL_RE = re.compile(r'"([^"]+)"')

# MinidoracatMiniMapPOICategories.lua 定義 20 類（原 15，ranger 因全圖 0 筆資料於
# 0.8.0 移除；2026-08-06 新增 electronics/church 與 farm/industry/retail/food，見
# .omc/research/2026-08-05-poi-category-gap-from-reset-tool.md）。CATEGORY_BLOCK_RE
# 對 entry 內註解很脆弱（曾在 military/medical 整類靜默消失），數量對不上時硬性失敗
# 好過生出漏類別的資料。未來合法新增/移除類別時，改這個常數即可。
EXPECTED_CATEGORY_COUNT = 20


def parse_categories(categories_lua_path):
    """Return an ordered list of (category_key, frozenset(room_names))."""
    text = categories_lua_path.read_text(encoding="utf-8")
    categories = []
    for match in CATEGORY_BLOCK_RE.finditer(text):
        key = match.group(1)
        rooms = frozenset(ROOM_LITERAL_RE.findall(match.group(2)))
        categories.append((key, rooms))
    if len(categories) != EXPECTED_CATEGORY_COUNT:
        print(
            f"WARNING: parsed {len(categories)} categories from "
            f"{categories_lua_path.name}, expected {EXPECTED_CATEGORY_COUNT}. "
            f"CATEGORY_BLOCK_RE likely dropped an entry (e.g. an inline "
            f"comment inside the entry). If a category was legitimately "
            f"added/removed, update EXPECTED_CATEGORY_COUNT in gen_poi_data.py."
        )
    assert len(categories) == EXPECTED_CATEGORY_COUNT, (
        f"parse_categories found {len(categories)} categories, expected "
        f"{EXPECTED_CATEGORY_COUNT}"
    )
    return categories


# 主身分優先級鏈：一棟建築命中多類時只取最前面的一類（dominant category）。
# 動機：附屬房間造成語意噪音與同心疊圖標——警局的拘留室(prisoncells)不是監獄、
# 監獄的圖書室不是書店、學校的保健室(medical)不是診所。越「專屬/稀有」的身分
# 越優先；school 排在 medical 前（學校常含保健室，醫院不會含教室）、police 排在
# prison 前（拘留室在警局內；真監獄無 police 房間，仍歸 prison）。
# 已知取捨：優先級只去重「同棟內的多類房間」，不跨棟去重——同園區的母樓與
# 獨立附屬棟（如監獄園區、校園）各自成 entry，bbox 巢狀/鄰近時圖標會近距重疊。
# 尾端七項的順序是實測約束（poi_raw.json 逐棟 counterfactual：把該類降到對手之後，
# 數 dominant 歸屬改變的棟數；2026-08-06 量測，2026-08-06 依 review 校正口徑）：
#   electronics/church 在六新類最前——不從原 14 類接手建物（與 storage 的交疊
#     實測 2/0 棟且皆被 military/medical 更早接走，零位移）；
#   church 在 food 前（降級後 1 棟含 cafeteriakitchen 的教堂會錯標為 food）；
#   electronics 在 retail 前（交集 9 棟，其中 5 棟靠此順序維持 electronics、
#     餘 4 棟本就由更早類別接走；沿既有出貨行為）；
#   industry 在 retail 前（7 棟工廠附設直售店爭議 6:1 定案）；
#   retail 在 food 前（降級後 41 棟因餐飲寄生錯標為 food——超市熟食櫃、
#     書店咖啡廳同理；兩類 room 交集共 86 棟）；
#   storage 墊到最後——warehouse/storageunit 建物含 farm/food/industry/retail
#     房間時屬主身分修正（研究文件情境 A/D 的既定設計，實測 10 棟）。
CATEGORY_PRIORITY = [
    "military", "police", "prison", "fire", "school", "pharmacy", "medical",
    "gunstore", "grocery", "gas", "outdoor", "tools", "books",
    "electronics", "church", "farm", "industry", "retail", "food", "storage",
]
_PRIORITY_INDEX = {key: i for i, key in enumerate(CATEGORY_PRIORITY)}

# 附屬型觸發房（v2 房間級規則，2026-08-06）：這些 room 是「設施的附屬空間」，
# 也大量出現在公寓/商場/場館等其他身分的建物裡。主身分候選的觸發房「全部」屬
# 此清單時，其房間面積須佔建物房間總面積 >= ACCESSORY_MIN_SHARE 才成立，否則
# 落給下一個命中類別（可能落到無 → 整棟不標）。實錘案例（poi_raw.json 實算）：
#   (10051,12613) 公寓 64sq storageunit（0.8%）標倉儲——玩家回報；
#   (15325,2842) Louisville 商場 130sq prisoncells（0.3%）標監獄；
#   (12900,1244)/(12550,1511) 兩棟場館因 schoolstorage 標學校。
# 商店型觸發房（pharmacy/gunstore/armysurplus 等）刻意不設門檻：公寓一樓的
# 12sq 藥局是真藥局、商場裡的軍品店是真店面——房間級錨定後圖標釘在店面位置，
# 小佔比反而是 feature。真設施不受影響（U-Store It 的 storageunit、真監獄的
# prisoncells、真學校的 schoolstorage 佔比皆遠高於門檻）。
# 該豁免在商業區成立，在住宅區不成立——見下方 HOUSE_* 住宅門檻。
ACCESSORY_ROOMS = frozenset({
    "storageunit", "warehouse",
    "prisoncells", "cells", "prisonstorage", "prisonlaundry",
    "prisonerbelongings", "prisonlocker", "prisonarmory", "prisonlibrary",
    "contraband",
    "schoolstorage", "schoolgymstorage", "universitystorage",
    "gymstorage", "sportstorage",
})
# 門檻分母＝建物全部房間面積（含 empty/hall 等未分類填充房與無名房），故門檻
# 偏保守；敏感度實測 8%→10% 翻 2 棟、10%→12% 翻 3 棟，非過擬合魔數。已知貼線
# 案例：(2511,14059) 住宅的 storageunit 佔 10.65%，恰在 accept 側 0.65pp。
ACCESSORY_MIN_SHARE = 0.10

# 住宅門檻（2026-08-14，玩家回報 (6724,5447) 民宅標超市、(10091,8257) 民宅標
# 餐飲後的根本修）：官方在獨棟民宅裡放 2-40sq 的 grocerystorage/medicaloffice/
# butcher/library/bar/gunstore 是「讓那個角落刷對應 loot」的刻意設計（三者在
# Distributions.lua 都有完整 loot 表），不是建圖失誤；但把整棟民宅升格成超市/
# 醫療/餐飲身分對導航是誤導。故商店型觸發房的免門檻豁免在「這棟明顯是住家」
# 時撤銷：建物房間總面積 <= HOUSE_MAX_ROOM_AREA 且臥室佔比 >=
# HOUSE_MIN_BEDROOM_SHARE 且觸發房佔比 < ACCESSORY_MIN_SHARE → 落給下一候選。
# 三條件缺一不可（poi_raw.json 9254 棟實算的 counterfactual）：
#   缺總面積條件 → 誤殺 14 棟真設施，全是「臥室是宿舍不是民宅」的機構型建物：
#     (5522,12407) March Ridge 地下軍事地堡（bedroom 1146sq 是軍營寢室，
#     armystorage 91sq）、(2168,5737)/(13054,1993) 兩棟療養院、(8072,11522)
#     診所+商店+住宅混合樓（medical 系 214sq）、(12767,1810) Louisville 大樓等。
#   缺臥室條件 → 誤殺 7 棟店住混合的真店面（(7235,8162)/(7251,8183)/
#     (12301,1325)/(3810,12303) 等槍店、(12612,1868) 藥局）。
#   缺佔比條件 → 誤殺小坪數真店面（(1978,8581) 53sq 建物裡 24sq 餐飲＝45%
#     佔比的路邊小吃、(2672,6311) 52sq 建物裡 16sq 服飾店）。
# 斷點依實測落點而非猜測：總面積排序在 761sq（(13610,2833) 民宅裡 3sq
# clothesstore）與 815sq（(11891,6872) 77sq 真書店、樓上住人）之間自然分離，
# 取 800 居中；臥室 10% 與住宅觸發房佔比皆沿用 ACCESSORY_MIN_SHARE 同一水位，
# 不引入第三、第四個魔數——兩道 gate 問的是同一件事「佔比太小不足以定義身分」。
# ⚠ 代價是耦合：調 ACCESSORY_MIN_SHARE 會連動住宅政策（codex review 指出）。
# 兩者需要分頭調整時再拆成獨立常數，屆時務必重跑下方 counterfactual。
# 三個門檻值都是 corpus-derived heuristic，不是不變量——poi_raw.json 隨官方
# 地圖更新後應重跑；決策錨點由 test_house_gate_real_corpus_decisions_if_raw_present
# 鎖住（實測對 800→900、臥室條件放寬、門檻關閉等 mutation 皆會失敗）。
# 效果：25 棟改判——23 棟民宅退場（grocery 7/retail 5/gunstore 3/medical 3/
# books 2/food 2/electronics 1，其中 6 棟 grocery 與 5 棟 clothesstore 分別是
# (6065..6753,5321..5473) 與 Louisville (13288..13610,1821..2833) 的同批 lot
# 範本群聚，玩家在那兩區會連續踩到），另 2 棟是主身分修正的額外收穫：
# (5894,5374) 182sq generalstore 雜貨行原被 30sq clothesstore 搶標 retail、
# (426,9816) 181sq 服飾店原被 14sq toolstore 搶標 tools，門檻擋掉小房間後
# 翻回真身分。
# 已知取捨：退場的 23 棟裡那些小房間仍會刷 loot，玩家路過搜刮仍有收穫，只是
# 不再值得為它專程導航——POI 是「值得專程去的地點」而非「所有有物資的櫃子」。
HOUSE_ROOMS = frozenset({"bedroom", "kidsbedroom"})
HOUSE_MAX_ROOM_AREA = 800
HOUSE_MIN_BEDROOM_SHARE = 0.10


def _coalesce(rects):
    """Merge exactly-adjacent same-row / same-column rects until stable.

    同層樓的房間彼此不重疊，教室一整排、倉儲一整條可以無損合併成大矩形——
    區塊模式少掉內部格線、矩形數大減（渲染每矩形 ~13 次 Kahlua→Java 呼叫）。
    只合併「完全貼齊」的鄰接（同 y/h 且 x 相接，或同 x/w 且 y 相接），輸出
    幾何覆蓋範圍與輸入嚴格相等。"""
    rects = sorted(set(rects))
    changed = True
    while changed:
        changed = False
        rects.sort(key=lambda r: (r[1], r[3], r[0]))
        out = []
        for r in rects:
            p = out[-1] if out else None
            if p and p[1] == r[1] and p[3] == r[3] and p[0] + p[2] == r[0]:
                out[-1] = (p[0], p[1], p[2] + r[2], p[3])
                changed = True
            else:
                out.append(r)
        rects = out
        rects.sort(key=lambda r: (r[0], r[2], r[1]))
        out = []
        for r in rects:
            p = out[-1] if out else None
            if p and p[0] == r[0] and p[2] == r[2] and p[1] + p[3] == r[1]:
                out[-1] = (p[0], p[1], p[2], p[3] + r[3])
                changed = True
            else:
                out.append(r)
        rects = out
    return rects


def group_records(raw_buildings):
    """Return (groups, group_order): raw records grouped into one physical
    building each. Split out of build_entries so the invariant test exercises
    the production grouping instead of a copy of it.

    分組必須在分類「之前」完成：分開分類會讓同類對任意保留先到的較差錨點、
    異類對輸出跨樓層雙圖標（codex review 實錘一棟 12x27 掛 storage+food 兩筆），
    且附屬房面積門檻的分母只看到半棟。合併後一棟物理建築恰做一次
    gate/priority/anchor。無外框欄位的紀錄（測試 fixture）各自成組。
    """
    # 第一道：整棟外框（bbox）完全相同的紀錄直接同組
    groups = {}
    group_order = []
    for i, building in enumerate(raw_buildings):
        if all(k in building for k in ("x", "y", "width", "height")):
            gkey = (building["x"], building["y"], building["width"], building["height"])
        else:
            gkey = ("#", i)
        if gkey not in groups:
            groups[gkey] = []
            group_order.append(gkey)
        groups[gkey].append(building)
    # 第二道合併（2026-08-13）：精確 bbox 相等只抓到 bbox 完全一致的樓層對；同一棟
    # 的地下／地上紀錄 bbox 常差幾格（實測 Louisville 警局 (6078,5233,12,32) 對
    # (6077,5236,14,29)），漏網後畫成兩個套疊外框＋兩顆圖標，跨類別時還會同棟掛兩個
    # 不同類別（books+grocery、medical+pharmacy、grocery+gunstore、food+tools 共 4 例）。
    #
    # 判據＝兩筆紀錄有**同名房間共享任一完全相同的 rect**（同名＋同座標同尺寸的
    # 方格）。論證：rect 是世界座標的實體地面，兩棟不同建築的房間不可能佔據同一格，
    # 故同名同座標 rect ⟹ 同位置的垂直堆疊 ⟹ .lotheader 的同一棟多 level 紀錄。
    # 刻意「任一片」而非「整個房間形狀相同」：同一房間在不同樓層形狀本就不同
    # （警局 policehall 地下 [[6080,5249,8,3],[6080,5252,3,8]] vs 地上
    # [[6078,5249,6,3],[6080,5252,3,8]]，只有第二片相同），要求全等會漏掉真同棟；
    # 只共享一片的典型形狀是樓梯／出入口那一格（商場 28_32_2 地下室與 28_32_35
    # 本體共享 hall [7249,8256,5,1]）。
    # 不變式（test_shared_room_merge_pairs_are_cross_level_overlaps 逐組鎖住）：
    # 本道實測全 corpus 命中 17 組，每一組的成員兩兩 bbox 相交且 level 各異
    # （-1/0、-2/0），零例外；反向的 60 對「bbox 相交但 level 相同」真·相鄰建築
    # 零共享 rect。該測試另鎖總組數 27（＝第一道 10＋本道 17）——變異驗證顯示
    # 光靠不變式擋不住過寬的 key（key 拿掉房名會併成 43 組，每組仍滿足不變式）。
    # 刻意不用 bbox 相交或 IoU 閾值：相交會把大樓與其內獨立記錄的小店鋪合併，
    # IoU 在 0.5-0.9 區間同棟與相鄰排屋混雜、找不到乾淨切點。
    parent = {k: k for k in group_order}

    def _find(k):
        while parent[k] != k:
            parent[k] = parent[parent[k]]
            k = parent[k]
        return k

    room_owner = {}
    for gkey in group_order:
        for building in groups[gkey]:
            for room in building.get("rooms") or ():
                name = room.get("name")
                if not name:
                    continue
                for rect in room.get("rects") or ():
                    rk = (name, tuple(rect))
                    prev = room_owner.get(rk)
                    if prev is None:
                        room_owner[rk] = gkey
                    else:
                        ra, rb = _find(prev), _find(gkey)
                        if ra != rb:
                            parent[rb] = ra
    if any(parent[k] != k for k in group_order):
        merged, merged_order = {}, []
        for gkey in group_order:
            root = _find(gkey)
            if root not in merged:
                merged[root] = []
                merged_order.append(root)
            merged[root].extend(groups[gkey])
        groups, group_order = merged, merged_order
    return groups, group_order


def build_entries(raw_buildings, categories):
    """Return (entries, stats, dup_count).

    每棟建築依 CATEGORY_PRIORITY 產出至多一個主身分條目；觸發房全屬
    ACCESSORY_ROOMS 且面積佔比低於 ACCESSORY_MIN_SHARE 的候選被跳過、
    落給下一個命中類別。條目帶主身分觸發房的逐矩形清單（主樓層過濾＋
    相鄰合併＋面積大→小，rects[0] 為圖標錨點；非整棟外框），另帶
    bbox＝整棟外框（該組所有紀錄的 bbox 聯集；無外框欄位的紀錄為 None）。
    stats maps category_key -> unique hit count (post-dedup).
    dup_count＝同一棟的多筆 building 紀錄被合併數（bbox 相等或共享相同座標房間）
    ＋(cat, rects, bbox) 全等的保險去重數。
    """
    seen = {}
    stats = {key: 0 for key, _ in categories}
    catmap = dict(categories)
    groups, group_order = group_records(raw_buildings)
    dup_count = sum(len(g) - 1 for g in groups.values())

    for gkey in group_order:
        name_rects = {}
        total_area = 0
        # 整棟外框＝該組所有紀錄的 bbox 聯集（第二道合併後 root 的 gkey 只涵蓋其中
        # 一筆；警局案例地下室往西多 1 格、地上往南多 3 格，取聯集才框得住整棟）
        bounds = None
        for building in groups[gkey]:
            if all(k in building for k in ("x", "y", "width", "height")):
                x0, y0 = building["x"], building["y"]
                x1, y1 = x0 + building["width"], y0 + building["height"]
                bounds = (x0, y0, x1, y1) if bounds is None else (
                    min(bounds[0], x0), min(bounds[1], y0),
                    max(bounds[2], x1), max(bounds[3], y1))
            for room in building.get("rooms") or ():
                rects = room.get("rects") or ()
                # 面積先進分母（含無名房——「建物全部房間面積」的契約；
                # corpus 實有 1 間 name="" 的房），名稱才決定可否參與分類
                total_area += sum(w * h for _, _, w, h in rects)
                name = room.get("name")
                if not name:
                    continue
                lv = room.get("level", 0)
                name_rects.setdefault(name, []).extend(
                    (lv, tuple(r)) for r in rects)
        room_set = set(name_rects)
        if not room_set:
            continue
        matched = [key for key, rooms in categories if room_set & rooms]
        matched.sort(key=lambda k: _PRIORITY_INDEX.get(k, len(CATEGORY_PRIORITY)))
        key = None
        pairs = None
        bedroom_area = sum(
            r[2] * r[3] for n in room_set & HOUSE_ROOMS for _, r in name_rects[n])
        is_house = bool(
            total_area
            and total_area <= HOUSE_MAX_ROOM_AREA
            and bedroom_area / total_area >= HOUSE_MIN_BEDROOM_SHARE)
        for cand in matched:
            trig = room_set & catmap[cand]
            cat_area = sum(
                r[2] * r[3] for n in trig for _, r in name_rects[n])
            if trig <= ACCESSORY_ROOMS:
                # 無面積資訊時附屬型候選不得通過（fail closed）
                if not total_area:
                    continue
                if cat_area / total_area < ACCESSORY_MIN_SHARE:
                    continue
            elif is_house and cat_area / total_area < ACCESSORY_MIN_SHARE:
                # 住宅門檻：民宅角落的小型設施房不足以定義整棟身分
                continue
            cand_pairs = [p for n in trig for p in name_rects[n]]
            # 觸發房無幾何＝無從錨定，同樣落給下一候選（與 gate 語意一致）
            if not cand_pairs:
                continue
            key = cand
            pairs = cand_pairs
            break
        if key is None or pairs is None:
            continue
        # 主樓層過濾：同類房間跨樓層在 2D 投影整片重疊（三層餐廳的二樓用餐區
        # 疊在一樓正上方→區塊疊色、框線層疊），取該類面積最大的樓層（平手取
        # 最低層＝偏地面）；同層房間物理上互不重疊，重疊就此消除。
        # gate 的面積佔比仍計全樓層（上方），只有「畫什麼」取主樓層。
        by_level = {}
        for lv, r in pairs:
            by_level.setdefault(lv, []).append(r)
        best = min(by_level,
                   key=lambda lv: (-sum(r[2] * r[3] for r in by_level[lv]), lv))
        # 相鄰合併後按面積大→小排序（r[1] 是圖標/名稱錨點——最大房間永遠
        # 落在實體房間裡，比聯集框中心準）
        uniq = sorted(_coalesce(by_level[best]),
                      key=lambda r: (-(r[2] * r[3]), r[0], r[1], r[2], r[3]))
        # 跨組保險去重：物理去重已由上方的整棟合併完成，這裡只擋「不同建物
        # 但 (cat, 矩形集) 完全相同」的極端巧合，維持輸出唯一性
        # bbox＝該組 bbox 聯集；無外框欄位的紀錄（測試 fixture）為 None，客戶端整棟
        # 模式對缺 b 的條目自動退回逐房間矩形
        bbox = (bounds[0], bounds[1], bounds[2] - bounds[0],
                bounds[3] - bounds[1]) if bounds else None
        # 地下條目（B42 basement）：畫的主樓層在地下＝地上看不到這個設施
        # （2026-08-20 玩家回報「普通民宅有 food 圖示」＝West Point 民宅的地下
        # 酒吧 28_32_0，corpus 有 113 棟 basement-only、62 筆入 POI 且多為高價值
        # loot——不剔除、改標注：圖標角標＋搜尋後綴由消費端處理）
        underground = best < 0
        # 保險去重的身分含 bbox：兩棟不同建築若 (cat, 房間矩形) 恰好全等，少了 bbox
        # 會靜默併成一筆並丟掉另一棟的外框（codex review 指出；現 corpus 未撞到）
        dedup_key = (key, tuple(uniq), bbox, underground)
        if dedup_key in seen:
            dup_count += 1
            continue
        seen[dedup_key] = {"cat": key, "rects": uniq, "bbox": bbox,
                           "underground": underground}
        stats[key] += 1
    entries = list(seen.values())
    # key 含完整矩形清單＋bbox＝全序（只取 r[1] 座標有 6 筆同鍵、順序會隨 raw 列序
    # 漂移；bbox 同進 dedup 身分後也必須同進排序鍵，否則同 (cat,rects) 異 bbox 的
    # 兩筆順序不定，破壞 byte-identical 重生）。None（fixture）排在有值者之前
    entries.sort(key=lambda e: (e["cat"], tuple(e["rects"]), e["bbox"] or (),
                                e["underground"]))
    return entries, stats, dup_count


def render_lua(entries, raw_count, gen_command):
    lines = [
        "-- MinidoracatMiniMapPOIData.lua",
        "-- 由 scripts/gen_poi_data.py 產生，請勿手動編輯。重新分類請改",
        "-- MinidoracatMiniMapPOICategories.lua 後重新執行：",
        f"--   {gen_command}",
        "--",
        f"-- 來源：poi_raw.json（{raw_count} 筆建築原始資料，世界 square 座標）。",
        "-- 消費契約見 MinidoracatMiniMapPOI.lua buildPoiConverted()（v3 逐房間矩形）：",
        "-- 陣列，每項 { cat=<CATEGORIES 類別 key>, rn=<矩形數>, r={ {x,y,w,h},.. },",
        "-- b={x,y,w,h}|nil, u=1|nil }（世界 square 座標，x/y 左上角、w/h 尺寸；",
        "-- r 按面積大→小排序，r[1] 為圖標/名稱錨點；b＝整棟建築外框，「整棟外框」",
        "-- 顯示模式用，非 r 的聯集——大型建物的分類房間可能只佔一角，兩者可差",
        "-- 數十格；u=1＝地下條目（B42 basement，主分類房的主樓層在地下——圖標角標",
        "-- ／搜尋後綴／匯出 u 欄由消費端處理，僅地下時輸出）。",
        "-- 迭代一律用 rn（Kahlua # 不可信）；count 為除錯輔助欄位。",
        "",
        "MinidoracatMiniMapPOIData = {",
    ]
    for e in entries:
        parts = ", ".join(
            f"{{ x = {x}, y = {y}, w = {w}, h = {h} }}"
            for x, y, w, h in e["rects"])
        bbox = e.get("bbox")
        b = ""
        if bbox:
            b = (f", b = {{ x = {bbox[0]}, y = {bbox[1]}, "
                 f"w = {bbox[2]}, h = {bbox[3]} }}")
        if e.get("underground"):
            b += ", u = 1"
        lines.append(
            f'    {{ cat = "{e["cat"]}", rn = {len(e["rects"])}, '
            f'r = {{ {parts} }}{b} }},'
        )
    lines.append("}")
    lines.append("")
    lines.append(f"MinidoracatMiniMapPOIData.count = {len(entries)}")
    lines.append("")
    return "\n".join(lines)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--raw", type=Path, default=DEFAULT_RAW, help="poi_raw.json path")
    parser.add_argument("--out", type=Path, default=DEFAULT_OUT, help="output .lua path")
    args = parser.parse_args()

    if not args.raw.exists():
        parser.error(
            f"raw building data not found: {args.raw}\n"
            f"Pass --raw <path> pointing at the exported poi_raw.json (flat "
            f"building list; see module docstring), or place the file at "
            f"{DEFAULT_RAW}."
        )

    raw_buildings = json.loads(args.raw.read_text(encoding="utf-8"))
    categories = parse_categories(DEFAULT_CATEGORIES_LUA)
    missing = {key for key, _ in categories} - set(CATEGORY_PRIORITY)
    assert not missing, f"CATEGORY_PRIORITY missing keys: {missing}"
    entries, stats, dup_count = build_entries(raw_buildings, categories)

    gen_command = "python scripts/gen_poi_data.py"
    lua_text = render_lua(entries, len(raw_buildings), gen_command)
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with args.out.open("w", encoding="utf-8", newline="\n") as f:
        f.write(lua_text)

    print(f"raw buildings: {len(raw_buildings)}")
    print(f"poi entries:   {len(entries)} ({dup_count} duplicate rows dropped)")
    print(f"output:        {args.out}")
    print("category hits:")
    zero_hit = []
    for key, _ in categories:
        count = stats[key]
        print(f"  {key:10s} {count}")
        if count == 0:
            zero_hit.append(key)
    if zero_hit:
        print(f"zero-hit categories: {', '.join(zero_hit)}")
    else:
        print("zero-hit categories: (none)")


if __name__ == "__main__":
    main()
