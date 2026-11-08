-- MinidoracatMiniMap_RemoteSymbols.lua
-- 本檔範圍：其他玩家分享的地圖標記（原版 B42 多人的「分享」）——作者清單資料、切換作者的規則
-- （設定分類的作者按鈕與清單視窗 _RemoteList.lua 共用）、「只看陣營與安全屋成員」篩選、世界地圖右鍵「隱藏 X 的標記」，
-- 與自己新放的標記預設分享給誰（檔尾）。
-- 隱藏名單是原版的：WorldMapSymbolsV2.setAuthorHidden 送伺服器、存 hidden_authors.ini，
-- 玩家登入時送回（HiddenAuthors.java:64-99、GameServer.java:2877-2895），本 MOD 不另存；
-- 小地圖與世界地圖共用 MapItem 單例的同一份標記（ISMiniMap.lua:193），隱藏對兩張地圖同時生效。
-- 「只看陣營與安全屋成員」（ModOptions RemoteTrustedOnly）不碰這份名單，改用每則標記的本機可見旗標
-- （WorldMapBaseSymbolV2.setVisible：畫圖與 hitTest 都看它，WorldMapBaseSymbol.java:233-275、
-- SymbolsRenderData.java:30、WorldMapSymbols.java:182），不存檔也不上傳。
-- 主開關 RemoteSymbols 的存檔與兩張地圖同步在主檔（applyToggleOptions、Core.syncRemoteSymbols）。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

-- 任一張開著的地圖的符號 API：先找該玩家的小地圖，沒有（沙盒關小地圖）就用世界地圖單例
local function symbolsApi(pn)
    local mm = getPlayerMiniMap(pn)
    local mapAPI = mm and mm.inner and mm.inner.mapAPI
    if not mapAPI and ISWorldMap_instance then mapAPI = ISWorldMap_instance.mapAPI end
    return mapAPI and mapAPI:getSymbolsAPIv2() or nil
end

-- 照抄原版可見規則（WorldMapBaseSymbol.java:250-270）：全部可見／同陣營／同安全屋／指名給我
local function visibleToMe(s, me)
    if s:isVisibleToEveryone() then return true end
    local author = s:getAuthor()
    if s:isVisibleToFaction() then
        local faction = Faction.getPlayerFaction(me)
        if faction and faction == Faction.getPlayerFaction(author) then return true end
    end
    if s:isVisibleToSafehouse() then
        local house = SafeHouse.hasSafehouse(me)
        if house and house == SafeHouse.hasSafehouse(author) then return true end
    end
    for i = 0, s:getVisibleToPlayerCount() - 1 do
        if s:getVisibleToPlayerByIndex(i) == me then return true end
    end
    return false
end

-- 圈內人：跟我同陣營（回 "faction"），或跟我同一間安全屋（回 "safehouse"）；圈外回 nil。判法同原版可見規則的
-- 身分比對（WorldMapBaseSymbol.java:252-262，getPlayerFaction／hasSafehouse 取第一個符合的，同一個物件才算）；
-- 同一輪查詢記在 memo
local function circle(faction, house)
    local memo = {}
    return function(author)
        local t = memo[author]
        if t == nil then
            t = (faction ~= nil and Faction.getPlayerFaction(author) == faction and "faction")
                or (house ~= nil and SafeHouse.hasSafehouse(author) == house and "safehouse") or false
            memo[author] = t
        end
        return t or nil
    end
end

-- 作者清單資料：{ key = 帳號, count = 標記數, tag = "faction"|"safehouse"|nil, trusted = 圈內人,
-- label = "帳號（標記數）" }，依帳號排序（設定分類的作者按鈕用 label，清單視窗用 key／count／tag）。
-- 只列別人分享、而且沒被隱藏時你本來就看得到的：引擎把每則分享標記送給每個客戶端
-- （WorldMapServer.java:154-163、238-249），不套可見規則會露出只分享給陣營的作者名。
-- 已隱藏的作者照列（清單要能把他放回來）
function Core.remoteSymbolAuthors(pn)
    if not isClient() then return {} end
    local player = getSpecificPlayer(pn)
    local api = player and symbolsApi(pn)
    if not api then return {} end
    local me = player:getUsername()
    local inCircle = circle(Faction.getPlayerFaction(me), SafeHouse.hasSafehouse(me))
    local count, keys = {}, {}
    for i = 0, api:getSymbolCount() - 1 do
        local s = api:getSymbolByIndex(i)
        if s:isShared() and not s:isAuthorLocalPlayer() and visibleToMe(s, me) then
            local author = s:getAuthor()
            if not count[author] then
                -- 依帳號插入排序（家規禁 table.sort：Kahlua 遞迴 quicksort，verify_mod.py 守衛）；
                -- 作者數小，O(n²) 無妨
                local pos = #keys + 1
                while pos > 1 and keys[pos - 1] > author do
                    keys[pos] = keys[pos - 1]
                    pos = pos - 1
                end
                keys[pos] = author
            end
            count[author] = (count[author] or 0) + 1
        end
    end
    local items = {}
    for i = 1, #keys do
        local author = keys[i]
        local tag = inCircle(author)
        items[i] = { key = author, count = count[author], tag = tag, trusted = tag ~= nil,
            label = getText("UI_MinidoracatMiniMap_RemoteAuthorChip", author, tostring(count[author])) }
    end
    return items
end

function Core.remoteSymbolHidden(author)
    local api = symbolsApi(0)
    return api ~= nil and api:isAuthorHidden(author) == true
end

-- 本 MOD 改隱藏名單的次數（右鍵、chip、全部顯示都走下面這支）；設定視窗用它判斷 chip 要不要重畫
local hiddenRevision = 0
-- 陣營或安全屋的成員數（沒有＝-1），簽章用
local function groupSize(group) return group and group:getPlayers():size() or -1 end

-- 原版每呼叫一次就送一個封包（HiddenAuthors.java:109-114）：值沒變就不送
function Core.setRemoteSymbolHidden(author, hidden)
    local api = symbolsApi(0)
    if api and api:isAuthorHidden(author) ~= hidden then
        api:setAuthorHidden(author, hidden)
        hiddenRevision = hiddenRevision + 1
    end
end

-- 作者清單的簽章：標記數、我的陣營與安全屋和人數、本 MOD 改過隱藏名單幾次。設定視窗停在這個分類時
-- 定期比對，變了就重畫 chip（新分享、有人加入或退出、在世界地圖右鍵隱藏）。原版「分享」面板改的
-- 隱藏名單不在簽章裡，要切換分類或重開視窗才會反映
function Core.remoteListSig(pn)
    local player = getSpecificPlayer(pn or 0)
    local api = player and symbolsApi(pn or 0)
    if not api then return "" end
    local me = player:getUsername()
    local faction, house = Faction.getPlayerFaction(me), SafeHouse.hasSafehouse(me)
    return table.concat({ api:getSymbolCount(), tostring(faction), groupSize(faction), tostring(house),
        groupSize(house), hiddenRevision }, "|")
end

-- chip 亮不亮＝這位作者的標記畫不畫（主開關另計）：沒被隱藏，而且沒開「只看陣營與安全屋」或他是圈內人
function Core.remoteAuthorShown(item)
    if Core.remoteSymbolHidden(item.key) then return false end
    return item.trusted or Core.getBoolOption("RemoteTrustedOnly", false) ~= true
end

-- 現在是不是圈內人（現查：設定視窗開著時有人加入或退出陣營，chip 上的 trusted 還是建清單那一刻的）
function Core.remoteAuthorTrusted(author)
    local player = getSpecificPlayer(0)
    if not player then return false end
    local me = player:getUsername()
    return circle(Faction.getPlayerFaction(me), SafeHouse.hasSafehouse(me))(author) ~= nil
end

-- 開著「只看陣營與安全屋」時點開圈外作者 keep：離開這個模式前，其他圈外作者先記進原版隱藏名單，
-- 畫面上維持關閉、只放出 keep（使用者裁定 2026-10-08）。圈內人不動
function Core.remoteHideOutsiders(keep, pn)
    local items = Core.remoteSymbolAuthors(pn or 0)
    for i = 1, #items do
        local it = items[i]
        if not it.trusted and it.key ~= keep then Core.setRemoteSymbolHidden(it.key, true) end
    end
end

-- 「全部顯示」：清單上的作者全部放回。原版名單沒有列舉 API（HiddenAuthors.java:101-118），
-- 目前沒分享給你的作者放不回來，等他再分享時會出現在清單上
function Core.remoteShowAllAuthors(pn)
    local items = Core.remoteSymbolAuthors(pn or 0)
    for i = 1, #items do Core.setRemoteSymbolHidden(items[i].key, false) end
end

-- 改「只看陣營與安全屋」並套用；套用尾端的 Core.settingsAfterApply 讓開著的設定視窗重畫
local function setTrustedOnly(on)
    local opt = Core.modOptions and Core.modOptions:getOption("RemoteTrustedOnly")
    if not opt then return end
    opt:setValue(on)
    Core.modOptions:apply()
    PZAPI.ModOptions:save()
end

-- 切換一位作者（設定分類的作者按鈕、清單視窗的列共用）。開著「只看陣營與安全屋」時點亮圈外作者＝離開
-- 這個模式：其他圈外作者先記進隱藏名單維持關閉，只放出這一位（使用者裁定 2026-10-08）。
-- 圈內人現查，不用清單建立時的 trusted：視窗開著時有人加入陣營，快照會讓點擊誤關篩選
function Core.remoteAuthorSet(author, on, pn)
    if on and Core.getBoolOption("RemoteTrustedOnly", false) and not Core.remoteAuthorTrusted(author) then
        Core.remoteHideOutsiders(author, pn)
        setTrustedOnly(false)
    end
    Core.setRemoteSymbolHidden(author, not on)
end

-- 一次切換多位（設定分類的全選／全不選、清單視窗底部兩顆按鈕只傳目前清單上的作者）。點亮的人裡有
-- 圈外作者＝直接離開「只看陣營與安全屋」，不必先把其他圈外作者記進隱藏名單
function Core.remoteAuthorSetMany(list, on)
    if on and Core.getBoolOption("RemoteTrustedOnly", false) then
        for i = 1, #list do
            if not Core.remoteAuthorTrusted(list[i].key) then
                setTrustedOnly(false)
                break
            end
        end
    end
    for i = 1, #list do Core.setRemoteSymbolHidden(list[i].key, not on) end
end

-- 上次套用「只看陣營與安全屋」時的狀態：模式、標記數、我的陣營與安全屋和它們的人數
local applied = { on = false, n = -1 }
-- 本 MOD 藏起來的標記：包裝物件 -> 作者。標記增刪會讓索引位移，所以記物件；包裝物件是池化的，
-- 那則被移除後可能接給另一則新標記（WorldMapSymbolsV2.java:245-263），動它之前先核對作者
local scopeHidden = {}

-- 把「只看陣營與安全屋」套到目前所有別人分享的標記：圈外的不畫，圈內的不碰。新收到的標記預設可見
-- （WorldMapBaseSymbol.java:42），所以標記數或圈內人數一變就重套；作者改內容沿用同一個物件
-- （WorldMapClient.java:107-121），旗標不會被洗掉。一直沒開＝直接返回，不掃標記。
-- 只放回自己藏過的：圈內與沒藏過的標記交給原版或別的 MOD（TwisTonFire 的縮放門檻）決定畫不畫
-- ponytail: 同一個檢查間隔內標記一增一減、或圈內一進一出，會等到下一次變動才重套；要更準得自己記標記 ID
function Core.remoteScopeApply()
    if not isClient() then return end
    local on = Core.getBoolOption("RemoteTrustedOnly", false) == true
    if not (on or applied.on) then return end
    local player = getSpecificPlayer(0)
    local api = player and symbolsApi(0)
    if not api then return end
    local me = player:getUsername()
    local faction, house = Faction.getPlayerFaction(me), SafeHouse.hasSafehouse(me)
    local n, fn, hn = api:getSymbolCount(), groupSize(faction), groupSize(house)
    if on == applied.on and n == applied.n and faction == applied.faction and fn == applied.fn
            and house == applied.house and hn == applied.hn then
        return
    end
    applied.on, applied.n, applied.faction, applied.fn, applied.house, applied.hn = on, n, faction, fn, house, hn
    local inCircle = circle(faction, house)
    local was = scopeHidden
    scopeHidden = {}
    for i = 0, (on and n or 0) - 1 do
        local s = api:getSymbolByIndex(i)
        if s:isShared() and not s:isAuthorLocalPlayer() and not inCircle(s:getAuthor()) then
            scopeHidden[s] = s:getAuthor()
            s:setVisible(false)
        end
    end
    local shown = false
    for s, author in pairs(was) do
        if not scopeHidden[s] and s:getAuthor() == author then s:setVisible(true); shown = true end
    end
    -- 放回的若是 TwisTonFire 手繪點，請它下一幀重套縮放門檻（它的 tracker.dirty，TTF_MapInk_Tools.lua:697）
    local ui = shown and ISWorldMap_instance and ISWorldMap_instance.symbolsUI
    local tracker = ui and ui.ttf_mapInkSketchTracker
    if tracker then tracker.dirty = true end
end

-- 每 30 tick 比一次狀態（約半秒；原版用例 client/Chat/ISChat.lua:943）
local scopeTicks = 0
Events.OnTick.Add(function()
    scopeTicks = scopeTicks + 1
    if scopeTicks < 30 then return end
    scopeTicks = 0
    Core.remoteScopeApply()
end)

-- 把本 MOD 藏的再藏一次（下面的 TwisTonFire 包裝用；經 Core 呼叫，本檔重載後包裝讀到的是新的 scopeHidden）
function Core.remoteScopeRehide()
    for s, author in pairs(scopeHidden) do
        if s:getAuthor() == author then s:setVisible(false) end
    end
end

-- TwisTonFire 手繪（mod twistmapimprovements）：世界地圖每次 prerenderMap 先呼叫 TTF_MapInk.ApplySketchZoomVisibility
-- （TTF_MapInk_Boot.lua:462-468）；縮放、標記數或它的設定一變，就對所有手繪點（symbolID TTF_mapInkDot 與長得像的）
-- setVisible(縮放門檻)（TTF_MapInk_Tools.lua:683-727），會把上面藏的圈外手繪點放出來。包它：它真的重設過
-- （重設前 tracker 是髒的，或縮放、門檻、標記數記錄變了），就在畫之前把本 MOD 藏的再藏回去，不必等下次檢查。
-- 它的 tracker 欄位改名時退成每次都重藏。沒裝或單機＝不包；兩邊載入順序不定，遊戲開始才包，包過的不再包
Events.OnGameStart.Add(function()
    local ttf = TTF_MapInk
    local base = isClient() and ttf and ttf.ApplySketchZoomVisibility
    if not base or base == ttf.minidoracatScopeWrap then return end
    ttf.minidoracatScopeWrap = function(ui, ...)
        local t = ui and ui.ttf_mapInkSketchTracker
        local quiet = t and not t.dirty and not t.rebuild
        local zoom, minZoom, count = quiet and t.lastZoomF, quiet and t.lastBaseMinZoom, quiet and t.symbolCount
        base(ui, ...)
        if quiet and t.lastZoomF == zoom and t.lastBaseMinZoom == minZoom and t.symbolCount == count then return end
        Core.remoteScopeRehide()
    end
    ttf.ApplySketchZoomVisibility = ttf.minidoracatScopeWrap
end)

-- 世界地圖右鍵：游標下是別人分享的標記，就加「隱藏 X 的標記」。hitTest 只命中畫得出來、
-- 至少 10px 的使用者標記（WorldMapSymbols.java:181-197），所以已隱藏的作者、關掉「其他玩家
-- 標記」時的、被「只看陣營與安全屋」篩掉的、縮得太小的都不會出現；自己的標記與私人標記也不出現
function Core.remoteSymbolHideOption(context, mapUI, x, y)
    if not isClient() then return end
    local api = mapUI.mapAPI and mapUI.mapAPI:getSymbolsAPIv2()
    if not api then return end
    local index = api:hitTest(x, y)
    if index < 0 then return end
    local s = api:getSymbolByIndex(index)
    if not s:isShared() or s:isAuthorLocalPlayer() then return end
    local author = s:getAuthor()
    context:addOption(getText("UI_MinidoracatMiniMap_HideAuthor", author), author, function(name)
        Core.setRemoteSymbolHidden(name, true)
    end)
end

-- 自己新放的標記預設分享（ModOptions SymbolShareDefault：1 私人＝原版、2 全部可見、3 陣營與安全屋）。原版放好的
-- 標記一律私人（WorldMapBaseSymbol.java:67-73），要按符號面板的「分享」再點標記才分享（ISWorldMapSharing.lua:429-459）。
-- 包原版放標記與放文字（ISWorldMapSymbols.lua:127-144、239-285），加好後照選項 setSharing，表的寫法同 applyChanges。
-- setSharing 把本機那份送上伺服器並移除，伺服器加好再廣播回來（WorldMapClient.java:221-241、WorldMapServer.java:80-98），
-- 所以要等原版把顏色、大小、角度都設好才送。只管世界地圖：紙本地圖的標記存在地圖物品裡，原版也只在世界地圖給「分享」
-- （ISWorldMapSymbols.lua:1281）
local SHARE_DEFAULT = { [2] = { everyone = true }, [3] = { everyone = false, faction = true, safehouse = true } }
local function shareNewSymbol(tool, s)
    if not (isClient() and tool.symbolsUI and tool.symbolsUI.isWorldMap) then return end
    local sharing = SHARE_DEFAULT[Core.getComboIndex("SymbolShareDefault", 1)]
    if sharing and s:isPrivate() then s:setSharing(sharing) end
end
for _, hook in ipairs({ { ISWorldMapSymbolTool_AddSymbol, "addSymbol" }, { ISWorldMapSymbolTool_AddNote, "onNoteAdded" } }) do
    local class, method = hook[1], hook[2]
    local original = class and class[method]
    if original then
        class[method] = function(self, ...)
            local api = self.symbolsAPI
            local before = api:getSymbolCount()
            local result = original(self, ...)
            -- 新的一則接在清單最後（WorldMapSymbols.java:99-105）；沒加成（空字、按取消）數量不變
            local n = api:getSymbolCount()
            if n == before + 1 then shareNewSymbol(self, api:getSymbolByIndex(n - 1)) end
            return result
        end
    end
end
-- 移動工具按住 Shift 拖＝複製（ISWorldMapSymbols.lua:601-617）：複本在拖曳開始就加進清單、放開才定位，而且不帶
-- 分享資訊（WorldMapBaseSymbol.java:510-534）。拖曳中分享會把正在拖的本機那則移除，所以放開後才分享。
-- 手把 A 放下（onJoypadDownInMap）不包：手把要另按鍵盤 Shift 才會複製
local originalMoveUp = ISWorldMapSymbolTool_MoveAnnotation and ISWorldMapSymbolTool_MoveAnnotation.onMouseUp
if originalMoveUp then
    function ISWorldMapSymbolTool_MoveAnnotation:onMouseUp(x, y)
        local copy = self.isCopying and self.dragging
        local result = originalMoveUp(self, x, y)
        if copy then shareNewSymbol(self, copy) end
        return result
    end
end
