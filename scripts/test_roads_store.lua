-- 自訂道路資料層回歸：真 RoadCodec＋真 _Roads.lua，驗存檔失敗不換記憶體、只讀檔拒寫、持久化、
-- 同 sid 合併遮罩、路網預算切點與 overBudget、停用／OFF、roadsAt、revision 單調。
-- 用法：lua scripts/test_roads_store.lua
local lua = "MOD/MinidoracatMiniMapFor42/Contents/mods/MinidoracatMiniMapFor42/42/media/lua/"
local function readFile(path)
    local f = assert(io.open(path, "rb")); local text = f:read("*a"); f:close(); return text
end
local sources = { readFile(lua .. "shared/MinidoracatMiniMap_RoadCodec.lua"),
    readFile(lua .. "client/MinidoracatMiniMap_Roads.lua") }
local PATH0 = "MinidoracatMiniMap/roads/Sandbox/Save1_p0.txt"

-- 假檔案系統同 test_places（LuaManager.java 語意）：broken＝檔在卻打不開；lossy＝寫入被吞掉；
-- lossyBak＝只有備份檔（.bak.txt）寫不進去
local function fixture(fs)
    fs = fs or { files = {}, broken = {}, lossy = false }
    local handlers, players = { OnCreatePlayer = {}, OnGameStart = {} }, {}
    local events = {}
    for name in pairs(handlers) do
        events[name] = { Add = function(fn) handlers[name][#handlers[name] + 1] = fn end }
    end
    local log = { nav = 0, put = {}, drop = {} }
    local core = { ready = true,
        navCustomRoadsChanged = function() log.nav = log.nav + 1 end,
        roadSharePut = function(pn, road) log.put[#log.put + 1] = { pn = pn, road = road } end,
        roadShareDrop = function(pn, sid) log.drop[#log.drop + 1] = { pn = pn, sid = sid } end }
    local env = setmetatable({ MinidoracatMiniMapCore = core, Events = events,
        getSpecificPlayer = function(pn) return players[pn] end,
        getTimestampMs = function() return 1700000000123 end,
        ZombRand = function() return 4660 end,
        getText = function(key, arg) if arg ~= nil then return key .. "|" .. tostring(arg) end return key end,
        getWorld = function()
            return { getGameMode = function() return "Sandbox" end, getWorld = function() return "Save1" end }
        end,
        cacheFileExists = function(path) return fs.files[path] ~= nil end,
        getFileReader = function(path)
            local text = fs.files[path]
            if path:find("..", 1, true) or fs.broken[path] or text == nil then return nil end
            local pos = 1
            return { close = function() end, readLine = function()
                if pos > #text then return nil end
                local nl = text:find("\n", pos, true) or #text + 1
                local line = text:sub(pos, nl - 1)
                pos = nl + 1
                return line
            end }
        end,
        getFileWriter = function(path)
            if path:find("..", 1, true) or not path:match("%.txt$") then return nil end
            fs.files[path] = ""
            local buf = {}
            return { write = function(_, s) buf[#buf + 1] = s end,
                close = function()
                    local lost = fs.lossy or (fs.lossyBak and path:match("%.bak%.txt$"))
                    fs.files[path] = lost and "" or table.concat(buf)
                end }
        end,
    }, { __index = _G })
    for i, source in ipairs(sources) do assert(load(source, "module" .. i, "t", env))() end
    local function player(pn)
        local p = {}
        function p:isDead() return self.dead == true end
        players[pn] = p
        for _, fn in ipairs(handlers.OnCreatePlayer) do fn(pn, p) end
        return p
    end
    return { core = core, fs = fs, log = log, player = player }
end
local function eq(a, b, why) assert(a == b, why .. ": " .. tostring(a) .. " != " .. tostring(b)) end
-- x0 起往東 segs 段的直路
local function road(x0, segs, over)
    local r = { pts = {}, segWidth = {}, segSurface = {}, ends = { "snap", "free" }, source = "draw" }
    for i = 0, segs do r.pts[2 * i + 1], r.pts[2 * i + 2] = x0 + i * 10, 100 end
    for i = 1, segs do r.segWidth[i], r.segSurface[i] = 4, "dirt" end
    for k, v in pairs(over or {}) do r[k] = v end
    return r
end
local function received(sid, x0, segs)
    return road(x0, segs, { sid = sid, author = "alice", name = "Shared " .. sid, rev = 1, enabled = true,
        share = { faction = true, safehouse = false } })
end

-- 新路配 id、預設名、rev；寫檔讀回；重開讀得到；revision 單調
do
    local t = fixture(); t.player(0)
    local C = t.core
    local r0 = C.roadsRevision()
    local ok, id = C.roadsSave(0, road(0, 2))
    assert(ok, "存檔成功"); eq(id, "r1", "第一條 id")
    local r1 = C.roadsRevision()
    assert(r1 > r0, "存檔後 revision 增加")
    local got = C.roadsGet(0, id)
    eq(got.name, "UI_MinidoracatMiniMap_RoadDefaultName|1", "空白名稱存預設名"); eq(got.rev, 1, "新路 rev 1")
    eq(t.log.nav, 1, "存檔通知路網"); eq(#t.log.put, 0, "沒分享旗不送")
    got.pts[1] = 999
    eq(C.roadsGet(0, id).pts[1], 0, "roadsGet 是副本")
    local ok2, id2 = C.roadsSave(0, got)
    assert(ok2); eq(id2, id, "改形狀同 id"); eq(C.roadsGet(0, id).rev, 2, "再存 rev+1")
    assert(C.roadsRevision() > r1, "revision 單調遞增")
end

-- 壞形狀不存；存檔失敗不換記憶體、不通知
do
    local t = fixture(); t.player(0)
    local C = t.core
    assert(C.roadsSave(0, road(0, 2, { name = "A" })))
    local ok, why = C.roadsSave(0, road(0, 2, { segWidth = { 4, 99 } }))
    eq(ok, false, "路寬越界拒存"); eq(why, "invalid", "原因 invalid")
    local rev, nav, file = C.roadsRevision(), t.log.nav, t.fs.files[PATH0]
    t.fs.lossy = true
    ok, why = C.roadsSave(0, road(0, 3))
    eq(ok, false, "寫入被吞＝失敗"); eq(why, "failed", "原因 failed")
    eq(#C.roadsList(0), 1, "失敗不換記憶體")
    eq(C.roadsRevision(), rev, "失敗不動 revision"); eq(t.log.nav, nav, "失敗不通知路網")
    eq(select(2, C.roadsRename(0, "r1", "B")), "failed", "改名寫入失敗")
    eq(C.roadsGet(0, "r1").name, "A", "改名失敗名稱不變")
    t.fs.lossy = false
    assert(file ~= nil)
    -- 重開：只讀得到寫成功的那條
    local t2 = fixture({ files = { [PATH0] = file }, broken = {} }); t2.player(0)
    eq(#t2.core.roadsList(0), 1, "重開筆數")
    eq(t2.core.roadsList(0)[1].name, "A", "重開名稱")
    local ok2, id2 = t2.core.roadsSave(0, road(50, 1))
    assert(ok2); eq(id2, "r2", "重開後編號接續 nextId")
end

-- 只讀：版本較新與打不開都拒寫，檔不動
do
    local newer = "MMROADS\t9\t3\nFUTURE\nEND\t0"
    local t = fixture({ files = { [PATH0] = newer }, broken = {} }); t.player(0)
    local C = t.core
    local list, reason = C.roadsList(0)
    eq(#list, 0, "只讀清單空"); eq(reason, "unsupported", "版本較新＝unsupported")
    local ok, why = C.roadsSave(0, road(0, 1))
    eq(ok, false, "只讀拒寫"); eq(why, "readonly", "原因 readonly")
    eq(select(2, C.roadsSetReceivedOff(0, "s1", true)), "readonly", "只讀拒寫 OFF")
    eq(t.fs.files[PATH0], newer, "較新檔沒被蓋掉")
    local tb = fixture({ files = { [PATH0] = "MMROADS\t1\t1\nEND\t0" }, broken = { [PATH0] = true } }); tb.player(0)
    eq(select(2, tb.core.roadsList(0)), "unreadable", "打不開＝unreadable")
    eq(select(2, tb.core.roadsSave(0, road(0, 1))), "readonly", "打不開拒寫")
    tb.fs.broken[PATH0] = nil
    assert(tb.core.roadsSave(0, road(0, 1)), "能打開後寫入前重讀即可寫")
    -- 壞檔（寫到一半）當空清單、可覆寫
    local tc = fixture({ files = { [PATH0] = "MMROADS\t1\t1\nROAD" }, broken = {} }); tc.player(0)
    eq(select(2, tc.core.roadsList(0)), nil, "壞檔不是只讀")
    assert(tc.core.roadsSave(0, road(0, 1)), "壞檔可覆寫")
end

-- 分享旗：存檔／改旗送出（rev 遞增），全關且有 sid 收回；刪除有 sid 收回
do
    local t = fixture(); t.player(0)
    local C = t.core
    local _, id = C.roadsSave(0, road(0, 1, { share = { faction = true } }))
    eq(#t.log.put, 1, "有分享旗就送"); eq(t.log.put[1].road.rev, 1, "送出的 rev")
    assert(C.roadsSetSid(0, id, "s9"))
    assert(C.roadsRename(0, id, "  New  "))
    eq(#t.log.put, 2, "改名重送"); eq(t.log.put[2].road.rev, 2, "改名 rev+1"); eq(t.log.put[2].road.name, "New", "名稱清理")
    assert(C.roadsSetShareFlags(0, id, { faction = false, safehouse = false }))
    eq(#t.log.drop, 1, "全關收回"); eq(t.log.drop[1].sid, "s9", "收回 sid")
    assert(C.roadsDelete(0, id))
    eq(#t.log.drop, 2, "刪除有 sid 也收回"); eq(#C.roadsList(0), 0, "刪掉了")
end

-- 路網：同 sid 合併遮罩、停用／OFF 不進、固定順序預算切點與 overBudget
do
    local t = fixture(); t.player(0); t.player(1)
    local C = t.core
    local _, a = C.roadsSave(0, road(0, 3, { name = "own0" }))       -- 3 段
    local _, b = C.roadsSave(0, road(0, 2, { name = "off0" }))       -- 停用
    assert(C.roadsSetEnabled(0, b, false))
    assert(C.roadsSetSid(0, a, "s5"))
    local _, c = C.roadsSave(1, road(200, 4, { name = "own1" }))     -- 4 段
    -- pn1 收到 pn0 分享的 s5；pn0 也收到伺服器回送的自己的 s5；pn0 收到 s3、s8（s8 停用）
    eq(C.roadsReplaceReceived(1, { received("s5", 0, 3) }), 1, "pn1 收到")
    eq(C.roadsReplaceReceived(0, { received("s8", 300, 1), received("s5", 0, 3), received("s3", 400, 2) }), 3, "pn0 收到")
    assert(C.roadsSetReceivedOff(0, "s8", true))
    eq(C.roadsReplaceReceived(0, { { sid = "bad" } }), 0, "壞的不收")
    C.roadsReplaceReceived(0, { received("s8", 300, 1), received("s5", 0, 3), received("s3", 400, 2) })
    local list, n = C.roadsActive(1000)
    eq(n, 3, "own0(s5 合併)、own1、s3")
    eq(list[1].road.name, "own0", "先自己的路 pn0"); eq(list[1].usableBy, 3, "s5 遮罩 pn0+pn1")
    eq(list[2].road.name, "own1", "再 pn1"); eq(list[2].usableBy, 2, "pn1 遮罩")
    eq(list[3].road.sid, "s3", "收到的照 sid"); eq(list[3].usableBy, 1, "s3 遮罩")
    eq(list[1].ownerPn, 0, "自己的路帶 ownerPn（s5 合併後仍是 pn0 那筆）"); eq(list[1].roadId, a, "自己的路帶 roadId")
    eq(list[3].ownerPn, nil, "收到的路不帶 ownerPn"); eq(list[3].roadId, nil, "收到的路不帶 roadId")
    -- 預算 7：own0(3)+own1(4) 剛好，s3(2) 切掉
    list, n = C.roadsActive(7)
    eq(n, 2, "預算切點")
    local recv = C.roadsReceived(0)
    local s3
    for _, r in ipairs(recv) do if r.sid == "s3" then s3 = r end end
    eq(s3.overBudget, true, "被切的標 overBudget"); eq(C.roadsList(0)[1].overBudget, nil, "沒切的不標")
    -- 預算 5：own0(3) 後 own1(4) 放不下，之後的 s3(2) 雖放得下也切（固定順序）
    list, n = C.roadsActive(5)
    eq(n, 1, "切點之後全不給"); eq(C.roadsList(1)[1].overBudget, true, "own1 標 overBudget")
    list, n = C.roadsActive(1000)
    eq(C.roadsList(1)[1].overBudget, nil, "預算夠了旗子清掉")
    eq(n, 3, "預算夠了全給")
    eq(#C.roadsReceived(0), 2, "伺服器送回的自己的 s5 不列在收到的")
    -- 作者停用自己的 s5：伺服器送回的那份不能讓它回到 pn0 的路網；pn1 照用
    assert(C.roadsSetEnabled(0, a, false))
    list, n = C.roadsActive(1000)
    eq(n, 3, "own1、s3、s5")
    eq(list[3].road.sid, "s5", "s5 只剩 pn1 收到的（排在 sid 順序）"); eq(list[3].usableBy, 2, "s5 只給 pn1")
    assert(C.roadsSetEnabled(0, a, true))
    -- OFF 往返：重開後仍停用
    local t2 = fixture({ files = t.fs.files, broken = {} }); t2.player(0)
    t2.core.roadsReplaceReceived(0, { received("s8", 300, 1) })
    eq(t2.core.roadsReceived(0)[1].off, true, "OFF 存檔")
    eq(select(2, t2.core.roadsActive(1000)), 1, "重開後 OFF 仍不進（只剩 own0）")
    -- 複製收到的路：新 id、沒有 sid／作者
    local id = t2.core.roadsCopyReceived(0, "s8")
    local copy = t2.core.roadsGet(0, id)
    eq(copy.sid, nil, "副本沒有 sid"); eq(copy.author, nil, "副本沒有作者"); eq(copy.name, "Shared s8", "副本名稱")
end

-- 預算硬上限 6000
do
    local t = fixture(); t.player(0)
    local C = t.core
    for i = 1, 21 do assert(C.roadsSave(0, road(i * 10000, 299))) end -- 21*299 = 6279 段
    local _, n = C.roadsActive(1e9)
    eq(n, 20, "上限 min(6000, max)")
end

-- roadsAt：最近一條、段號與投影點；半徑外 nil
do
    local t = fixture(); t.player(0)
    local C = t.core
    C.roadsSave(0, road(0, 3, { name = "near" }))                         -- y=100
    C.roadsSave(0, { pts = { 0, 104, 30, 104 }, segWidth = { 4 }, segSurface = { "dirt" },
        ends = { "snap", "snap" }, source = "draw", name = "far" })         -- y=104
    C.roadsReplaceReceived(0, { received("s2", 0, 3) })                      -- 與 near 重疊，自己的先
    local hit = C.roadsAt(0, 15, 101, 5)
    eq(hit.road.name, "near", "最近一條"); eq(hit.kind, "own", "重疊時自己的優先")
    eq(hit.seg, 2, "第 2 段"); eq(hit.px, 15, "投影 x"); eq(hit.py, 100, "投影 y"); eq(hit.dist, 1, "距離")
    eq(C.roadsAt(0, 15, 103.5, 5).road.name, "far", "靠近另一條")
    eq(C.roadsAt(0, 15, 120, 5), nil, "半徑外")
    C.roadsReplaceReceived(0, { received("s2", 0, 3), received("s9", 1000, 3), received("s10", 2000, 3) })
    assert(C.roadsSetReceivedOff(0, "s9", true))
    hit = C.roadsAt(0, 1015, 101, 5)
    eq(hit.kind, "received", "命中收到的路"); eq(hit.off, true, "停用的收到的路 off＝true")
    eq(C.roadsAt(0, 2015, 101, 5).off, false, "沒停用的 off＝false")
    eq(C.roadsAt(0, 15, 101, 5).off, nil, "自己的路不帶 off")
end

-- 草稿只在記憶體、動 revision；換世界重置
do
    local t = fixture(); t.player(0)
    local C = t.core
    local r = C.roadsRevision()
    assert(C.roadsSetDraft(0, { pts = { 1, 2 } }))
    assert(C.roadsRevision() > r, "草稿動 revision")
    eq(C.roadsDraft(0).pts[2], 2, "草稿")
    C.roadsClearDraft(0)
    eq(C.roadsDraft(0), nil, "清草稿")
    eq(next(t.fs.files), nil, "草稿不寫檔")
end

-- 寫檔先備份：備份寫不成＝主檔不動、記憶體不換；主檔壞了讀備份；較新版本不退回備份
local BAK0 = "MinidoracatMiniMap/roads/Sandbox/Save1_p0.bak.txt"
do
    local t = fixture(); t.player(0)
    local C = t.core
    assert(C.roadsSave(0, road(0, 2, { name = "A" })))
    eq(t.fs.files[BAK0], t.fs.files[PATH0], "備份與主檔同內容")
    local main = t.fs.files[PATH0]
    t.fs.lossyBak = true
    eq(select(2, C.roadsSave(0, road(0, 3, { name = "B" }))), "failed", "備份寫不成＝失敗")
    eq(t.fs.files[PATH0], main, "備份失敗不動主檔"); eq(#C.roadsList(0), 1, "記憶體不換")
    t.fs.lossyBak = false
    local good = t.fs.files[PATH0]
    local t2 = fixture({ files = { [PATH0] = "MMROADS\t1\t2\nROAD", [BAK0] = good }, broken = {} }); t2.player(0)
    local list, why = t2.core.roadsList(0)
    eq(#list, 1, "主檔壞了讀備份"); eq(list[1].name, "A", "備份內容"); eq(why, nil, "讀到備份可寫")
    local t3 = fixture({ files = { [PATH0] = good, [BAK0] = good }, broken = { [PATH0] = true } }); t3.player(0)
    eq(#t3.core.roadsList(0), 1, "主檔打不開讀備份")
    local t4 = fixture({ files = { [PATH0] = "MMROADS\t9\t1\nEND\t0", [BAK0] = good }, broken = {} }); t4.player(0)
    eq(select(2, t4.core.roadsList(0)), "unsupported", "較新版本不退回備份")
end

-- 來源碼：第一次寫檔存進檔頭、重開不變、分享副本帶著；舊檔沒有就補
do
    local t = fixture(); t.player(0)
    local C = t.core
    local _, id = C.roadsSave(0, road(0, 1, { share = { faction = true } }))
    local origin = t.fs.files[PATH0]:match("^MMROADS\t1\t%d+\t(%x+)\n")
    eq(origin, "cfe5687b1234", "檔頭來源碼＝時間低 32 位＋亂數")
    eq(t.log.put[1].road.origin, origin, "分享副本帶來源碼"); eq(t.log.put[1].road.id, id, "id 不變")
    local t2 = fixture({ files = { [PATH0] = t.fs.files[PATH0] }, broken = {} }); t2.player(0)
    t2.core.roadsRename(0, id, "X")
    eq(t2.fs.files[PATH0]:match("^MMROADS\t1\t%d+\t(%x+)\n"), origin, "重開沿用同一個來源碼")
    local old = fixture({ files = { [PATH0] = "MMROADS\t1\t1\nEND\t0" }, broken = {} }); old.player(0)
    assert(old.core.roadsSave(0, road(0, 1)))
    eq(old.fs.files[PATH0]:match("^MMROADS\t1\t%d+\t(%x+)\n"), "cfe5687b1234", "舊檔補來源碼")
end

-- 待撤回：刪除有 sid 記進 DROP（重開還在），清掉才消失
do
    local t = fixture(); t.player(0)
    local C = t.core
    local _, id = C.roadsSave(0, road(0, 1, { share = { faction = true } }))
    assert(C.roadsSetSid(0, id, "s4"))
    assert(C.roadsDelete(0, id))
    eq(C.roadsPendingDrops(0)[1], "s4", "刪除後待撤回"); eq(t.log.drop[1].sid, "s4", "刪除時先送一次")
    local t2 = fixture({ files = { [PATH0] = t.fs.files[PATH0] }, broken = {} }); t2.player(0)
    eq(t2.core.roadsPendingDrops(0)[1], "s4", "重開後仍待撤回")
    assert(t2.core.roadsClearPendingDrop(0, "s4"))
    eq(#t2.core.roadsPendingDrops(0), 0, "清掉")
    local t3 = fixture({ files = { [PATH0] = t2.fs.files[PATH0] }, broken = {} }); t3.player(0)
    eq(#t3.core.roadsPendingDrops(0), 0, "清掉有存檔")
    assert(t3.core.roadsClearPendingDrop(0, "s4"), "不在清單＝已清")
end
print("test_roads_store: ok")
