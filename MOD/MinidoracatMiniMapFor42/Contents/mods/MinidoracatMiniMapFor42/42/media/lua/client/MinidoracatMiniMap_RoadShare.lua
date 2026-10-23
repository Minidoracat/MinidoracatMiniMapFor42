-- MinidoracatMiniMap_RoadShare.lua
-- 自訂道路分享（客戶端）：送出／收回、接收伺服器的分享道路、分享表單、回饋。伺服器端在
-- server/MinidoracatMiniMapRoadShare.lua（存檔、收件人判斷）；道路資料在 _Roads.lua（Core.roads*）。
-- 伺服器回覆都帶 to（收件角色名）：分割畫面共用一條連線，照 to 分到對應的 pn（同 _Nav.lua sharedTarget）。
-- 單機不提供分享。PZ API：sendClientCommand／OnServerCommand（ClientCommands.lua:453、ServerCommands.lua:194）；
-- Faction.getPlayerFaction(String)、faction:getOwner()／getPlayers()（Faction.java:123、241、281）；
-- SafeHouse.hasSafehouse(String)、getSafehouseList()、getOwner()／getPlayers()（SafeHouse.java:97、640-658）；
-- 事件 SyncFaction（ISFactionUI.lua:445）、OnSafehousesChanged（ISSafehouseUI.lua:443）。
-- 表單用 UI 框架 rev 17 元件（UI.Window、UI.Checkbox、UI.Button），手把交給表單擁有者（同 _RemoteList.lua）。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) or Core.roadShareAvailable then return end

local S = {
    MODULE = "MinidoracatMiniMapRoads",
    SYNC_DELAY_MS = 1000, -- 防抖：登入時 SyncFaction／OnSafehousesChanged 會連發
    snaps = {},  -- [pn] = { seq, parts, got, have = { [part] = roads } }
    syncAt = {}, -- [pn] = 要送 roadSync 的時刻
    lastPolicy = nil,
    PAD = 10,
}

function S.say(pn, text, good)
    if Core.navMessage then Core.navMessage(pn, text, good) end
end

function S.pnOf(to)
    if type(to) ~= "string" then return nil end
    for pn = 0, 3 do
        local p = getSpecificPlayer(pn)
        if p and p:getUsername() == to then return pn end
    end
    return nil
end

function S.policyOn()
    local P = Core.policy
    return P ~= nil and P.readBool("AllowRoadShare", true) == true
end

-- 一個群組可以用的人數（含離線）：owner＋成員，不含自己
function S.groupCount(me, owner, list, seen)
    local n = 0
    local function add(name)
        if name and name ~= me and not seen[name] then
            seen[name] = true
            n = n + 1
        end
    end
    add(owner)
    for i = 0, list:size() - 1 do add(list:get(i)) end
    return n
end

-- 表單用：{ factionName=, factionCount= }（沒有陣營＝nil）、safehouseCount（沒有安全屋＝nil）
function S.groups(me)
    local out = {}
    local f = Faction.getPlayerFaction(me)
    if f then
        out.factionName = f:getName()
        out.factionCount = S.groupCount(me, f:getOwner(), f:getPlayers(), {})
    end
    if SafeHouse.hasSafehouse(me) then
        local seen, n, houses = {}, 0, SafeHouse.getSafehouseList()
        for i = 0, houses:size() - 1 do
            local h = houses:get(i)
            if h:getOwner() == me or h:getPlayers():contains(me) then
                n = n + S.groupCount(me, h:getOwner(), h:getPlayers(), seen)
            end
        end
        out.safehouseCount = n
    end
    return out
end

-- 功能閘門 share（addon 例：錶沒有通訊）只擋送出；已收到的路照常顯示與導航（docs/addon-api.md 功能閘門）
Core.roadShareAvailable = function(pn)
    if not isClient() then return false, "UI_MinidoracatMiniMap_RoadShareNoSP" end
    if not S.policyOn() then return false, "UI_MinidoracatMiniMap_RoadShareWhy_disabled" end
    local fa = Core.featureAllowed
    if fa then
        local allowed, key = fa(pn, "share")
        if allowed == false then
            return false, type(key) == "string" and key or "UI_MinidoracatMiniMap_FeatureUnavailable"
        end
    end
    local p = getSpecificPlayer(pn)
    local me = p and p:getUsername()
    if not me then return false, "UI_MinidoracatMiniMap_RoadShareNoSP" end
    if not Faction.getPlayerFaction(me) and not SafeHouse.hasSafehouse(me) then
        return false, "UI_MinidoracatMiniMap_RoadShareNoGroup"
    end
    return true
end

function S.failText(reasonKey)
    return getText("UI_MinidoracatMiniMap_RoadShareFail", getText(reasonKey))
end

-- Roads 在儲存／改名／改分享旗（已 rev+1）後呼叫
Core.roadSharePut = function(pn, road)
    local Codec = MinidoracatMiniMapRoadCodec
    local ok, why = Core.roadShareAvailable(pn)
    local p = getSpecificPlayer(pn)
    if ok and not (Codec and p and p:getOnlineID() >= 0) then ok, why = false, "UI_MinidoracatMiniMap_RoadShareWhy_disabled" end
    if not ok then
        S.say(pn, S.failText(why), false)
        return false, why
    end
    sendClientCommand(p, S.MODULE, "roadPut", { lid = Codec.lid(road), sid = road.sid, rev = road.rev,
        road = Codec.toWire(road) })
    return true
end

-- 收回不看沙盒與閘門（伺服器關掉分享時作者照樣能撤回）；回覆 roadDropped 才清本機 sid 與待撤回
Core.roadShareDrop = function(pn, sid)
    local p = isClient() and getSpecificPlayer(pn)
    if not (p and type(sid) == "string" and p:getOnlineID() >= 0) then return false end
    sendClientCommand(p, S.MODULE, "roadDrop", { sid = sid })
    return true
end

-- 伺服器回覆 ---------------------------------------------------------------------------
function S.decode(wire)
    local Codec = MinidoracatMiniMapRoadCodec
    local road = Codec and Codec.fromWire(wire)
    if road and road.sid and road.author then return road end
    return nil
end

function S.whoText(share)
    if share.faction and share.safehouse then return getText("UI_MinidoracatMiniMap_RoadShareWhoBoth") end
    return getText(share.faction and "UI_MinidoracatMiniMap_RoadShareWhoFaction" or "UI_MinidoracatMiniMap_RoadShareWhoSafehouse")
end

function S.ownBySid(pn, sid)
    local list = Core.roadsList and Core.roadsList(pn) or {}
    local i = 1
    while list[i] ~= nil do
        if list[i].sid == sid then return list[i] end
        i = i + 1
    end
    return nil
end

-- 分批的 snap：同一個 seq 收齊才整批替換；換 seq＝丟掉舊的半批
function S.onSnap(pn, args)
    local seq, part, parts = args.seq, args.part, args.parts
    if type(seq) ~= "number" or type(part) ~= "number" or type(parts) ~= "number"
        or part < 1 or part > parts or parts > 10000 or part % 1 ~= 0 or parts % 1 ~= 0 then return end
    local b = S.snaps[pn]
    if not b or b.seq ~= seq then
        b = { seq = seq, parts = parts, got = 0, have = {} }
        S.snaps[pn] = b
    end
    if b.parts ~= parts or b.have[part] then return end
    b.have[part] = type(args.roads) == "table" and args.roads or {}
    b.got = b.got + 1
    if b.got < parts then return end
    S.snaps[pn] = nil
    local list, n = {}, 0
    for k = 1, parts do
        local roads, i = b.have[k], 1
        while roads[i] ~= nil do
            local road = S.decode(roads[i])
            if road then
                n = n + 1
                list[n] = road
            end
            i = i + 1
        end
    end
    if Core.roadsReplaceReceived then Core.roadsReplaceReceived(pn, list) end
end

S.handlers = {
    roadPutOk = function(pn, args)
        local Codec = MinidoracatMiniMapRoadCodec
        local road = Codec and Core.roadsGet and Core.roadsGet(pn, (Codec.splitLid(args.lid)))
        if not road then return end
        if road.sid ~= args.sid and Core.roadsSetSid then Core.roadsSetSid(pn, road.id, args.sid) end
        S.say(pn, getText("UI_MinidoracatMiniMap_RoadShareOk", road.name, S.whoText(road.share),
            tostring(args.members or 0), tostring(args.online or 0)), true)
    end,
    roadPutFail = function(pn, args)
        local key = "UI_MinidoracatMiniMap_RoadShareWhy_" .. tostring(args.reason)
        S.say(pn, S.failText(getTextOrNull(key) and key or "UI_MinidoracatMiniMap_RoadShareWhy_invalid"), false)
    end,
    roadDropped = function(pn, args)
        if Core.roadsClearPendingDrop then Core.roadsClearPendingDrop(pn, args.sid) end
        local road = S.ownBySid(pn, args.sid)
        if not road then return end
        if Core.roadsSetSid then Core.roadsSetSid(pn, road.id, nil) end
        S.say(pn, getText("UI_MinidoracatMiniMap_RoadShareDropped", road.name), true)
    end,
    roadDropFail = function(pn, args)
        -- notowner＝伺服器上這個 sid 已經不是我們的路，沒有東西可撤，待撤回清掉
        if args.reason == "notowner" and Core.roadsClearPendingDrop then Core.roadsClearPendingDrop(pn, args.sid) end
        local key = "UI_MinidoracatMiniMap_RoadShareWhy_" .. tostring(args.reason)
        S.say(pn, getText("UI_MinidoracatMiniMap_RoadShareDropFail",
            getText(getTextOrNull(key) and key or "UI_MinidoracatMiniMap_RoadShareWhy_savefailed")), false)
    end,
    roadUpsert = function(pn, args)
        local road = S.decode(args.road)
        if road and Core.roadsUpsertReceived then Core.roadsUpsertReceived(pn, road) end
    end,
    roadRemove = function(pn, args)
        if type(args.sid) == "string" and Core.roadsRemoveReceived then Core.roadsRemoveReceived(pn, args.sid) end
    end,
    roadSnap = S.onSnap,
}

Events.OnServerCommand.Add(function(module, command, args)
    if module ~= S.MODULE or type(args) ~= "table" then return end
    local fn = S.handlers[command]
    local pn = fn and S.pnOf(args.to)
    if pn then fn(pn, args) end
end)

-- 同步：登入（OnCreatePlayer）、換陣營、換安全屋、沙盒開關變了，防抖後每位本機玩家要一次清單 ----------
function S.requestSync(pn)
    local due = getTimestampMs() + S.SYNC_DELAY_MS
    for p = 0, 3 do
        if pn == nil or pn == p then S.syncAt[p] = due end
    end
end

function S.tick()
    if not isClient() then return end
    local on = S.policyOn()
    if on ~= S.lastPolicy then
        S.lastPolicy = on
        S.requestSync()
    end
    local now = getTimestampMs()
    for pn = 0, 3 do
        local due = S.syncAt[pn]
        if due and now >= due then
            local p = getSpecificPlayer(pn)
            if not p then
                S.syncAt[pn] = nil
            elseif p:getOnlineID() >= 0 then -- 登入初期還沒有 onlineID（同 _Itinerary.lua syncDirty）
                S.syncAt[pn] = nil
                sendClientCommand(p, S.MODULE, "roadSync", {})
                -- 刪掉時沒撤回成功的分享：每次同步重送，收到 roadDropped 才從清單清掉
                local drops = Core.roadsPendingDrops and Core.roadsPendingDrops(pn) or {}
                local i = 1
                while drops[i] ~= nil do
                    sendClientCommand(p, S.MODULE, "roadDrop", { sid = drops[i] })
                    i = i + 1
                end
            end
        end
    end
end

Events.OnCreatePlayer.Add(function(pn) S.requestSync(pn) end)
Events.SyncFaction.Add(function() S.requestSync() end)
Events.OnSafehousesChanged.Add(function() S.requestSync() end)
Events.OnTick.Add(S.tick)
Events.OnGameStart.Add(function()
    S.snaps, S.syncAt, S.lastPolicy = {}, {}, nil
end)

-- 分享表單 ------------------------------------------------------------------------------
-- 「只有自己」與兩個群組勾選是互斥的單選語意：勾群組＝取消「只有自己」；群組全取消＝回到「只有自己」
function S.formChanged(win, checked, box)
    local only, fac, sh = win._only, win._fac, win._sh
    if box == only then
        if checked then
            fac:setChecked(false, true)
            sh:setChecked(false, true)
        elseif not (fac.checked or sh.checked) then
            only:setChecked(true, true)
        end
    elseif checked then
        only:setChecked(false, true)
    elseif not (fac.checked or sh.checked) then
        only:setChecked(true, true)
    end
end

function S.formApply(win)
    local pn, road = win._playerNum, win._road
    local flags = { faction = win._fac.checked == true, safehouse = win._sh.checked == true }
    win:close()
    local shared = flags.faction or flags.safehouse
    if flags.faction == road.share.faction and flags.safehouse == road.share.safehouse
        and (road.sid ~= nil) == shared then return end
    local ok, why = Core.roadsSetShareFlags(pn, road.id, flags)
    if not ok then S.say(pn, Core.roadsErrorText and Core.roadsErrorText(why) or tostring(why), false) end
end

function S.formPrerender(self)
    self._UI.Window.prerender(self)
    local texts = self._texts
    for i = 1, texts.n do
        local t = texts[i]
        self:drawText(t.text, t.x, t.y, t.c.r, t.c.g, t.c.b, t.c.a or 1, self.font)
    end
end

-- 手把交給表單擁有者（框架 Window 預設只接 player 0），隱藏時還原原焦點（同 _RemoteList.lua）
function S.formSetVisible(self, visible)
    local was = self.javaObject ~= nil and self:getIsVisible()
    ISPanel.setVisible(self, visible)
    if was == (visible == true) then return end
    local Focus = self._UI.Focus
    if not Focus then return end
    if visible then
        Focus.onFocus(self)
        local pn = self._playerNum
        if JoypadState and JoypadState.players[pn + 1] then Focus.takeJoypad(self, pn) end
    else
        Focus.releaseJoypad(self)
        Focus.clear(self)
    end
end

function S.formClosed(self)
    self:removeFromUIManager()
    if S.form == self then S.form = nil end
end

-- 分享表單（道路分頁「動作…」、地圖右鍵的道路子選單呼叫）。單機不提供
Core.roadsOpenShare = function(pn, id)
    if not isClient() then return false end
    -- 沙盒關閉、功能閘門擋住：不開表單、說原因；只是沒有陣營／安全屋照開（標籤寫原因，仍可改回只有自己）
    local ok, why = Core.roadShareAvailable(pn)
    if not ok and why ~= "UI_MinidoracatMiniMap_RoadShareNoGroup" then
        S.say(pn, getText(why), false)
        return false
    end
    local p = getSpecificPlayer(pn)
    local road = p and Core.roadsGet and Core.roadsGet(pn, id)
    if not road then return false end
    local UI = MinidoracatUI and MinidoracatUI.v1
    if not (UI and UI.API_MAJOR == 1 and type(UI.API_REVISION) == "number" and UI.API_REVISION >= 17
        and UI.Window and UI.Checkbox and UI.Button) then
        S.say(pn, getText("UI_MinidoracatMiniMap_NeedFramework"), false)
        return false
    end
    if S.form then S.form:close() end
    local g = S.groups(p:getUsername())
    local font, PAD = UIFont.Small, S.PAD
    local tm = getTextManager()
    local fontH = tm:getFontHeight(font)
    local rowH = math.max(24, fontH + 8)
    local facLabel = g.factionName
        and getText("UI_MinidoracatMiniMap_RoadShareFaction", g.factionName, tostring(g.factionCount))
        or getText("UI_MinidoracatMiniMap_RoadShareNoFaction")
    local shLabel = g.safehouseCount
        and getText("UI_MinidoracatMiniMap_RoadShareSafehouse", tostring(g.safehouseCount))
        or getText("UI_MinidoracatMiniMap_RoadShareNoSafehouse")
    local toText, note = getText("UI_MinidoracatMiniMap_RoadShareTo"), getText("UI_MinidoracatMiniMap_RoadShareNote")
    local width = 300
    local labels = { facLabel, shLabel, toText, note, getText("UI_MinidoracatMiniMap_RoadShareOnlyMe") }
    for i = 1, 5 do width = math.max(width, tm:MeasureStringX(font, labels[i]) + PAD * 2 + 64) end
    local win = UI.Window.new{ width = width, height = 200, font = font, opaque = true, icon = "users",
        title = getText("UI_MinidoracatMiniMap_RoadShareTitle", road.name), onClose = S.formClosed }
    win._UI, win._playerNum, win._road = UI, pn, road
    win.prerender, win.setVisible = S.formPrerender, S.formSetVisible
    local colors = win.theme.colors
    local y = win:titleBarHeight() + PAD
    local shared = road.share.faction or road.share.safehouse
    win._only = UI.Checkbox.new{ x = PAD, y = y, label = labels[5], checked = not shared, target = win,
        onChange = S.formChanged, font = font }
    y = y + rowH
    win._texts = { n = 2, { text = toText, x = PAD, y = y + 2, c = colors.text } }
    y = y + rowH
    win._fac = UI.Checkbox.new{ x = PAD + 20, y = y, label = facLabel, target = win, font = font,
        checked = road.share.faction and g.factionName ~= nil, onChange = S.formChanged }
    win._fac:setEnabled(g.factionName ~= nil)
    y = y + rowH
    win._sh = UI.Checkbox.new{ x = PAD + 20, y = y, label = shLabel, target = win, font = font,
        checked = road.share.safehouse and g.safehouseCount ~= nil, onChange = S.formChanged }
    win._sh:setEnabled(g.safehouseCount ~= nil)
    y = y + rowH
    win._texts[2] = { text = note, x = PAD, y = y + 2, c = colors.textMuted or colors.text }
    y = y + rowH + PAD
    local apply = UI.Button.new{ y = y, title = getText("UI_MinidoracatMiniMap_RoadShareApply"), style = "primary",
        target = win, onClick = S.formApply, font = font }
    local cancel = UI.Button.new{ y = y, title = getText("UI_Cancel"), target = win,
        onClick = function(w) w:close() end, font = font }
    win:setHeight(y + apply.height + PAD)
    if not (win._fac.checked or win._sh.checked) then win._only:setChecked(true, true) end
    win:setVisible(false)
    win:addToUIManager()
    local kids = { win._only, win._fac, win._sh, cancel, apply }
    for i = 1, 5 do win:addChild(kids[i]) end
    apply:setX(width - PAD - apply.width) -- 先 addChild 再移位（同 _RemoteList.lua）
    cancel:setX(apply.x - 8 - cancel.width)
    local sx, sy = getPlayerScreenLeft(pn), getPlayerScreenTop(pn)
    win:setX(sx + math.floor((getPlayerScreenWidth(pn) - win.width) / 2))
    win:setY(sy + math.floor((getPlayerScreenHeight(pn) - win.height) / 2))
    S.form = win
    win:setVisible(true)
    win:bringToTop()
    return true
end
