-- 自訂道路編碼回歸：shared/MinidoracatMiniMap_RoadCodec.lua 的檔案往返、壞檔分類、驗證邊界與封包。
-- 用法：lua scripts/test_road_codec.lua
local path = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/shared/"
    .. "MinidoracatMiniMap_RoadCodec.lua"
local env = setmetatable({}, { __index = _G })
assert(loadfile(path, "t", env))()
local C = assert(env.MinidoracatMiniMapRoadCodec)

local function eq(a, b, why) assert(a == b, why .. ": " .. tostring(a) .. " != " .. tostring(b)) end
-- over 裡值為 false 的 id／sid＝拿掉（pairs 看不到 nil）
local function road(over)
    local r = { id = "r1", name = "Back\tlane %25\nx", source = "draw", enabled = true, rev = 3,
        pts = { 10668.5, 9700, 10690, 9662.5, -3.5, 9640 }, segWidth = { 4, 16 }, segSurface = { "dirt", "paved" },
        ends = { "snap", "free" }, share = { faction = true, safehouse = false }, sid = "s41" }
    for k, v in pairs(over or {}) do r[k] = v end
    if r.id == false then r.id = nil end
    if r.sid == false then r.sid = nil end
    return r
end
local function lines(text)
    local out, n = {}, 0
    for line in (text .. "\n"):gmatch("([^\n]*)\n") do n = n + 1; out[n] = line end
    return out, n
end
local function decode(text, tag) local l, n = lines(text); return C.decodeStore(l, n, tag) end
local function sameRoad(a, b, why)
    for _, k in ipairs({ "id", "sid", "author", "name", "source", "enabled", "rev" }) do eq(a[k], b[k], why .. " " .. k) end
    for i = 1, 6 do eq(a.pts[i], b.pts[i], why .. " pts") end
    for i = 1, 2 do
        eq(a.segWidth[i], b.segWidth[i], why .. " w"); eq(a.segSurface[i], b.segSurface[i], why .. " s")
        eq(a.ends[i], b.ends[i], why .. " ends")
    end
    eq(a.share.faction, b.share.faction, why .. " faction"); eq(a.share.safehouse, b.share.safehouse, why .. " safehouse")
end

-- 檔案往返（名稱含 tab／換行／%，座標含半格與負數）＋ OFF 行
local store = { nextId = 5, count = 2, roads = { road(), road({ id = "r4", sid = false, enabled = false,
    share = { faction = false, safehouse = false }, name = "B" }) }, offCount = 1, off = { "s77" } }
local text = C.encodeStore(store)
assert(text:find("10668.5,9700,10690,9662.5,-3.5,9640", 1, true), "座標自己格式化（不印 .0）: " .. text)
assert(not text:find("%.0[,\n\t]"), "整數不印 .0")
local back = assert(decode(text))
eq(back.count, 2, "往返筆數"); eq(back.nextId, 5, "往返 nextId")
sameRoad(back.roads[1], store.roads[1], "往返 1"); sameRoad(back.roads[2], store.roads[2], "往返 2")
eq(back.offCount, 1, "OFF 筆數"); eq(back.off[1], "s77", "OFF sid")
eq(C.encodeStore(back), text, "再編碼逐位元相同")

-- 壞檔分類
local function bad(t, why, reason, tag)
    local s, err = decode(t, tag); eq(s, nil, why); eq(err, reason or "invalid", why)
end
-- 改檔一處（斷言真的改到，免得測到原檔）
local function mut(pat, rep)
    local out, hits = text:gsub(pat, rep, 1)
    eq(hits, 1, "改到 " .. pat)
    return out
end
local body = mut("\nEND\t2$", "")
bad(body, "缺 END")
bad(body .. "\nEND\t1", "END 筆數不符")
bad(mut("\nW\t4,16\n", "\nW\t4\n"), "段數不符")
bad(mut("\nW\t4,16\n", "\nW\t4,17\n"), "路寬 17")
bad(mut("\nW\t4,16\n", "\nW\t2,16\n"), "路寬 2")
bad(mut("10668%.5", "10668.25"), "非 0.5 格座標")
bad(mut("10668%.5", "1e3"), "科學記號")
bad(mut("Back%%09lane", string.rep("x", 129)), "名稱過長")
bad(mut("\tdirt,paved", "\tdirt,mud"), "未知路面")
bad(mut("^MMROADS\t1\t5", "MMROADS\t1\t4"), "id 不小於 nextId")
bad(mut("\tr4\t", "\tr1\t"), "id 重複")
bad(mut("PTS\t10668%.5,9700,10690,9662%.5", "PTS\t10690,9662.5,10690,9662.5"), "零長度段")
bad("", "空檔")
bad("MMROADS\t2\t9\nWHATEVER", "版本較新", "unsupported")
bad(text, "客戶端檔當伺服器檔讀", "invalid", C.SERVER_TAG)
-- 2–300 點
local function pts(n) local t = {} for i = 1, n do t[2 * i - 1], t[2 * i] = i, 0 end return t end
local function segs(n, v) local t = {} for i = 1, n do t[i] = v end return t end
local function sized(n) return road({ pts = pts(n), segWidth = segs(n - 1, 4), segSurface = segs(n - 1, "dirt") }) end
assert(C.validateRoad(sized(2)), "2 點可存"); assert(C.validateRoad(sized(300)), "300 点可存")
eq(C.validateRoad(sized(1)), false, "1 點拒收"); eq(C.validateRoad(sized(301)), false, "301 點拒收")
eq(C.validateRoad(road({ pts = { 0, 0, 1, 0 / 0, 2, 2 } })), false, "NaN 座標拒收")
eq(C.validateRoad(road({ pts = { 0, 0, 1, math.huge, 2, 2 } })), false, "無限座標拒收")
eq(C.validateRoad(road({ name = " B" })), false, "未清理名稱拒收")
eq(C.validateRoad(road({ id = false, sid = false })), false, "沒有 id 也沒有 sid")
eq(C.validateRoad(road({ rev = 0 })), false, "rev 0")

-- 伺服器檔：多作者，每筆要有 sid 與 author，sid 號碼 < nextId
local srv = { nextId = 42, count = 2, roads = { road({ author = "alice" }), road({ id = "r1", sid = "s7", author = "bob" }) },
    offCount = 0, off = {} }
local stext = C.encodeStore(srv, C.SERVER_TAG)
local sback = assert(C.decodeStore(select(1, lines(stext)), select(2, lines(stext)), C.SERVER_TAG))
eq(sback.roads[1].author, "alice", "伺服器作者 1"); eq(sback.roads[2].author, "bob", "伺服器作者 2")
eq(sback.roads[2].id, "r1", "lid 留在 id")
eq(decode(stext), nil, "伺服器檔當客戶端檔讀")
eq(decode(stext:gsub("\talice\t", "\t\t"), C.SERVER_TAG), nil, "伺服器檔缺作者")

-- 來源碼與 DROP：客戶端檔頭帶來源碼、DROP 行往返；伺服器檔的 id 是「來源碼:r編號」
local cstore = { nextId = 5, origin = "a1b2c3d4e5f6", count = 1, roads = { road() }, offCount = 0, off = {},
    dropCount = 2, drops = { "s3", "s9" } }
local ctext = C.encodeStore(cstore)
local cback = assert(decode(ctext))
eq(cback.origin, "a1b2c3d4e5f6", "檔頭來源碼往返"); eq(cback.dropCount, 2, "DROP 筆數"); eq(cback.drops[2], "s9", "DROP sid")
eq(C.encodeStore(cback), ctext, "帶來源碼與 DROP 再編碼相同")
local function sub1(s, pat, rep) local out, hits = s:gsub(pat, rep, 1); eq(hits, 1, "改到 " .. pat); return out end
eq(decode(sub1(ctext, "a1b2c3d4e5f6", "xyz")), nil, "壞來源碼")
eq(decode(sub1(ctext, "\nDROP\ts9", "\nDROP\ts3")), nil, "DROP 重複")
eq(decode(sub1(ctext, "\tr1\t", "\ta1b2c3d4e5f6:r1\t")), nil, "客戶端路不能自帶來源碼")
eq(decode(sub1(stext, "^MMROADSRV\t1\t42", "MMROADSRV\t1\t42\ta1b2c3d4e5f6"), C.SERVER_TAG), nil, "伺服器檔頭不帶來源碼")
local osrv = { nextId = 42, count = 2, roads = { road({ author = "alice", origin = "aaaaaaaa" }),
    road({ author = "alice", origin = "bbbbbbbb", sid = "s8" }) }, offCount = 0, off = {} }
local otext = C.encodeStore(osrv, C.SERVER_TAG)
assert(otext:find("\taaaaaaaa:r1\t", 1, true), "伺服器檔存 lid")
local oback = assert(C.decodeStore(select(1, lines(otext)), select(2, lines(otext)), C.SERVER_TAG))
eq(oback.roads[1].id, "r1", "lid 拆回 id"); eq(oback.roads[2].origin, "bbbbbbbb", "lid 拆回來源碼")
eq(C.lid(oback.roads[1]), "aaaaaaaa:r1", "lid 組回")
local ow = C.toWire(road({ origin = "a1b2c3d4" }))
eq(ow.id, "a1b2c3d4:r1", "wire id＝lid")
local ob = assert(C.fromWire(ow))
eq(ob.id, "r1", "fromWire 拆 id"); eq(ob.origin, "a1b2c3d4", "fromWire 拆來源碼")
ow.id = "zz:r1"
eq((C.fromWire(ow)), nil, "壞 lid 拒收")
eq(C.backupPath("a/b_p0.txt"), "a/b_p0.bak.txt", "備份檔名保持 .txt（getFileWriter 副檔名白名單）")

-- 封包往返與惡意封包
local wire = C.toWire(road({ author = "alice" }))
for k, v in pairs(wire) do eq(type(v), "string", "wire 欄位是字串 " .. k) end
sameRoad(assert(C.fromWire(wire)), road({ author = "alice" }), "wire 往返")
local function evil(over, why)
    local w = C.toWire(road())
    for k, v in pairs(over) do w[k] = v end
    eq((C.fromWire(w)), nil, why)
end
evil({ extra = "x" }, "多欄")
evil({ rev = 3 }, "非字串欄")
evil({ pts = "1,2,3,x,5,6" }, "非數字座標")
evil({ pts = "1,2,,4,5,6" }, "空座標")
evil({ pts = "0x10,2,3,4,5,6" }, "十六進位")
evil({ w = "4,4,4" }, "段數不符")
local many = C.toWire(sized(300)); many.pts = many.pts .. ",301,0"; many.w = many.w .. ",4"; many.s = many.s .. ",dirt"
eq((C.fromWire(many)), nil, "超點數")
eq((C.fromWire("road")), nil, "不是表")

-- 檔名轉義（收藏檔沿用）
eq(C.fileKey("a/b\\c..d%"), "a%2fb%5cc.%2ed%25", "fileKey")
print("test_road_codec: ok")
