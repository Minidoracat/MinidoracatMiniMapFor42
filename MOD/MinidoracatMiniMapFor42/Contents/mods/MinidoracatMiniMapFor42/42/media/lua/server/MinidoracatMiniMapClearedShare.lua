-- MinidoracatMiniMapClearedShare.lua — 資源點「已清空」分享與重置偵測（MP 伺服器端；2026-11-08 設計稿 cleared 作答）
-- 玩家自己的標記以他電腦上的帳號檔為準；客戶端把「會存」的標記（C.relevant：已清空、已刷新、有翻過進度而且拿過東西）
-- 同步一份到這裡，伺服器只回寫「已刷新」。只有去過、只翻過沒拿的不上傳、不分享，clrPut 收到就整包拒收。
--
-- 檔案（格式在 shared/MinidoracatMiniMap_ClearedCodec.lua）：Lua/MinidoracatMiniMap/cleared/<世界>/
--   <帳號十六進位>.txt  每位作者一個檔（帳號可能含檔名不允許的字元，所以用十六進位；不用 fileKey）
--   index.txt          作者清單（筆數、分享）；Lua 列不出資料夾，所以要索引
-- chunk → 作者（B2／B3 查表）只在記憶體：開服時逐一讀索引列的作者檔重建（讀完就丟），之後增量維護、不存檔。
-- 2026-11-08 實測（9950X3D）：存進索引時，30 位作者各 300 筆（同一批城鎮）索引 13,172 行、5.1 MB，每輪整份重寫一次
-- 單幀中位 44、最大 81 ms，開服讀 348 ms。
-- 作者檔要用才載入（線上作者、同步時看得到的隊友、重置碰到的 chunk），閒置 EVICT_MS 且不在線就丟掉；
-- 有變動的檔每 SAVE_MS 排一輪：先寫作者、最後寫索引，每個 tick 寫一個檔（先寫 .bak.txt，RoadCodec.writeSafe；
-- 寫失敗留著下輪再寫）。專用伺服器停機不發任何 Lua 事件（ServerMap.QueuedQuit／QueuedSaveAll，ServerMap.java:332-391；
-- OnSave 只在客戶端）：停機或當機最多掉 SAVE_MS 的資料，靠 clrSyncOk 的 digest 在作者下次登入時對帳補回。
-- 讀檔規則見 C.readSafe；任何錯誤（打不開、版本較新、主檔與備份都壞）都只讀，不覆寫（Lua 列不出資料夾，索引沒了
-- 就找不回其他作者）；log 帶檔名，每個檔記一次。
--
-- 來源碼（同自訂道路）：每台電腦的帳號檔有固定的來源碼，伺服器以（來源碼, 建築）存，同一個帳號兩台電腦各一份、
-- 不互刪（設計稿 cleared.html「同一個帳號在兩台電腦，伺服器那份是兩邊合併」）。對帳的筆數與摘要、整份重傳的
-- reset…done、刪除都只算送來的那個來源碼；刷新（B2／B3）套到所有來源碼；chunk 預算算作者全部來源碼。
-- 每位作者最多 MAX_ORIGINS 個來源碼，滿了有新的進來就丟掉最久沒同步的那個。
-- 隊友看到的是合併後的一棟一筆（CS.groups／CS.better：同棟用 C.same 分組，已清空有效到被刷新為止，
-- 再比伺服器發的修改序號 us）。
--
-- 上限（全部先驗整包、算好套用後的筆數與預算，可以接受才改 store）：一包 MAX_PUT 筆；每個來源碼 C.MAX_MARKS 筆；
-- 每位作者外框蓋到的 chunk 總數 C.CHUNK_BUDGET（C.chunkCost O(1) 算）。chunk 表用每位作者的引用數增量維護，
-- 只展開有新增或刪除的外框。
--
-- 身分：作者與收件人一律 MinidoracatMiniMapGroups.principal（分割畫面第 2～4 位沒有身分：寫入回
-- clrPutFail reason=identity，同步不回，也收不到任何分享或刷新）。
--
-- 收件人每次當下判斷（CS.canSee：作者開了分享（看作者檔，不看索引），而且同陣營或同一間安全屋；管理員
-- 不會因為進得了所有安全屋就收到）。沙盒 AllowClearedShare 關＝照存、刷新照做，只是不轉送給隊友。
-- 封包（模組 MinidoracatMiniMapCleared，伺服器回的都帶 to：分割畫面共用一條連線）：
--   客戶端→伺服器 clrPut{id, marks=[≤MAX_PUT 筆 wire], share, origin, reset?, done?}、clrDrop{id, keys, origin}、
--     clrSync{seq, count, share, origin}（三種各自每位作者每 RATE_MS 一次）
--   伺服器→客戶端 clrSyncOk{to, count, digest, seq, readOnly?}、clrSyncRate{to}、
--     clrTeamSnap{to, seq, part, parts, marks=[{a, m}]}、clrTeamUpsert{to, a, marks=[wire]}、
--     clrTeamRemove{to, a, keys?（nil＝這位作者全部）}、clrRefreshed{to, marks=[wire], seq?（最後一包才帶）}、
--     clrPutFail{to, reason, cmd, id?（客戶端那包的請求編號）}
--
-- 重置偵測：
--   B2：LoadChunk（ServerMap.java:953 → IsoChunk.java:3969）時 chunk:isNewChunk()（IsoChunk.java:5170：存檔不存在
--     而重新生成才為真，被重置工具移走的 chunk 就是這種）。只對 chunk 表裡有標記的 chunk 排進佇列，下一個 tick 才載入作者、
--     改「已刷新」；只通知標記的主人與他看得到的隊友，不廣播（重新生成本身透露「最近有人走到那裡」）。
--   B3：外部重置工具寫的 Lua/MinidoracatMiniMap/chunk_resets_<存檔名>.txt（存檔名取法同 players_<存檔名>.json，
--     MinidoracatMiniMapPlayerExport.lua buildExportPath）。開服讀一次，之後每 RESETS_CHECK_MS 只讀第一行，
--     第一行變了才整份解析（解析、套用成功才記下這一行；失敗下一輪重試）；壞行或 RUN 的毫秒不是由新到舊遞減就整份拒收。
--     只套用比水位晚的 RUN（水位＝max(索引建立時間, 已套用的最新 RUN 毫秒)：索引遺失重建時不把舊的重置套到新標記上，
--     產生端之後若做還原、移除最新 RUN 也不會重套）。
--     冪等：作者檔記自己已套到哪個 RUN 毫秒（rms），重播時跳過；索引的 run／ms 要等這次受影響的作者都寫進檔才寫
--     （只讀的作者寫不進去＝這輪不提交），所以任何一個寫檔邊界停機，重開後都會重播、而且不會把之後又清空的建築再標已刷新。
--     線上重置（產生端在伺服器跑著時移檔）：RUN 毫秒＝開始移檔的時間，標記的 rs 不早於它＝之後 B2 刷新過，跳過。
-- server 資料夾在 MP 客戶端也會載入（GameLoadingState.java:149），故閘 isClient；單機（不是 isServer）不做 B2／B3，
-- 單機的 B2 在 client/MinidoracatMiniMap_Cleared.lua。
if isClient() then return end

local CS = {
    MODULE = "MinidoracatMiniMapCleared",
    MAX_PUT = 64,
    MAX_ORIGINS = 4,
    RATE_MS = 1000,
    SNAP_BATCH = 64,
    SAVE_MS = 10000,
    RESETS_CHECK_MS = 600000,
    EVICT_MS = 1800000,
    KEEP_MS = 300000,   -- 整份重傳超過這麼久沒有下一包＝中途放棄（客戶端每 2 秒一包，47 包約 100 秒）
    MAX_RUNS = 60,
    authors = {},       -- [hex] = { hex, name, store, readOnly, dirty, touched, ck = { ["cx,cy"] = 這位作者的外框數 } }
    index = nil, indexPath = nil, indexDirty = false, indexReadOnly = false,
    missing = {},       -- [hex] = true：開服重建時作者檔讀不到（不知道他的 chunk）；讀得到之前不提交重置 run
    lastPut = {}, lastDrop = {}, lastSync = {},
    originOf = {},      -- [帳號] = 這次登入的來源碼（clrSync 記下；刷新只推這台電腦的筆）
    seq = 0,
    pendingChunks = {}, pendingN = 0,
    saveAt = 0, saveQueue = nil, saveQn = 0, resetsAt = 0, resetsHead = nil,
    runPending = nil,   -- { run, ms, hexes = { [hex] = true } }：已套用、等作者都寫進檔才寫進索引
    WRITES = { clrPut = true, clrDrop = true },
    warned = {},
}

-- Kahlua 沒有 next（verify_mod.py 擋）
function CS.empty(t)
    for _ in pairs(t) do return false end
    return true
end

function CS.warn(key, msg)
    if CS.warned[key] then return end
    CS.warned[key] = true
    print("[MinidoracatMiniMap] ClearedShare " .. tostring(msg))
end

function CS.codecs()
    return MinidoracatMiniMapClearedCodec, MinidoracatMiniMapRoadCodec
end

-- 政策缺席＝不轉送（同 RoadShare）；AllowClearedShare 不在任何旁路名單，故不傳 playerNum
function CS.allowed()
    local P = MinidoracatMiniMapPolicy
    if not P then
        CS.warn("policy", "policy facade missing, cleared share not forwarded")
        return false
    end
    return P.readBool("AllowClearedShare", true) == true
end

function CS.now()
    local gt = getGameTime()
    return gt and gt:getWorldAgeHours() or 0
end

function CS.dir()
    local _, Codec = CS.codecs()
    return "MinidoracatMiniMap/cleared/" .. Codec.fileKey(getWorld():getWorld()) .. "/"
end

-- 存檔名 token：同 server/MinidoracatMiniMapPlayerExport.lua buildExportPath（只留字母數字 - _、最長 48）
function CS.resetsPath()
    local ok, save = pcall(function() return getWorld():getWorld() end)
    if not ok or type(save) ~= "string" or save == "" then return "MinidoracatMiniMap/chunk_resets.txt" end
    local token = save:gsub("[^%w%-_]", "_")
    if token:len() > 48 then token = token:sub(1, 48) end
    if token:gsub("_", "") == "" then return "MinidoracatMiniMap/chunk_resets.txt" end
    return "MinidoracatMiniMap/chunk_resets_" .. token .. ".txt"
end

-- 讀檔（C.readSafe；例外當 unreadable）：回 data, err（任何 err＝只讀）；log 帶檔名，每個檔一次
function CS.load(path, decode)
    local C = CS.codecs()
    local ok, data, err, recovered = pcall(C.readSafe, path, decode)
    if not ok then
        CS.warn("load:" .. path, path .. ": " .. tostring(data) .. ", read-only")
        return nil, "unreadable"
    end
    if err then
        CS.warn("load:" .. path, path .. ": " .. err .. (data and ", showing backup" or "") .. ", read-only")
    elseif recovered then
        CS.warn("load:" .. path, path .. ": " .. recovered .. ", read backup")
    end
    return data, err, recovered
end

-- 索引 -------------------------------------------------------------------------------
function CS.ensureIndex()
    local C = CS.codecs()
    local path = CS.dir() .. "index.txt"
    if CS.indexPath == path then return CS.index end
    local idx, err, recovered = CS.load(path, C.decodeIndex)
    CS.indexDirty = recovered ~= nil -- 從備份讀回來的寫回主檔
    if not idx then
        idx = { run = nil, since = math.floor(getTimestampMs()), ms = 0, authors = {}, an = 0, chunks = {} }
        CS.indexDirty = err == nil
    end
    CS.indexPath, CS.index = path, idx
    CS.indexReadOnly = err ~= nil
    CS.authors, CS.runPending, CS.missing = {}, nil, {}
    -- chunk 表：逐一讀作者檔重建（讀完就丟，作者檔照樣要用才載入）。OnServerStarted 當下做完，玩家連進來、
    -- 有 LoadChunk 之前表就是完整的。讀不到的作者記在 missing（CS.commitRun）。
    -- ponytail: 開服時間隨作者總筆數線性（2026-11-08 9950X3D：30 位各 300 筆 528-571 ms、單一作者 2950 筆 193-268 ms）；
    -- 上百位滿額作者拖慢開服時，改成分 tick 重建、重建完之前的新 chunk 排隊補套
    local hexes, hn = {}, 0
    for hex in pairs(idx.authors) do
        hn = hn + 1
        hexes[hn] = hex
    end
    for i = 1, hn do
        if CS.author(hexes[i]).readOnly then CS.missing[hexes[i]] = true end
        CS.authors[hexes[i]] = nil
    end
    return idx
end

-- 一個外框的 chunk 引用數 ±1；從 0 變 1、從 1 變 0 才動記憶體的 chunk 表（只展開這個外框）
function CS.refChunks(entry, m, d)
    local C, idx = CS.codecs(), CS.index
    local keys, n = C.chunkKeys(m)
    for k = 1, n do
        local key = keys[k]
        local c = (entry.ck[key] or 0) + d
        if c > 0 then
            entry.ck[key] = c
            if c == 1 and d > 0 then
                local set = idx.chunks[key] or {}
                idx.chunks[key] = set
                set[entry.hex] = true
            end
        else
            entry.ck[key] = nil
            local set = idx.chunks[key]
            if set and set[entry.hex] then
                set[entry.hex] = nil
                if CS.empty(set) then idx.chunks[key] = nil end
            end
        end
    end
end

-- 作者摘要（筆數、分享）沒變就不動索引
function CS.summary(entry)
    local idx, st = CS.index, entry.store
    local a = idx.authors[entry.hex]
    if st.count == 0 then
        if a then
            idx.authors[entry.hex] = nil
            idx.an = idx.an - 1
            CS.indexDirty = true
        end
    elseif not a or a.count ~= st.count or a.share ~= st.share then
        if not a then idx.an = idx.an + 1 end
        idx.authors[entry.hex] = { count = st.count, share = st.share }
        CS.indexDirty = true
    end
end

-- 作者檔 -----------------------------------------------------------------------------
function CS.hexOf(name)
    local C = CS.codecs()
    local ok, hex = pcall(C.hex, name)
    if ok and type(hex) == "string" and #hex >= 4 then return hex end
    CS.warn("hex", "cannot encode account name")
    return nil
end

-- 載入時用作者檔重建這位作者的 chunk 引用數；讀得懂作者檔才順便修正索引的摘要（索引和作者檔可能差一輪寫檔），
-- 也不再算開服時讀不到（CS.missing）。讀不到或只讀（內容不明）時索引原樣留著：暫時的讀檔故障不能變成永久刪掉這位作者
function CS.author(hex, name)
    local entry = CS.authors[hex]
    if not entry then
        local C = CS.codecs()
        local store, err = CS.load(CS.dir() .. hex .. ".txt", C.decodeServer)
        entry = { hex = hex, name = name or C.unhex(hex), store = store or C.emptyServer(), readOnly = err ~= nil,
            ck = {}, keep = {}, keepAt = {}, at = {}, cnt = {}, cost = {}, total = 0, keepN = {}, keepCost = {} }
        CS.authors[hex] = entry
        local st = entry.store
        for i = 1, st.count do CS.track(entry, st.marks[i], 1) end
        if not err then
            CS.missing[hex] = nil
            CS.summary(entry)
        end
    end
    entry.touched = getTimestampMs()
    return entry
end

-- 每位作者的增量索引（clrPut 每包只看這包碰到的外框鍵，不掃整份；2026-11-08 實測 2950 筆整份重傳時整份掃描
-- 每包 18–31 ms）：at[來源碼][外框鍵]＝那筆標記、cnt／cost[來源碼]＝筆數與外框蓋到的 chunk 數、total＝全部 chunk 數；
-- 整份重傳中 keepN／keepCost[來源碼]＝這次已再送到（keep 裡）的筆數與 chunk 數。加筆、刪筆一律經這裡
-- （CS.author 載入、clrPut 新增、CS.removeWhere）；換內容是就地改那筆（外框鍵、chunk 都不變）
function CS.track(entry, m, d)
    local C = CS.codecs()
    local o, key, c = m.o, C.key(m), C.chunkCost(m)
    local at = entry.at[o]
    if not at then
        at = {}
        entry.at[o] = at
    end
    at[key] = d > 0 and m or nil
    entry.cnt[o] = (entry.cnt[o] or 0) + d
    entry.cost[o] = (entry.cost[o] or 0) + d * c
    entry.total = entry.total + d * c
    local keep = entry.keep[o]
    if keep and keep[key] then
        entry.keepN[o] = entry.keepN[o] + d
        entry.keepCost[o] = entry.keepCost[o] + d * c
    end
    CS.refChunks(entry, m, d)
end

-- 拿掉符合 pred 的筆（一次搬移；索引與引用數同步扣），把外框鍵記進 keys
function CS.removeWhere(entry, pred, keys)
    local C, st, k = CS.codecs(), entry.store, 0
    for i = 1, st.count do
        local m = st.marks[i]
        if pred(m) then
            CS.track(entry, m, -1)
            keys[C.key(m)] = true
        else
            k = k + 1
            st.marks[k] = m
        end
    end
    for i = k + 1, st.count do st.marks[i] = nil end
    st.count = k
end

-- 一輪寫檔：先排好有變動的作者，CS.saveStep 每個 tick 從尾端取一個寫；索引排在最前面＝最後寫
function CS.saveStart()
    local q, n = {}, 0
    if (CS.indexDirty or CS.runPending) and not CS.indexReadOnly then
        n = n + 1
        q[n] = false
    end
    for hex, entry in pairs(CS.authors) do
        if entry.dirty and not entry.readOnly then
            n = n + 1
            q[n] = hex
        end
    end
    CS.saveQueue, CS.saveQn = n > 0 and q or nil, n
end

-- 重置 RUN 的受影響作者都寫進檔了才把 run／ms 交給索引；只讀的作者寫不了（dirty 一直在）＝不提交，
-- 下次開服從上一個 run 重播（作者檔修好後補套；寫進去的作者有 rms，不會重複）。
-- 開服時有作者檔讀不到（CS.missing）也不提交：不知道他的 chunk，不知道這次 RUN 有沒有碰到他
function CS.commitRun()
    local p = CS.runPending
    if not p then return end
    if not CS.empty(CS.missing) then return end
    for hex in pairs(p.hexes) do
        local e = CS.authors[hex]
        if e and e.dirty then return end
    end
    CS.index.run, CS.index.ms = p.run, p.ms
    CS.runPending = nil
    CS.indexDirty = true
end

function CS.saveStep()
    local q = CS.saveQueue
    local hex = q[CS.saveQn]
    q[CS.saveQn] = nil
    CS.saveQn = CS.saveQn - 1
    if CS.saveQn <= 0 then CS.saveQueue = nil end
    local C, Codec = CS.codecs()
    if hex == false then
        CS.commitRun()
        if not CS.indexDirty or CS.indexReadOnly then return end
        local ok, saved = pcall(Codec.writeSafe, CS.indexPath, C.encodeIndex(CS.index))
        if ok and saved then
            CS.indexDirty = false
        else
            CS.warn("save:" .. CS.indexPath, CS.indexPath .. ": " .. (ok and "read-back mismatch" or tostring(saved)))
        end
        return
    end
    local entry = CS.authors[hex]
    if not (entry and entry.dirty and not entry.readOnly) then return end
    local path = CS.dir() .. hex .. ".txt"
    -- ponytail: 每次整份編碼＋寫兩份＋讀回比對；2026-11-08 9950X3D 量 2950 筆的作者寫一次中位 21、最大 28-53 ms
    -- （編碼約一半），300 筆約 12 ms。伺服器回報卡頓再做每筆編碼快取：clrPut 就地換內容與 refreshGrid 都要清那筆的快取
    local ok, saved = pcall(Codec.writeSafe, path, C.encodeServer(entry.store))
    if ok and saved then
        entry.dirty = false
    else
        CS.warn("save:" .. path, path .. ": " .. (ok and "read-back mismatch" or tostring(saved)))
    end
end

-- 收件人與合併 -------------------------------------------------------------------------
CS.SHARE_ALL = { faction = true, safehouse = true }
function CS.canSee(entry, name)
    return entry.store.share and MinidoracatMiniMapGroups.canSee(entry.name, CS.SHARE_ALL, name)
end

function CS.send(p, command, args)
    sendServerCommand(p, CS.MODULE, command, args)
end

-- 線上、看得到這位作者的隊友（沙盒關＝沒有人）
function CS.eachViewer(entry, fn)
    if not CS.allowed() then return end
    local list = getOnlinePlayers()
    for i = 0, list:size() - 1 do
        local p = list:get(i)
        local name = p and MinidoracatMiniMapGroups.principal(p)
        if name and name ~= entry.name and CS.canSee(entry, name) then fn(p, name) end
    end
end

-- 換分享設定前看得到的人（share 參數＝當時的旗標）
function CS.eachViewerAll(entry, share, fn)
    if not share or not CS.allowed() then return end
    local list = getOnlinePlayers()
    for i = 0, list:size() - 1 do
        local p = list:get(i)
        local name = p and MinidoracatMiniMapGroups.principal(p)
        if name and name ~= entry.name and MinidoracatMiniMapGroups.canSee(entry.name, CS.SHARE_ALL, name) then
            fn(p, name)
        end
    end
end

function CS.online(name)
    local list = getOnlinePlayers()
    for i = 0, list:size() - 1 do
        local p = list:get(i)
        if p and MinidoracatMiniMapGroups.principal(p) == name then return p end
    end
    return nil
end

-- 隊友看到的合併規則（同一個帳號的幾台電腦）：同一棟（C.same：地上地下、兩種標示方式的外框）各來源碼只輸出一筆。
--   1. 已清空有效到被刷新為止：ch>0 而且清空狀態是在這棟最後一次刷新之後送來的（us > 組裡最大的 rs）優先；
--   2. 再比伺服器發的修改序號 us（單調，不比遊戲時數：管理員會撥時鐘，另一台走進去翻幾格也不該蓋掉已清空）；
--   3. 一樣新的翻過數多的優先。
function CS.better(a, b, maxRs)
    local va, vb = a.ch > 0 and a.us > maxRs, b.ch > 0 and b.us > maxRs
    if va ~= vb then return va end
    if a.us ~= b.us then return a.us > b.us end
    return a.s > b.s
end

-- 分組：回 gid[標記] = 組（第一筆的外框鍵）、best[組] = 代表那筆。同外框鍵直接同組；不只一個來源碼時，
-- 中心所在 8 格桶與周圍 8 桶裡用 C.same 找同一棟。
-- ponytail: 兩個外框中心相距超過 8～16 格的同一棟（地下室比地上大很多）會分成兩組各自輸出；遇到再加大搜尋範圍
function CS.groups(st)
    local C, floor = CS.codecs(), math.floor
    local gid, kg, maxRs, buckets = {}, {}, {}, {}
    for i = 1, st.count do
        local m = st.marks[i]
        local k = C.key(m)
        local g = kg[k]
        if not g and st.on > 1 then
            local bx, by = floor((m.x + m.w / 2) / 8), floor((m.y + m.h / 2) / 8)
            for dx = -1, 1 do
                for dy = -1, 1 do
                    local list = not g and buckets[(bx + dx) .. "," .. (by + dy)]
                    for j = 1, list and #list or 0 do
                        if C.same(list[j], m) then
                            g = gid[list[j]]
                            break
                        end
                    end
                end
            end
            if not g then
                local bk = bx .. "," .. by
                local list = buckets[bk] or {}
                buckets[bk] = list
                list[#list + 1] = m
            end
        end
        g = g or k
        kg[k], gid[m] = g, g
        if m.rs > (maxRs[g] or 0) then maxRs[g] = m.rs end
    end
    local best = {}
    for i = 1, st.count do
        local m = st.marks[i]
        local g = gid[m]
        local cur = best[g]
        if not cur or CS.better(m, cur, maxRs[g] or 0) then best[g] = m end
    end
    return gid, best
end

-- 合併後的 wire；keys＝{ [外框鍵] = true }（nil＝全部，照標記順序、同樣的資料每次輸出一樣）只輸出碰到這些鍵的組。
-- 回 wires, n, gone（隊友該拿掉的外框鍵：keys 裡沒輸出的、和這些組裡不是代表的其他外框）。
-- 只有一個來源碼時一個外框鍵就是一組：直接查 CS.track 的索引，不分組、不掃整份（整份重傳每包都走這裡；順序不固定，
-- 客戶端照外框鍵套用）。
-- ponytail: 多來源碼的作者每包仍全掃分組（CS.groups）；常見了再維護 8 格桶的索引
function CS.mergedWires(entry, keys)
    local C, st = CS.codecs(), entry.store
    if keys and st.on <= 1 then
        local at = {}
        for o in pairs(st.origins) do at = entry.at[o] or {} end
        local wires, n, gone, gn = {}, 0, {}, 0
        for k in pairs(keys) do
            local m = at[k]
            if m then
                n = n + 1
                wires[n] = C.toWire(m)
            else
                gn = gn + 1
                gone[gn] = k
            end
        end
        return wires, n, gone, gn
    end
    local gid, best = CS.groups(st)
    local hit = {}
    if keys then
        for i = 1, st.count do
            local m = st.marks[i]
            if keys[C.key(m)] then hit[gid[m]] = true end
        end
    end
    local wires, n, out = {}, 0, {}
    for i = 1, st.count do
        local m = st.marks[i]
        local g = gid[m]
        if best[g] == m and (keys == nil or hit[g]) then
            n = n + 1
            wires[n] = C.toWire(m)
            out[C.key(m)] = true
        end
    end
    local gone, gn, seen = {}, 0, {}
    local function drop(k)
        if out[k] or seen[k] then return end
        seen[k] = true
        gn = gn + 1
        gone[gn] = k
    end
    for k in pairs(keys or {}) do drop(k) end
    if keys then
        for i = 1, st.count do
            local m = st.marks[i]
            if hit[gid[m]] then drop(C.key(m)) end
        end
    end
    return wires, n, gone, gn
end

function CS.sendTeamMarks(p, to, entry, wires, n)
    for from = 1, math.max(1, n), CS.SNAP_BATCH do
        local part, k = {}, 0
        for i = from, math.min(n, from + CS.SNAP_BATCH - 1) do
            k = k + 1
            part[k] = wires[i]
        end
        if k > 0 then CS.send(p, "clrTeamUpsert", { to = to, a = entry.name, marks = part }) end
    end
end

-- 這些外框的合併結果推給看得到的隊友：還在的 upsert、全部來源碼都沒了的 remove。線上沒有看得到的人（沒開分享、
-- 沙盒關、隊友都不在線；CS.eachViewer）就不算合併
function CS.pushKeys(entry, keys)
    if CS.empty(keys) then return end
    local to, tn = {}, 0
    CS.eachViewer(entry, function(p, name)
        tn = tn + 1
        to[tn] = { p, name }
    end)
    if tn == 0 then return end
    local wires, n, gone, gn = CS.mergedWires(entry, keys)
    for i = 1, tn do
        local p, name = to[i][1], to[i][2]
        if n > 0 then CS.sendTeamMarks(p, name, entry, wires, n) end
        if gn > 0 then CS.send(p, "clrTeamRemove", { to = name, a = entry.name, keys = gone }) end
    end
end

-- 自己的刷新分批送；seq 只放在最後一包（客戶端處理完整批才推進游標）
function CS.sendRefreshed(p, to, wires, n, seq)
    for from = 1, n, CS.SNAP_BATCH do
        local part, k = {}, 0
        for i = from, math.min(n, from + CS.SNAP_BATCH - 1) do
            k = k + 1
            part[k] = wires[i]
        end
        CS.send(p, "clrRefreshed", { to = to, marks = part, seq = from + CS.SNAP_BATCH > n and seq or nil })
    end
end

-- 刷新（B2／B3）：外框碰到 grid[cx][cy] 的已清空或有進度標記（全部來源碼）改已刷新，每筆發一個新序號
-- （max(現在 epoch 毫秒, 上一個＋1)：伺服器停機回滾後也不會發出客戶端看過的號碼）；回改了的標記陣列。
-- grid 的值：true＝B2（這個 chunk 現在重新生成，一定套）；數字＝B3 的 RUN 毫秒（重置工具開始移檔的時間）：
-- 這筆的 rs 已經不早於它＝線上重置時那之後 B2 刷新過（之後再清空的不能被清單蓋回已刷新），跳過。
-- B2 不套沒走進去過的（vh＝0，手動標的）：isNewChunk 第一次生成也是真（IsoChunk.java:2260、:5170），
-- 從沒人靠近過的建築第一次有人走近不是「被重置」。
-- 每位作者的標記只掃一遍（2026-11-08 實測：逐 chunk 掃全部標記，一次傳送命中 67 個 chunk 時單幀 37 ms）
function CS.newSeq(st)
    st.seq = math.max(math.floor(getTimestampMs()), st.seq + 1)
    return st.seq
end
function CS.refreshGrid(entry, grid, now, out)
    local C, st = CS.codecs(), entry.store
    local K, floor = C.CHUNK, math.floor
    for i = 1, st.count do
        local m = st.marks[i]
        if m.ch > 0 or m.s > 0 then
            local b2, ms, useB2 = false, nil, m.vh > 0
            for cx = floor(m.x / K), floor((m.x + m.w - 1) / K) do
                local col = grid[cx]
                if col then
                    for cy = floor(m.y / K), floor((m.y + m.h - 1) / K) do
                        local v = col[cy]
                        if v == true then
                            b2 = useB2
                            if b2 then break end
                        elseif v and (not ms or v > ms) then
                            ms = v
                        end
                    end
                end
                if b2 then break end
            end
            if b2 or (ms and m.rs < ms) then
                C.refresh(m, now)
                m.rs = CS.newSeq(st)
                m.us = m.rs
                entry.dirty = true
                out[#out + 1] = m
            end
        end
    end
end

-- 通知主人（在線、只送他這台電腦的來源碼）與他看得到的隊友（合併後）
function CS.notifyRefreshed(entry, marks)
    local n = #marks
    if n == 0 then return end
    local C = CS.codecs()
    local owner, origin = CS.online(entry.name), CS.originOf[entry.name]
    if owner and origin then
        local wires, wn = {}, 0
        for i = 1, n do
            if marks[i].o == origin then
                wn = wn + 1
                wires[wn] = C.toWire(marks[i])
            end
        end
        if wn > 0 then CS.sendRefreshed(owner, entry.name, wires, wn, entry.store.seq) end
    end
    local keys = {}
    for i = 1, n do keys[C.key(marks[i])] = true end
    CS.pushKeys(entry, keys)
end

-- 指令 -------------------------------------------------------------------------------
local Commands = {}

function CS.rateOk(map, name, now)
    local last = map[name]
    if last and now - last < CS.RATE_MS then return false end
    map[name] = now
    return true
end

-- 新的來源碼要進來、作者已經有 MAX_ORIGINS 個：最久沒同步的那個（回 nil＝不用丟）
function CS.evictOrigin(st, origin)
    if st.origins[origin] or st.on < CS.MAX_ORIGINS then return nil end
    local oldest, at = nil, nil
    for o, seen in pairs(st.origins) do
        if not at or seen < at or (seen == at and o < oldest) then oldest, at = o, seen end
    end
    return oldest
end

-- 世界範圍（格）：IsoMetaGrid 的 cell 範圍×256，同引擎加區域時的檢查多留 100 格（IsoMetaGrid.java:521-524）。
-- 開服後不變，算一次；拿不到（不該發生）就不檢查
function CS.worldBox()
    if CS.wb ~= nil then return CS.wb or nil end
    local ok, mg = pcall(function() return getWorld():getMetaGrid() end)
    if ok and mg then
        CS.wb = { x0 = mg:getMinX() * 256 - 100, y0 = mg:getMinY() * 256 - 100,
            x1 = (mg:getMaxX() + 1) * 256 + 100, y1 = (mg:getMaxY() + 1) * 256 + 100 }
    else
        CS.wb = false
    end
    return CS.wb or nil
end
function CS.inWorld(m)
    local wb = CS.worldBox()
    return not wb or (m.x >= wb.x0 and m.y >= wb.y0 and m.x + m.w <= wb.x1 and m.y + m.h <= wb.y1)
end

-- 失敗回覆帶回客戶端的請求編號（同時好幾包在途時客戶端才找得到被拒的是哪一包）
function CS.failFn(player, author, cmd, args)
    local id = type(args.id) == "number" and args.id or nil
    return function(reason) CS.send(player, "clrPutFail", { to = author, reason = reason, cmd = cmd, id = id }) end
end

-- 上傳。整份重傳（reset … done）分兩段：reset 開始記這台電腦這次送到的外框（entry.keep[來源碼]），收到 done
-- 才刪沒送到的舊筆；中間舊筆照常留著（B2／B3 刷新、隊友合併、保留伺服器較新的刷新都看得到）。
-- 伺服器重開等原因沒收到 done：舊筆留著，下次同步摘要不同再重傳一次
function Commands.clrPut(player, args, author)
    local fail = CS.failFn(player, author, "clrPut", args)
    local C = CS.codecs()
    local hex = C and CS.hexOf(author)
    if not hex then return fail("invalid") end
    local nowMs = getTimestampMs()
    if not CS.rateOk(CS.lastPut, author, nowMs) then return fail("rate") end
    local origin = args.origin
    if not C.validOrigin(origin) then return fail("invalid") end
    local wires = args.marks
    if type(wires) ~= "table" then wires = {} end
    -- 先驗整包、同一棟去重（後面的蓋前面的）
    local marks, n, pos, seen = {}, 0, {}, 0
    for _, w in pairs(wires) do
        seen = seen + 1
        if seen > CS.MAX_PUT then return fail("invalid") end
        local m = C.fromWire(w)
        if not (m and C.relevant(m) and CS.inWorld(m)) then return fail("invalid") end
        local key = C.key(m)
        if pos[key] then
            marks[pos[key]] = m
        else
            n = n + 1
            marks[n] = m
            pos[key] = n
        end
    end
    CS.ensureIndex()
    local entry = CS.author(hex, author)
    if entry.readOnly or CS.indexReadOnly then return fail("readonly") end
    local st = entry.store
    local reset, done = args.reset == true, args.done == true
    local keep = entry.keep[origin]
    -- 整份重傳中途斷了（斷線、重開客戶端）就不會有 done：太久沒有下一包＝放棄這次，不刪任何舊筆。留著的話
    -- 之後的一般上傳都被當成重傳中：預算少算、筆數接近上限時把還沒再送到的有效舊筆刪掉
    if keep and nowMs - (entry.keepAt[origin] or 0) > CS.KEEP_MS then keep = nil end
    if reset then keep = {} end
    -- 套用後的筆數與 chunk 預算（不動 store；只看這包的外框鍵，其餘用 CS.track 維護的合計）：
    -- 整份重傳中，這台電腦還沒再送到的舊筆不算
    local evict = CS.evictOrigin(st, origin)
    local at = entry.at[origin] or {}
    entry.at[origin] = at
    local have = entry.cnt[origin] or 0
    local keepN, keepCost = 0, 0
    if keep and keep == entry.keep[origin] then keepN, keepCost = entry.keepN[origin] or 0, entry.keepCost[origin] or 0 end
    local mine = keep and keepN or have
    local cost = entry.total - (evict and entry.cost[evict] or 0)
    if keep then cost = cost - (entry.cost[origin] or 0) + keepCost end
    local added = 0
    for k = 1, n do
        local m = marks[k]
        local key = C.key(m)
        if not at[key] then added = added + 1 end
        if not (keep and keep[key]) and (keep or not at[key]) then
            mine = mine + 1
            cost = cost + C.chunkCost(m)
        end
    end
    if mine > C.MAX_MARKS or cost > C.CHUNK_BUDGET then return fail("limit") end
    -- 套用
    local touched = {}
    if evict then
        CS.removeWhere(entry, function(m) return m.o == evict end, touched)
        st.origins[evict], st.on = nil, st.on - 1
    end
    if keep ~= entry.keep[origin] then entry.keepN[origin], entry.keepCost[origin] = 0, 0 end
    entry.keep[origin], entry.keepAt[origin] = keep, keep and nowMs or nil
    -- 舊筆加新筆會超過每個來源碼的上限（讀檔會整份拒收）：還沒再送到的舊筆先刪
    if keep and have + added > C.MAX_MARKS then
        CS.removeWhere(entry, function(m) return m.o == origin and not keep[C.key(m)] end, touched)
    end
    local kept, kn = {}, 0
    for k = 1, n do
        local m = marks[k]
        local key = C.key(m)
        local old = at[key]
        local crs = m.rs
        m.rs, m.o = old and old.rs or 0, origin
        -- 伺服器刷新過、這台電腦還沒處理到（客戶端的 rs 比較舊）：保留已刷新（整份重傳也用舊資料比），
        -- 並把那筆刷新回送給這台（它錯過了；不回送的話本機一直和伺服器不同、每次登入整份重傳）
        if old and old.rh > 0 and old.rs > crs then
            C.refresh(m, old.rh)
            kn = kn + 1
            kept[kn] = C.toWire(m)
        end
        -- 修改序號：狀態（對帳摘要的欄位）真的變了才發新的，整份重傳原樣送回來的不算更新
        m.us = old and C.digest(old) == C.digest(m) and old.us or CS.newSeq(st)
        if old then
            -- 就地換內容：外框鍵與 chunk 不變，索引與分組都還指著這個物件
            for f, v in pairs(m) do old[f] = v end
        else
            st.count = st.count + 1
            st.marks[st.count] = m
            CS.track(entry, m, 1)
        end
        touched[key] = true
        if keep and not keep[key] then
            keep[key] = true
            entry.keepN[origin] = entry.keepN[origin] + 1
            entry.keepCost[origin] = entry.keepCost[origin] + C.chunkCost(m)
        end
    end
    if done and keep then
        CS.removeWhere(entry, function(m) return m.o == origin and not keep[C.key(m)] end, touched)
        entry.keep[origin], entry.keepAt[origin] = nil, nil
    end
    if not st.origins[origin] then st.on = st.on + 1 end
    st.origins[origin] = nowMs
    if kn > 0 then CS.sendRefreshed(player, author, kept, kn, nil) end
    local share, wasShare = args.share == true, st.share
    st.share = share
    entry.dirty = true
    CS.summary(entry)
    if wasShare and not share then
        CS.eachViewerAll(entry, true, function(p, name) CS.send(p, "clrTeamRemove", { to = name, a = author }) end)
    elseif share and not wasShare then
        local all, an = CS.mergedWires(entry)
        CS.eachViewer(entry, function(p, name) CS.sendTeamMarks(p, name, entry, all, an) end)
    else
        CS.pushKeys(entry, touched)
    end
end

-- 刪除：只刪這位作者這台電腦（來源碼）的；沒有這筆＝已刪
function Commands.clrDrop(player, args, author)
    local fail = CS.failFn(player, author, "clrDrop", args)
    local C = CS.codecs()
    local hex = C and CS.hexOf(author)
    if not hex or type(args.keys) ~= "table" or not C.validOrigin(args.origin) then return end
    if not CS.rateOk(CS.lastDrop, author, getTimestampMs()) then return fail("rate") end
    CS.ensureIndex()
    local entry = CS.author(hex, author)
    if entry.readOnly or CS.indexReadOnly then return fail("readonly") end
    local st, origin = entry.store, args.origin
    local drop, dn, seen = {}, 0, 0
    for _, key in pairs(args.keys) do
        seen = seen + 1
        if seen > CS.MAX_PUT then break end -- 客戶端每包最多 MAX_PUT 筆；多的不看（不讓一包大清單吃 CPU）
        local x, y, w, h = C.parseKey(key)
        if x then
            drop[C.key({ x = x, y = y, w = w, h = h })] = true
            dn = dn + 1
        end
    end
    if dn == 0 then return end
    local touched = {}
    CS.removeWhere(entry, function(m) return m.o == origin and drop[C.key(m)] == true end, touched)
    if CS.empty(touched) then return end
    entry.dirty = true
    CS.summary(entry)
    CS.pushKeys(entry, touched)
end

-- 同步：先分批送這台電腦錯過的刷新，再回自己的筆數、摘要與序號，最後送看得到的隊友標記（分批，同 seq 收齊才替換）
function Commands.clrSync(player, args, name)
    local nowMs = getTimestampMs()
    if not CS.rateOk(CS.lastSync, name, nowMs) then return CS.send(player, "clrSyncRate", { to = name }) end
    local C = CS.codecs()
    local hex = C and CS.hexOf(name)
    local origin = args.origin
    if not hex or not C.validOrigin(origin) then return end
    CS.ensureIndex()
    CS.originOf[name] = origin
    local entry = CS.author(hex, name)
    local st = entry.store
    if st.origins[origin] then
        -- 只記在記憶體（滿 MAX_ORIGINS 時丟最久沒同步的）：同步本身不寫檔，等下次真的有變動一起寫
        -- （陣營／安全屋事件全服都會同步，每次都寫會讓每位線上作者整份重寫一次）
        st.origins[origin] = nowMs
    end
    local share = args.share == true
    if st.share ~= share and st.count > 0 and not entry.readOnly then
        local was = st.share
        st.share = share
        entry.dirty = true
        CS.summary(entry)
        if was then
            CS.eachViewerAll(entry, true, function(p, to) CS.send(p, "clrTeamRemove", { to = to, a = name }) end)
        else
            local all, an = CS.mergedWires(entry)
            CS.eachViewer(entry, function(p, to) CS.sendTeamMarks(p, to, entry, all, an) end)
        end
    end
    -- 客戶端的游標比伺服器新＝伺服器停機回滾過：這台電腦有序號的筆全部重送（客戶端比每筆的 rs，處理過的跳過），
    -- 游標改回伺服器的值
    local seen = type(args.seq) == "number" and args.seq or 0
    if seen > st.seq then seen = 0 end
    local refreshed, rn = {}, 0
    for i = 1, st.count do
        local m = st.marks[i]
        if m.o == origin and m.rs > seen then
            rn = rn + 1
            refreshed[rn] = C.toWire(m)
        end
    end
    CS.sendRefreshed(player, name, refreshed, rn, nil)
    local digest, count = C.storeDigest(st.marks, st.count, origin)
    CS.send(player, "clrSyncOk", { to = name, count = count, seq = st.seq, digest = digest,
        readOnly = (entry.readOnly or CS.indexReadOnly) or nil })
    -- 隊友標記：索引裡開了分享、而且現在看得到的作者才載入；載入後再看作者檔自己的分享旗標
    -- （索引可能比作者檔舊一輪寫檔）
    local list, n = {}, 0
    if CS.allowed() then
        local cand, cn = {}, 0
        for ahex, a in pairs(CS.index.authors) do
            if a.share and ahex ~= hex then
                cn = cn + 1
                cand[cn] = ahex
            end
        end
        for k = 1, cn do
            local aname = C.unhex(cand[k])
            if MinidoracatMiniMapGroups.canSee(aname, CS.SHARE_ALL, name) then
                local e = CS.author(cand[k], aname)
                if CS.canSee(e, name) then
                    local wires, wn = CS.mergedWires(e)
                    for i = 1, wn do
                        n = n + 1
                        list[n] = { a = aname, m = wires[i] }
                    end
                end
            end
        end
    end
    CS.seq = CS.seq + 1
    local parts = math.max(1, math.floor((n + CS.SNAP_BATCH - 1) / CS.SNAP_BATCH))
    for part = 1, parts do
        local marks, k = {}, 0
        for i = (part - 1) * CS.SNAP_BATCH + 1, math.min(n, part * CS.SNAP_BATCH) do
            k = k + 1
            marks[k] = list[i]
        end
        CS.send(player, "clrTeamSnap", { to = name, seq = CS.seq, part = part, parts = parts, marks = marks })
    end
end

CS.Commands = Commands
Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= CS.MODULE then return end
    local fn = Commands[command]
    -- 空表的 args 不上線（GameClient.java:1837、GameServer.java:2267-2278）：nil 當空表
    if not (fn and player and (args == nil or type(args) == "table")) then return end
    local name = MinidoracatMiniMapGroups.principal(player)
    if name then return fn(player, args or {}, name) end
    local to = player:getUsername()
    if CS.WRITES[command] and type(to) == "string" then CS.failFn(player, to, command, args or {})("identity") end
end)

-- B2：重新生成的 chunk ------------------------------------------------------------------
function CS.chunkXY(chunk)
    for x = 0, 7 do
        local sq = chunk:getGridSquare(x, 0, 0)
        if sq then return math.floor(sq:getX() / 8), math.floor(sq:getY() / 8) end
    end
    return nil
end

function CS.onLoadChunk(chunk)
    if not isServer() or not chunk:isNewChunk() then return end
    local idx = CS.index
    if not idx then return end -- 開服前（OnServerStarted 才載入索引、重建 chunk 表）
    local cx, cy = CS.chunkXY(chunk)
    if not cx then return end
    local C = CS.codecs()
    local key = C.fmtInt(cx) .. "," .. C.fmtInt(cy)
    local set = idx.chunks[key]
    if not set then return end
    if not CS.pendingChunks[key] then
        CS.pendingChunks[key] = { cx, cy }
        CS.pendingN = CS.pendingN + 1
    end
end

-- chunkList[k]＝{ cx, cy, ms? }（ms＝B3 的 RUN 毫秒：作者的 rms 已經到這裡就跳過）；回碰到的作者 { [hex] = true }
function CS.applyChunks(chunkList, n)
    local C = CS.codecs()
    local now = CS.now()
    local byAuthor, order, on = {}, {}, 0 -- [hex] = 碰到的 chunk 陣列
    for k = 1, n do
        local c = chunkList[k]
        local set = CS.index.chunks[C.fmtInt(c[1]) .. "," .. C.fmtInt(c[2])]
        if set then
            for hex in pairs(set) do
                local list = byAuthor[hex]
                if not list then
                    list = {}
                    byAuthor[hex] = list
                    on = on + 1
                    order[on] = hex
                end
                list[#list + 1] = c
            end
        end
    end
    local hit = {}
    for k = 1, on do
        local hex = order[k]
        local entry = CS.author(hex)
        local rms, grid, maxMs = entry.store.rms, {}, nil
        local list = byAuthor[hex]
        for i = 1, #list do
            local c = list[i]
            if not c[3] or c[3] > rms then
                local col = grid[c[1]] or {}
                grid[c[1]] = col
                -- B2＝true（一定套）；B3＝RUN 毫秒，同一個 chunk 有好幾次 RUN 取最新的（refreshGrid 比 rs）
                local v = col[c[2]]
                if not c[3] then
                    col[c[2]] = true
                elseif v ~= true and (not v or c[3] > v) then
                    col[c[2]] = c[3]
                end
                if c[3] and (not maxMs or c[3] > maxMs) then maxMs = c[3] end
            end
        end
        local out = {}
        CS.refreshGrid(entry, grid, now, out)
        if maxMs then
            entry.store.rms = maxMs
            entry.dirty = true
            hit[hex] = true
        end
        CS.notifyRefreshed(entry, out)
    end
    return hit
end

function CS.flushChunks()
    if CS.pendingN == 0 then return end
    local list, n = {}, 0
    for _, xy in pairs(CS.pendingChunks) do
        n = n + 1
        list[n] = xy
    end
    CS.pendingChunks, CS.pendingN = {}, 0
    CS.applyChunks(list, n)
end

-- B3：重置清單 ------------------------------------------------------------------------
-- 格式（tab 分欄，UTF-8，最新的在最前面、最多 MAX_RUNS 次執行）：
--   MMRESETS <版本 1> <最新 run id>
--   RUN <run id> <epoch 毫秒> <chunk 數>
--   C <cx>,<cy>;<cx>,<cy>;…     （一次執行可以有多行 C，加起來＝chunk 數）
--   END <RUN 數>
-- run id 只收 [A-Za-z0-9_-.:]、最長 64；RUN 的毫秒要由新到舊嚴格遞減；任何一行不合整份拒收。
-- 回 runs（陣列，最新在前）或 nil, 原因
function CS.parseResets(lines, n)
    local C = CS.codecs()
    local split = C.split
    local hf, hn = split(n > 0 and lines[1] or "", "\t", 3)
    if not (hf and hn == 3 and hf[1] == "MMRESETS") then return nil, "header" end
    if hf[2] ~= "1" then return nil, "version" end
    if not C.validRun(hf[3]) or n < 2 then return nil, "header" end
    local runs, rn, cur, seen = {}, 0, nil, {}
    local function close()
        return not cur or cur.got == cur.count
    end
    for li = 2, n - 1 do
        local line = lines[li]
        local f, fn = split(line, "\t", 4)
        if f and fn == 4 and f[1] == "RUN" then
            if not close() then return nil, "count" end
            local ms, count = f[3]:match("^%d+$") and tonumber(f[3]), f[4]:match("^%d+$") and tonumber(f[4])
            if not (C.validRun(f[2]) and ms and count) or seen[f[2]] or #f[3] > 15 or #f[4] > 9 then
                return nil, "run"
            end
            if cur and ms >= cur.ms then return nil, "order" end
            seen[f[2]] = true
            cur = { id = f[2], ms = ms, count = count, got = 0, chunks = {} }
            rn = rn + 1
            if rn > CS.MAX_RUNS then return nil, "runs" end
            runs[rn] = cur
        elseif f and fn == 2 and f[1] == "C" and cur then
            local items, k = split(f[2], ";", 1000000)
            if not items then return nil, "chunk" end
            for i = 1, k do
                local xy, xn = split(items[i], ",", 2)
                local cx = xy and xn == 2 and xy[1]:match("^%-?%d+$") and tonumber(xy[1])
                local cy = cx and xy[2]:match("^%-?%d+$") and tonumber(xy[2])
                if not cy or #items[i] > 24 then return nil, "chunk" end
                cur.got = cur.got + 1
                cur.chunks[cur.got] = { cx, cy, cur.ms }
            end
            if cur.got > cur.count then return nil, "count" end
        else
            return nil, "line"
        end
    end
    if not close() then return nil, "count" end
    if lines[n] ~= "END\t" .. rn or rn == 0 or runs[1].id ~= hf[3] then return nil, "end" end
    return runs
end

-- 第一行（只看最新 run id）
function CS.resetsHeadLine(path)
    local reader = getFileReader(path, false)
    if not reader then return nil end
    local ok, line = pcall(function() return reader:readLine() end)
    pcall(function() reader:close() end)
    return ok and line or nil
end

function CS.checkResets()
    local idx = CS.ensureIndex()
    if CS.indexReadOnly then return end
    local path = CS.resetsPath()
    if not cacheFileExists(path) then return end
    local head = CS.resetsHeadLine(path)
    if not head or head == CS.resetsHead then return end
    local pending = CS.runPending
    local latest = head:match("^MMRESETS\t1\t(.+)$")
    if latest and latest == (pending and pending.run or idx.run) then
        CS.resetsHead = head
        return
    end
    local _, Codec = CS.codecs()
    local lines, n = Codec.readLines(path)
    if not lines then
        CS.warn("resets:" .. head .. ":unreadable", "resets: cannot read " .. path)
        return
    end
    local runs, why = CS.parseResets(lines, n)
    if not runs then
        CS.warn("resets:" .. head .. ":" .. tostring(why), "resets: rejected " .. path .. ": " .. tostring(why))
        return
    end
    -- 最新在前：只套比水位晚的（水位＝max(索引建立時間, 已套用的最新 RUN 毫秒)），也停在上次套用的 run id
    local water = math.max(idx.since or 0, idx.ms or 0, pending and pending.ms or 0)
    local list, ln = {}, 0
    for i = 1, #runs do
        local r = runs[i]
        if r.id == idx.run or r.ms <= water then break end
        for k = 1, r.got do
            ln = ln + 1
            list[ln] = r.chunks[k]
        end
    end
    local hit = CS.applyChunks(list, ln)
    local hexes = pending and pending.hexes or {}
    for hex in pairs(hit) do hexes[hex] = true end
    CS.runPending = { run = runs[1].id, ms = math.max(water, runs[1].ms), hexes = hexes }
    CS.resetsHead = head
    print("[MinidoracatMiniMap] ClearedShare resets: applied up to " .. runs[1].id .. " (" .. ln .. " chunks)")
end

-- 計時：寫檔、B2 佇列、B3、閒置作者 ---------------------------------------------------------
function CS.evict(nowMs)
    local gone, gn = {}, 0
    for hex, entry in pairs(CS.authors) do
        if not entry.dirty and nowMs - (entry.touched or 0) > CS.EVICT_MS and not CS.online(entry.name) then
            gn = gn + 1
            gone[gn] = hex
        end
    end
    for i = 1, gn do CS.authors[gone[i]] = nil end
end

function CS.tick()
    if not isServer() or not CS.index then return end
    CS.flushChunks()
    local nowMs = getTimestampMs()
    if CS.saveQueue then
        CS.saveStep()
    elseif nowMs >= CS.saveAt then
        CS.saveAt = nowMs + CS.SAVE_MS
        CS.saveStart()
    end
    if nowMs >= CS.resetsAt then
        CS.resetsAt = nowMs + CS.RESETS_CHECK_MS
        local ok, err = pcall(CS.checkResets)
        if not ok then CS.warn("resetsError", "resets: " .. tostring(err)) end
        CS.evict(nowMs)
    end
end

Events.LoadChunk.Add(CS.onLoadChunk)
Events.OnTickEvenPaused.Add(CS.tick)
Events.OnServerStarted.Add(function()
    if not isServer() then return end
    CS.ensureIndex()
    CS.resetsAt = 0 -- 下一個 tick 讀重置清單
end)
