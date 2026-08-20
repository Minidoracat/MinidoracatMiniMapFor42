#!/usr/bin/env python3
"""烘焙官方街道英文原名表（搜尋雙語用）。

動機（2026-08-20 使用者回報「搜 will 無結果」）：LangFor42 等翻譯 MOD 是
「整份取代」官方 streets.xml（跳過官方英文檔、載自己的中文檔）——引擎
runtime 只有譯名物件、無原名欄（WorldMapStreet 僅 translatedText 一欄，
WorldMapStreetsXML.parseStreet 直塞 name attr）。原名唯一可靠來源＝官方
安裝目錄的 streets.xml，但 runtime 讀遊戲目錄的 Lua 入口（getGameFilesTextInput）
非 debug 環境回 null——故走家族 POIData 同款生成期烘焙。

輸出：42/media/lua/shared/MinidoracatMiniMapStreetNames.lua
  MinidoracatMiniMapStreetNames = { { n="Oak St", l="oak st", x=10961, y=6635 }, ... }
  n＝顯示名、l＝預小寫（搜尋端零 runtime lower 成本）、x/y＝首點 floor
  （與 NavRoute 引擎索引同源座標，_Search 以首點精確鍵去重）。

用法：python scripts/gen_street_names.py
PZ 更新後重跑（來源檔隨 build 變動；EXPECTED_MIN 擋空檔/格式漂移）。
"""
import io
import os
import re
import sys

SRC = r"D:/SteamLibrary/steamapps/common/ProjectZomboid/media/maps/Muldraugh, KY/streets.xml"
DST = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "MOD", "MinidoracatMiniMapFor42", "Contents", "mods", "MinidoracatMiniMapFor42",
    "42", "media", "lua", "shared", "MinidoracatMiniMapStreetNames.lua")
EXPECTED_MIN = 1000  # 42.20.3 實測 1098 條；低於此＝來源檔異常，拒絕生成

STREET_RE = re.compile(r'<street name="([^"]*)"[^>]*>(.*?)</street>', re.S)
POINT_RE = re.compile(r'<point x="([0-9.\-]+)" y="([0-9.\-]+)"')


def lua_quote(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def main() -> int:
    with io.open(SRC, "r", encoding="utf-8") as f:
        xml = f.read()
    rows = []
    for name, body in STREET_RE.findall(xml):
        m = POINT_RE.search(body)
        if not m or not name.strip():
            continue
        # 非 ASCII 名（來源被翻譯檔污染）直接拒生成：本表的意義就是英文原名
        if any(ord(c) > 127 for c in name):
            print(f"non-ascii street name in source: {name!r}", file=sys.stderr)
            return 1
        x, y = int(float(m.group(1))), int(float(m.group(2)))
        rows.append((name, name.lower(), x, y))
    if len(rows) < EXPECTED_MIN:
        print(f"only {len(rows)} streets parsed (< {EXPECTED_MIN}), refuse to write",
              file=sys.stderr)
        return 1
    out = io.StringIO()
    out.write("-- MinidoracatMiniMapStreetNames.lua（生成檔，勿手編）\n")
    out.write("-- 由 scripts/gen_street_names.py 烘焙自官方 Muldraugh, KY/streets.xml：\n")
    out.write("-- 搜尋雙語用英文原名表（翻譯 MOD 整份取代後 runtime 無原名，緣由見\n")
    out.write("-- 生成器 docstring）。n=顯示名 l=預小寫 x/y=首點（與引擎索引同源）。\n")
    out.write(f"-- 來源 {len(rows)} 條；PZ 更新後重跑生成器。\n")
    out.write("MinidoracatMiniMapStreetNames = {\n")
    for name, low, x, y in rows:
        out.write("    { n = %s, l = %s, x = %d, y = %d },\n"
                  % (lua_quote(name), lua_quote(low), x, y))
    out.write("}\n")
    data = out.getvalue().encode("utf-8")
    with open(DST, "wb") as f:
        f.write(data)
    print(f"wrote {DST} ({len(rows)} streets, {len(data)} bytes)")
    return 0


if __name__ == "__main__":
    sys.exit(main())
