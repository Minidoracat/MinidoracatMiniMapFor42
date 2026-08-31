-- MinidoracatMiniMapPlayerExport.lua — 玩家座標 JSON 週期匯出（外部工具契約）
-- 沙盒開啟時，伺服器（含單機）每 N 秒把「在線玩家即時座標」＋「離線玩家最後
-- 觀測座標」寫成 Zomboid/Lua/MinidoracatMiniMap/players_<存檔名>.json，給外部程式
-- （如 pz-rewild 地圖區塊重置工具）在清除區域前判斷該處有無玩家、必要時先踢下線。
-- 與 poi_blocks.json（MinidoracatMiniMapPOIExport.lua）、Zones addon 的
-- zones.json 同一目錄，工具端一個根目錄讀三份。
--
-- ⚠⚠ 兩份清單的證明力完全不同——這是本檔最重要的契約，弄錯會刪到有人的區域：
--   · online 筆（`"online":true`）＝**完整**：來源 getOnlinePlayers() 是引擎的權威
--     在線清單，掃遍所有連線的所有分割畫面 slot（GameServer.java:3522-3541）。
--     可以用它證明「此刻沒有在線玩家在這塊地上」。這個保證由「無損轉義 ＋
--     不可表示就整輪拒寫」維持（見 escapeJson／collectOnline）：任何一個在線玩家
--     無法被無損寫出時，本輪**完全不寫檔**（讓舊檔因 ts 過期被工具擋下），絕不
--     靜默略過那個人——少一個人就等於這條保證失效。
--   · offline 筆（`"online":false`）＝**本 MOD 觀測到的子集，永遠不完整**
--     （`offlineAuthority` 欄位固定為 `"observed-subset"`，schema 層面明示）。
--     缺席的來源至少四種：(1) 本 MOD 開始記錄之前就登出的角色（見 offlineSince）；
--     (2) 沙盒 ExportOfflinePlayers 關閉時全部缺席（見 offlineIncluded）；
--     (3) registry 超過上限被裁掉的（見 offlineTruncated）；(4) 玩家在最後一次
--     觀測之後才移動並登出（誤差最多一個 interval）。
--     **絕對不可以用 offline 清單證明「這塊地上沒有離線角色」**——它只能當正向
--     證據（清單裡有人 ⇒ 那裡真的有人）。
--   · 要在停機後「證明某區域沒有任何角色」，唯一權威來源是存檔的 players.db
--     `networkPlayers` 表（斷線時由 GameServer.disconnect 寫入當下 x/y/z，
--     GameServer.java:2988-2996；欄位 PlayerDBHelper.java:39-41）。那是 SQLite、
--     Lua 讀不到（見下），只有停機中的外部工具能讀。本檔的定位是「伺服器運行中
--     的即時資訊」（判斷現在誰在哪、要踢誰），不是停機後的完整清冊。
--
-- 為什麼要由 MOD 匯出（引擎沒有替代路徑，皆已反編譯核對 42.20.2）：
--   · Lua 讀不到 players.db——ServerPlayerDB/PlayerDB/PlayerDBHelper 皆未
--     setExposed（LuaManager.java:1687-2712 曝露表無 savefile 類），且
--     ServerPlayerDB 只有依 username/steamid＋playerIndex 的單筆 load/update，無
--     列舉 API（ServerPlayerDB.java:216-227）；唯一 Lua 入口 getSaveInfo
--     （LuaManager.java:8068-8071 → PlayerDBHelper.java:134-165）只查 localPlayers
--     的 id/name/isDead，無座標。
--   · RCON 的 players 指令只給名字、沒有座標；players.db 的在線座標每連線約
--     180 秒才寫一次，不能當即時判斷依據。
--   · 沒有「玩家斷線」Lua 事件——全 snapshot 無 OnPlayerDisconnect；OnDisconnect
--     僅客戶端且無玩家參數（LuaEventManager.java:653、GameClient.java:354-355），
--     GameServer.disconnect 只寫 DB 不 triggerEvent（GameServer.java:2976-3034）。
--     故「離線」只能由在線名單差集推導（見下方 registry）。
--
-- 輸出檔名帶存檔名：Zomboid/Lua/MinidoracatMiniMap/players_<存檔名>.json
--   （存檔名取不到時退回 players.json）。Zomboid/Lua 是全域目錄、不隨存檔，而
--   本檔內容是存檔狀態——同機輪流跑兩個 world 時共用單一檔名會互相覆寫，
--   下次啟動只剩「save 不符→丟棄整份離線歷史」。檔名綁存檔名同時讓工具端指錯
--   檔＝檔案不存在（fail-closed），而不是讀進內容後才靠 save 欄位擋。
--   存檔名本身必然是合法路徑元素（引擎已拿它當目錄／ini 檔名：
--   Saves/Multiplayer/<serverName>、Server/<serverName>_SandboxVars.lua），
--   仍再過一次白名單消毒（僅 %w - _，點也轉 _——見 buildExportPath）防路徑注入。
--
-- 檔案格式 v1（第一行 metadata＋每筆一行；條目間逗號在行首、末行閉合）：
--   {"v":1,"modversion":"<mod.info modversion>","save":"<存檔名>","ts":<epoch ms>,
--   "interval":<秒>,"offlineAuthority":"observed-subset","offlineIncluded":true,
--   "offlineSince":<epoch ms>,"offlineTruncated":false,
--   "online":<在線筆數>,"count":<總筆數>,"players":[
--   {"name":"<username>","idx":0,"online":true,"x":10700,"y":9800,"z":0,"seen":<epoch ms>}
--   ,{"name":"...","idx":0,"online":false,...}
--   ]}
--   · x/y＝世界 square 整數（math.floor，原版慣例 forageServer.lua:259）；
--     B42 chunk 換算 cx = floor(x/8)（chunk＝8×8 tiles，存檔 map/<cx>/<cy>.bin）
--   · z＝樓層（可為負，地下室）
--   · name＝username，**無損** JSON 轉義（`\` `"` 照 JSON 規則，控制字元寫成
--     \u00xx）。踢人用它。引擎允許的 username 字元集比直覺寬：primary 只擋
--     `" \ / . ' ? ; @ $ ,` 與 NUL、長度 2-20（ServerWorldDatabase.java:763-785），
--     **控制字元是允許的**；coop 分屏的 secondary username 更寬，只擋空字串與
--     全服重名（ConnectCoopPacket.java:73-80）——所以轉義必須無損，不能消毒。
--   · idx＝分割畫面 slot（playerIndex 0-3，IsoPlayer.java:966-974；伺服器端由
--     GameServer.java:2785 指派）。`(name, idx)` 是**本 schema 的去重鍵**：同一
--     username 同機分屏可有多個角色在不同位置，工具端要按這組合去重，勿只按
--     name（會丟座標）。**注意它不等於 players.db 的持久身分**——username 是各
--     slot 自報的 alias（GameServer.java:2803），而 DB 用主連線 username（非 Steam
--     coop）或 SteamID（Steam coop）＋world＋playerIndex（ServerPlayerDB.java:129）。
--     玩家改名會產生新的 registry 鍵；別人日後用同一個 alias＋idx 上線，會覆寫
--     前一個角色的離線觀測值。這對 offline 筆是「可能張冠李戴」的已知限制（由
--     offline 只作正向證據的契約承接），對 online 筆無影響（每輪重新觀測）。
--   · online＝本次匯出當下是否在線；false＝本 MOD 最後一次觀測到他的位置
--   · seen＝該座標的觀測時刻（真實 epoch ms）。在線筆等於 ts
--   · save＝存檔名（dedicated 上＝serverName，IsoWorld.java:1792-1793 →
--     getWorld():getWorld()＝Core.gameSaveWorld，IsoWorld.java:3192-3194；原版
--     用例 MainScreen.lua:1061）
--   · ts/interval＝寫檔時刻與當時生效的匯出週期，新鮮度判斷用（見下）
--   · offlineAuthority＝固定 `"observed-subset"`：schema 層面宣告 offline 清單
--     沒有反證力（新增值代表語意變更，工具端遇到未知值應中止）
--   · offlineIncluded＝沙盒是否要求輸出離線筆（false＝一筆離線都沒有，不是
--     「沒有離線角色」）
--   · offlineSince＝這份離線歷史的起點（epoch ms）。**早於此時刻登出的角色不在
--     清單中**。只有在讀回成功且該檔 offlineIncluded 為 true 時才延續原值；
--     檔案不存在／讀回被拒／IO 失敗／該檔本身不含離線筆時＝該次啟動時刻
--   · offlineTruncated＝registry 是否曾因上限（REG_MAX）裁掉最舊的條目
--   · 排序：先 name 升序、同 name 再 idx 升序；同輸入輸出逐 byte 相同
--
-- ⚠ 外部工具端義務（座標會被拿去決定「能不能刪這塊地」，讀錯＝刪到有人的區域）：
--   1. 整檔嚴格 JSON 解析；失敗＝視同不存在並中止破壞性操作（撕裂檔防護——外層
--      物件到 EOF 才閉合，任何截斷前綴都過不了嚴格解析；勿逐行流式取用）。
--   2. players 筆數必須等於 count、其中 online==true 的筆數等於 online，不等＝中止。
--      去重一律用 (name, idx)；**出現重複的 (name, idx) 就中止整份文件**，不可
--      靜默去重（本 MOD 寫出前已拒絕重複鍵，出現重複代表檔案不可信）。
--   3. **新鮮度 fail-closed**：`now - ts` 超過 interval 的數倍（建議 3×，至少留一次
--      漏拍餘裕）＝資料已停止更新（沙盒被關、MOD 被移除、伺服器已停、或本 MOD
--      因為無法完整寫出在線清單而拒寫），此時 online 欄位只代表「伺服器最後一刻
--      誰在線」，不可再當成即時狀態。
--      **上界也要驗**：`ts` 大於 `now` 加上小幅時鐘偏差（建議 60 秒）＝來源時鐘
--      異常，同樣中止——否則未來時間戳會讓陳舊檔案永遠看起來新鮮。
--      `interval` 不在 1–300 之內＝檔案不可信（沙盒值域見 sandbox-options.txt）。
--   4. save 必須等於你要操作的存檔目錄名，不等＝這份檔屬於另一個存檔，中止。
--      `offlineAuthority` 不是 `"observed-subset"`＝未知語意版本，中止。
--   5. **offline 清單不可反證**（見檔首「兩份清單的證明力」）：不論
--      offlineIncluded／offlineSince／offlineTruncated 為何，都不能從「offline 裡
--      沒有人在這塊地」推論「這塊地沒有離線角色」。要那個結論請在停機後讀
--      players.db。offlineSince 晚於伺服器本次啟用該功能的時間、或
--      offlineTruncated 為 true 時，離線歷史更不完整，破壞性操作應更保守。
--   6. 容忍檔案不存在（功能預設關閉；剛開啟還沒到第一次週期）。
--
-- 已知限制（設計取捨，不是 bug）：
--   · 離線座標是本 MOD 週期觀測的快照，不是 players.db 的權威值：玩家在本 MOD
--     未觀測期間被移動（管理員傳送、離線後的存檔操作）不會反映。最壞誤差＝
--     interval 秒（在線）／最後一次觀測（離線）。
--   · 死亡玩家不列入，且從 registry 移除——屍體座標對「保護玩家」無意義。
--   · registry 上限 REG_MAX 筆，超過時丟棄 seen 最舊者並把 offlineTruncated 設為
--     true（防長年運行無限膨脹）。
--   · 沙盒關閉／MOD 移除後檔案原地凍結（不寫空文件）：空 players 清單會讓工具
--     誤判「到處都沒人」而放行刪除，比陳舊檔案更危險——新鮮度由第 3 條擋。
--
-- 週期不做每輪寫後讀回驗證（每輪整份讀回會讓 I/O 加倍，且下一輪就整檔覆寫）；
-- 改為每 VERIFY_EVERY_MS 抽驗一次——**整份讀回並重新嚴格解析**，比對 ts／count／
-- online 與末行閉合。只驗第一行不夠：header 寫成功、後面玩家列或 `]}` 因磁碟滿被
-- 截斷的 partial write 會被誤判成功。LuaFileWriter 走 PrintWriter
-- （LuaManager.java:12751-12770），磁碟滿／唯讀時**完全靜默**（PrintWriter 內吞
-- trouble flag，pcall 接不到），沒有這道抽驗，管理員會完全看不到匯出早已停擺
-- （工具端靠 ts 仍是安全的，只是沒人知道原因）。
--
-- 執行位置：dedicated／遊戲內 Host 的 server 行程掛 OnServerStarted
-- （GameServer.java:1514，此時 _SandboxVars.lua 已 toLua，GameServer.java:1460-1473）；
-- 單機掛 OnGameStart（IngameState.java:761）。isClient() 為真（MP 客戶端、Host 的
-- client 行程）一律不跑——本檔在 MP 客戶端也會被載入（server 目錄由
-- GameLoadingState.java:149 無條件載入，非 dedicated 專屬），閘門必要。
--
-- 節流事件用 OnTickEvenPaused（LuaEventManager.java:594）而非 OnTick：dedicated
-- 在 pauseEmpty＋空服時 paused 為真（IngameState.java:1485-1486），OnTick 被
-- pause 閘門擋掉（:1489 判斷、:1532 呼叫 onTick、:1623 才 triggerEvent），而
-- OnTickEvenPaused 在 :1316、pause 判斷之前，空服也照跑——空服仍需推進 ts，
-- 否則工具無法區分「沒人」與「匯出停擺」。dedicated 觸發鏈：GameServer.java:824
-- IngameState statex → :1001 statex.update() → updateInternal():1316，主迴圈
-- LockFPS(10)（GameServer.java:823）約 10 Hz。真實時間一律 getTimestampMs()
-- （LuaManager.java:9267-9274，原版節流範本 forageServer.lua:456-460）。

-- 實際輸出路徑在 startExport() 依存檔名決定（見檔頭）
local exportPath = "MinidoracatMiniMap/players.json"
local VERIFY_EVERY_MS = 300000 -- 寫入落檔抽驗間隔（5 分鐘，整份讀回重新解析）

-- test:player-export:start
-- 純字串／表邏輯，無 PZ API——離線測試 scripts/test_player_export.lua 抽本區段。
-- 迭代一律用顯式 count；數字經 .. 串接走 Kahlua numberToString
-- （KahluaUtil.java:180，整數值 <1e14 印整數不帶 .0；epoch ms ≈1.7e12 安全）。
local REG_MAX = 2000   -- registry 條目上限
local REG_KEEP = 1800  -- 超限時保留筆數（留餘裕，避免每輪都排序裁切）
local NAME_MAX = 64    -- 單一字串欄位上限（轉義前的字元數；引擎 primary 上限是 20）

-- 控制字元 → JSON \u00xx 對照表（無損轉義用）。建表靠 string.char（Kahlua
-- StringLib.java:1487 註冊；原版 media/lua 無用例，故整段包 pcall）——若該 API
-- 在執行環境不可用，表會是空的，escapeJson 就把「含控制字元的名字」判為不可
-- 表示，讓整輪匯出 fail-closed，而不是靜默丟掉那個玩家。
local CTRL_ESCAPE = {}
local CTRL_ESCAPE_N = 0
pcall(function()
    local hexd = "0123456789abcdef"
    for b = 0, 31 do
        local hi = math.floor(b / 16)
        local lo = b - hi * 16
        CTRL_ESCAPE[string.char(b)] = "\\u00"
            .. hexd:sub(hi + 1, hi + 1) .. hexd:sub(lo + 1, lo + 1)
    end
    CTRL_ESCAPE[string.char(127)] = "\\u007f"
    CTRL_ESCAPE_N = 33
end)

-- 無損 JSON 字串字面值轉義。回傳 (escaped, ok)。
-- ok=false＝這個字串無法無損表示（非字串／空／超過 NAME_MAX／含無法轉義的控制
-- 字元）。呼叫端對「在線玩家」必須據此讓整輪匯出 fail-closed，**不可略過該玩家**
-- ——少一個在線玩家就推翻「online 清單完整、可反證此處無人」的核心契約。
-- 刻意不做任何消毒或截斷：引擎允許的 username 字元集比直覺寬（見檔頭），
-- 消毒會讓兩個不同玩家的名字撞成同一個鍵，截斷同理。
-- registry 的鍵一律含「轉義後」的 name：寫檔直接輸出、讀回原樣取用，全程不需反
-- 轉義（Kahlua 下反轉義的先後順序容易寫錯，索性不需要）。
-- 註：Kahlua 的 string.sub 走 Java String.substring（UTF-16 code unit），BMP 中文
-- 逐字取用不會切壞；補充平面字元（emoji）的 surrogate 對會被逐半處理，但兩半都
-- 不是控制字元也不是 \ 或 "，原樣輸出後仍是同一組 code unit，無損。
local function escapeJson(s)
    if type(s) ~= "string" or s == "" then return "", false end
    if s:len() > NAME_MAX then return "", false end
    local out, on = {}, 0
    for i = 1, s:len() do
        local c = s:sub(i, i)
        local piece
        if c == "\\" then
            piece = "\\\\"
        elseif c == '"' then
            piece = '\\"'
        elseif c:match("%c") then
            piece = CTRL_ESCAPE[c]
            if not piece then return "", false end
        else
            piece = c
        end
        on = on + 1
        out[on] = piece
    end
    return table.concat(out, "", 1, on), true
end

-- 驗證字串是「合法的 JSON 字串字面值內容」：不得有裸引號或控制字元，反斜線只能
-- 跟著 " \ 或 u（\uXXXX）。讀回自家檔案時用它擋下被外部改壞的 name——裸引號能
-- 通過欄位錨點 pattern，卻會讓下一輪寫出非法 JSON，使匯出永久不可用（工具端會
-- 安全拒絕，但沒人知道為什麼）。逐字元掃描，長度有界，成本可忽略。
local function isEscapedJsonBody(s)
    if type(s) ~= "string" then return false end
    local i, len = 1, s:len()
    while i <= len do
        local c = s:sub(i, i)
        if c == '"' then return false end
        if c == "\\" then
            local nxt = s:sub(i + 1, i + 1)
            if nxt == '"' or nxt == "\\" then
                i = i + 2
            elseif nxt == "u" then
                -- \uXXXX：四位十六進位
                local hex = s:sub(i + 2, i + 5)
                if hex:len() ~= 4 or hex:match("^%x%x%x%x$") == nil then
                    return false
                end
                i = i + 6
            else
                return false
            end
        elseif c:match("%c") then
            return false
        else
            i = i + 1
        end
    end
    return true
end

-- 數字欄位讀回守衛：限制位數（擋掉 400 位數經 tonumber 變 inf、再被寫成
-- `"x":inf` 這種非法 JSON）並夾在合理值域內。任一不符回 nil＝整份拒絕。
local function numIn(s, lo, hi, maxDigits)
    if type(s) ~= "string" then return nil end
    local body = s
    if body:sub(1, 1) == "-" then body = body:sub(2) end
    local bl = body:len()
    if bl < 1 or bl > maxDigits then return nil end
    if body:match("^%d+$") == nil then return nil end
    local v = tonumber(s)
    if v == nil then return nil end
    if v < lo or v > hi then return nil end
    return v
end

-- 版本號白名單消毒（僅留字母數字 . -），沿用 POIExport 的做法：值進 JSON 字串
-- 字面值，杜絕引號／反斜線破壞結構。modversion 來自 mod.info、非玩家可控，
-- 消毒（有損）在這裡是安全的。
local function sanitizeVersion(v)
    if type(v) ~= "string" or v == "" then return "unknown" end
    local mv = v:gsub("[^%w%.%-]", "")
    if mv == "" then return "unknown" end
    return mv
end

-- 檔名 token 白名單消毒：僅留字母數字 - _，其餘（含空白、分隔符、點）轉 _。
-- 點一併排除是必要的：存檔名含 ".." 會讓組出的路徑被 getFileWriter 的
-- hasRelativePath 判定為相對路徑攻擊而回 nil（LuaManager.java:6730、
-- :8519-8522），匯出會整個失效——檔名裡的點只是裝飾，原名仍保留在 save 欄位。
-- 消毒後只剩底線＝退回無存檔名的檔名（save 欄位比對仍是第二道防線）。
local function buildExportPath(save)
    if type(save) ~= "string" or save == "" then
        return "MinidoracatMiniMap/players.json"
    end
    local token = save:gsub("[^%w%-_]", "_")
    if token:len() > 48 then token = token:sub(1, 48) end
    if token:gsub("_", "") == "" then
        return "MinidoracatMiniMap/players.json"
    end
    return "MinidoracatMiniMap/players_" .. token .. ".json"
end

local function intOf(v)
    if type(v) ~= "number" then return 0 end
    return math.floor(v)
end

-- registry 的去重鍵：(轉義後 name, playerIndex)。只用 name 會讓同機分屏的同名
-- 多角色塌成一筆、直接丟掉其中一個座標（對破壞性消費端是漏報，最危險的方向）。
local function regKey(name, idx)
    return tostring(name) .. "#" .. intOf(idx)
end

-- Steam64 格式檢查：17 位十進位、且不小於 individual account 區段起點。
-- 固定長度所以字串字典序＝數值序，不必轉數字（轉了就失精，見 rememberSteamId）。
local STEAM64_MIN = "76561197960265728"
local function isSteam64(s)
    if type(s) ~= "string" then return false end
    if s:match("^%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d%d$") == nil then return false end
    return s >= STEAM64_MIN
end

-- entries：{ {name=<已轉義>, idx=, steamId=<""或17位字串>, online=<bool>,
--            x=, y=, z=, seen=}, ... }（1..n，已排序）
-- meta：{ modversion=, save=<已轉義>, ts=, interval=, offlineIncluded=<bool>,
--         offlineSince=, offlineTruncated=<bool> }
-- name／save 必須是 escapeJson 過的字串（registry 的鍵、cachedSave 都已是）——
-- builder 刻意不再 escape：對已轉義字串二次轉義會把 \" 變成 \\"，解析回來就
-- 多一個反斜線。數字欄位仍過 intOf，杜絕 float 印成 1.0 汙染整數語意。
-- table.concat 一律傳 first/last：Kahlua 未給第 4 參數時會走 table.len()
-- （TableLib.java:129-138），那是家規要避開的隱性長度依賴。
local function buildPlayersJson(entries, n, onlineCount, meta)
    meta = meta or {}
    local lines = { '{"v":1,"modversion":"' .. sanitizeVersion(meta.modversion)
        .. '","save":"' .. tostring(meta.save or "")
        .. '","ts":' .. intOf(meta.ts)
        .. ',"interval":' .. intOf(meta.interval)
        .. ',"offlineAuthority":"observed-subset"'
        .. ',"offlineIncluded":' .. ((meta.offlineIncluded ~= false) and 'true' or 'false')
        .. ',"offlineSince":' .. intOf(meta.offlineSince)
        .. ',"offlineTruncated":' .. (meta.offlineTruncated and 'true' or 'false')
        .. ',"online":' .. intOf(onlineCount)
        .. ',"count":' .. intOf(n) .. ',"players":[' }
    local ln = 1
    for i = 1, n do
        local e = entries[i]
        ln = ln + 1
        lines[ln] = ((i > 1) and ',' or '')
            .. '{"name":"' .. tostring(e.name)
            .. '","idx":' .. intOf(e.idx)
            .. ',"steamId":"' .. (isSteam64(e.steamId) and e.steamId or "")
            .. '","online":' .. (e.online and 'true' or 'false')
            .. ',"x":' .. intOf(e.x) .. ',"y":' .. intOf(e.y) .. ',"z":' .. intOf(e.z)
            .. ',"seen":' .. intOf(e.seen) .. '}'
    end
    ln = ln + 1
    lines[ln] = ']}'
    return table.concat(lines, "\n", 1, ln)
end

-- 讀回（繼承離線 registry）用的逐行解析。欄位順序由 builder 固定，因此用固定
-- 錨點 pattern 即可，不需 JSON parser：字串欄位以其後的固定欄位名收尾（貪婪
-- .* 讓轉義後的 \" 也能正確落在字串內），抽出後再用 isEscapedJsonBody 驗文法、
-- numIn 驗數字位數與值域。
local TS_MAX = 4000000000000    -- epoch ms 上界（約西元 2096）
local COORD_MAX = 10000000      -- 世界 square 座標絕對值上界
local function parseHeaderLine(line)
    if type(line) ~= "string" then return nil end
    local v, mv, save, ts, interval, auth, oIncl, oSince, oTrunc, online, count =
        line:match('^{"v":(%d+),"modversion":"([^"]*)","save":"(.*)","ts":(%d+),'
        .. '"interval":(%d+),"offlineAuthority":"([%a%-]*)","offlineIncluded":(%a+),'
        .. '"offlineSince":(%d+),"offlineTruncated":(%a+),'
        .. '"online":(%d+),"count":(%d+),"players":%[$')
    if not v then return nil end
    if auth ~= "observed-subset" then return nil end
    if oIncl ~= "true" and oIncl ~= "false" then return nil end
    if oTrunc ~= "true" and oTrunc ~= "false" then return nil end
    if not isEscapedJsonBody(save) then return nil end
    local nv = numIn(v, 1, 9, 1)
    local nts = numIn(ts, 0, TS_MAX, 13)
    local nint = numIn(interval, 1, 300, 3)
    local nsince = numIn(oSince, 0, TS_MAX, 13)
    local non = numIn(online, 0, 100000, 6)
    local ncount = numIn(count, 0, 100000, 6)
    if not (nv and nts and nint and nsince and non and ncount) then return nil end
    return { v = nv, modversion = mv, save = save, ts = nts, interval = nint,
        offlineAuthority = auth, offlineIncluded = (oIncl == "true"),
        offlineSince = nsince, offlineTruncated = (oTrunc == "true"),
        online = non, count = ncount }
end

local function parseEntryLine(line)
    if type(line) ~= "string" then return nil end
    local name, idx, steamId, online, x, y, z, seen = line:match(
        '^,?{"name":"(.*)","idx":(%d+),"steamId":"(%d*)","online":(%a+),"x":(%-?%d+),"y":(%-?%d+),"z":(%-?%d+),"seen":(%d+)}$')
    if not name or name == "" then return nil end
    if online ~= "true" and online ~= "false" then return nil end
    if not isEscapedJsonBody(name) then return nil end
    -- steamId 允許空（非 Steam 伺服器、或該玩家的客戶端沒回報過）；非空就必須是
    -- 合法 Steam64，否則整份拒絕——半個可信的識別欄位比沒有更糟
    if steamId ~= "" and not isSteam64(steamId) then return nil end
    local nidx = numIn(idx, 0, 3, 1)
    local nx = numIn(x, -COORD_MAX, COORD_MAX, 8)
    local ny = numIn(y, -COORD_MAX, COORD_MAX, 8)
    local nz = numIn(z, -32, 31, 2)
    local nseen = numIn(seen, 0, TS_MAX, 13)
    if nidx == nil or nx == nil or ny == nil or nz == nil or nseen == nil then
        return nil
    end
    return { name = name, idx = nidx, steamId = steamId,
        online = (online == "true"), x = nx, y = ny, z = nz, seen = nseen }
end

-- 整份嚴格解析（自家寫出的檔）：header v==1、save 相符、條目數==count、末行閉合、
-- 無重複 (name, idx)，任一不符回 nil＝不繼承（半份 registry 比沒有更會誤導工具）。
-- lines：1..ln 的字串陣列。回傳 reg（regKey→{name,idx,x,y,z,seen}）、筆數、header。
local function parseExportLines(lines, ln, expectSave)
    if type(ln) ~= "number" or ln < 2 then return nil, "too short" end
    local head = parseHeaderLine(lines[1])
    if not head then return nil, "bad header" end
    if head.v ~= 1 then return nil, "unsupported v" end
    if lines[ln] ~= ']}' then return nil, "unterminated" end
    if expectSave ~= nil and head.save ~= expectSave then return nil, "save mismatch" end
    local reg, n = {}, 0
    for i = 2, ln - 1 do
        local e = parseEntryLine(lines[i])
        if not e then return nil, "bad entry line " .. i end
        local key = regKey(e.name, e.idx)
        if reg[key] then return nil, "duplicate key at line " .. i end
        n = n + 1
        -- 讀回時一律視為離線：此刻沒有任何連線（啟動）或連線需重新觀測
        reg[key] = { name = e.name, idx = e.idx, steamId = e.steamId,
            x = e.x, y = e.y, z = e.z, seen = e.seen }
    end
    if head.count ~= (ln - 2) then return nil, "count mismatch" end
    return reg, n, head
end

-- 迭代（bottom-up）merge sort：家規禁用 table.sort——Kahlua 的 sort 是遞迴
-- quicksort（coroutine 堆疊上限 3000），**已排序輸入退化成 O(n) 深度、數百筆就
-- 溢位**，見 scripts/verify_mod.py 檔頭。本功能的輸入正好幾乎總是已排序
-- （registry 讀回自按 name 排序的檔案），且上限 REG_MAX＝2000 筆，用 table.sort
-- 必炸；其他家族用例的集合是個位數才用插入排序（MinidoracatMiniMap.lua:384）。
-- less(a, b)＝a 必須排在 b 之前；等價元素保留原序（穩定）。
local function sortSafe(arr, n, less)
    if n < 2 then return end
    local buf = {}
    local width = 1
    while width < n do
        local lo = 1
        while lo <= n do
            local mid = lo + width - 1
            local hi = lo + 2 * width - 1
            if mid > n then mid = n end
            if hi > n then hi = n end
            local a, b, k = lo, mid + 1, lo
            while a <= mid and b <= hi do
                -- 只有 b 嚴格在前才取 b ⇒ 等價時取左半，穩定
                if less(arr[b], arr[a]) then
                    buf[k] = arr[b]
                    b = b + 1
                else
                    buf[k] = arr[a]
                    a = a + 1
                end
                k = k + 1
            end
            while a <= mid do
                buf[k] = arr[a]
                a = a + 1
                k = k + 1
            end
            while b <= hi do
                buf[k] = arr[b]
                b = b + 1
                k = k + 1
            end
            lo = lo + 2 * width
        end
        for j = 1, n do arr[j] = buf[j] end
        width = width * 2
    end
end

-- 超過 REG_MAX 時保留 seen 最新的 keep 筆（同 seen 以 key 決勝，輸出穩定）。
-- 回傳新筆數與「是否發生裁切」——裁切過就要在檔案裡標 offlineTruncated，
-- 否則消費端無從得知離線歷史被截過。
local function pruneRegistry(reg, count, keep)
    if count <= REG_MAX then return count, false end
    local arr, an = {}, 0
    for key, e in pairs(reg) do
        an = an + 1
        arr[an] = { key = key, seen = (e and e.seen) or 0 }
    end
    sortSafe(arr, an, function(a, b)
        if a.seen == b.seen then return a.key < b.key end
        return a.seen > b.seen
    end)
    for i = keep + 1, an do
        reg[arr[i].key] = nil
    end
    if an <= keep then return an, false end
    return keep, true
end

-- 合併在線觀測與 registry → 排序好的 entries。
-- online：{ {name=, idx=, steamId=, x=, y=, z=}, ... }（1..onlineN，name 已轉義）
-- 回傳 entries, n, onlineCount
local function mergeEntries(online, onlineN, reg, includeOffline, now)
    local entries, n = {}, 0
    local seen = {}
    for i = 1, onlineN do
        local p = online[i]
        n = n + 1
        entries[n] = { name = p.name, idx = p.idx, steamId = p.steamId,
            online = true, x = p.x, y = p.y, z = p.z, seen = now }
        seen[regKey(p.name, p.idx)] = true
    end
    if includeOffline then
        for key, e in pairs(reg) do
            if not seen[key] then
                n = n + 1
                entries[n] = { name = e.name, idx = e.idx, steamId = e.steamId,
                    online = false, x = e.x, y = e.y, z = e.z, seen = e.seen }
            end
        end
    end
    sortSafe(entries, n, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        if a.idx ~= b.idx then return (a.idx or 0) < (b.idx or 0) end
        if a.online ~= b.online then return a.online end
        return (a.seen or 0) > (b.seen or 0)
    end)
    return entries, n, onlineN
end
-- test:player-export:end

--------------------------------------------------------------------------------
-- PZ API 區
--------------------------------------------------------------------------------

local function log(msg)
    print("[MinidoracatMiniMap] " .. msg)
end

-- 沙盒讀值一律走 shared facade（MinidoracatMiniMap_Policy.lua）：Java
-- SandboxOptions 是真相源，SandboxVars 只是任何 MOD 都能寫的鏡像表——匯出開關
-- 決定玩家座標要不要落地成檔案，不能建在可被任意改寫的表上。
-- 三把匯出鍵（ExportPlayerPositions／PlayerExportInterval／ExportOfflinePlayers）
-- 都**不在**任何管理員旁路白名單上（見 facade 檔頭），且這裡刻意只用 read 系
-- API、不傳 playerNum＝形式上也拿不到旁路。
-- facade 缺席＝安裝不完整，此時退回呼叫端 default（主開關的 default 是 false，
-- 即不寫檔），並記一次 log；不退回直讀鏡像表。
local policyWarned = false
local function sb(method, name, default)
    local P = MinidoracatMiniMapPolicy
    if not P then
        if not policyWarned then
            policyWarned = true
            log("policy facade missing, player export uses built-in defaults")
        end
        return default
    end
    return P[method](name, default)
end
local function sbBool(name, default) return sb("readBool", name, default) end
local function sbNumber(name, default) return sb("readNumber", name, default) end

local registry = {}         -- regKey(name, idx) → {name, idx, steamId, x, y, z, seen}
local reportedSteamIds = {} -- regKey(name, idx) → 已通過一致性檢查的 Steam64 字串
local registryCount = 0
local offlineSince = nil    -- 離線歷史起點；nil＝首次 tick 時設為當下
local wasDisabled = false   -- 上一輪 tick 看到主開關是關的（見 exportTick 的空窗處理）
local offlineTruncated = false
local lastExportMs = nil    -- 上次寫檔時刻；nil＝還沒寫過（下一次 tick 立即寫）
local lastVerifyMs = nil    -- 上次寫入落檔抽驗時刻
local cachedModVersion = nil
local cachedSave = ""
local ioFailLogged = false
local started = false

-- 存檔名：dedicated＝serverName、單機＝存檔資料夾名（見檔頭）。取用失敗降級空
-- 字串——輸出退回無存檔名的檔名，且 save 欄位為空使工具端比對失敗＝fail-closed。
local function readSaveName()
    local ok, name = pcall(function() return getWorld():getWorld() end)
    if ok and type(name) == "string" then return name end
    return ""
end

-- getModVersion：ChooseGameInfo.java:696-698（原版用例 ModInfoPanelParam.lua:23）
local function readModVersion()
    local okInfo, info = pcall(getModInfoByID, "MinidoracatMiniMapFor42")
    if okInfo and info then
        local okV, v = pcall(function() return info:getModVersion() end)
        if okV and type(v) == "string" then return v end
    end
    return nil
end

-- 逐行讀回自家上次寫出的檔案，繼承離線 registry 與其起點／截斷標記。
-- getFileReader 無副檔名白名單，「不存在」與 IOException 都回 null
-- （家族用例 _Migrate.lua:37）——兩者都代表「沒有可繼承的歷史」，差別只在 log。
-- 繼承失敗不影響在線資料的正確性，但離線歷史等於重新開始：offlineSince 會被設成
-- 當下、寫進檔案，消費端據此知道「早於這個時刻登出的角色不在清單裡」。
-- 讀到的檔案本身 offlineIncluded 為 false 時同樣不延續 offlineSince——那份檔案
-- 根本沒有離線筆，延續它的起點會假裝歷史完整。
local function loadRegistry()
    local reader = getFileReader(exportPath, false)
    if not reader then
        log("no previous players file (" .. exportPath
            .. "); offline history starts fresh from now")
        return
    end
    local lines, ln = {}, 0
    local ok = pcall(function()
        local line = reader:readLine()
        while line ~= nil do
            ln = ln + 1
            lines[ln] = line
            line = reader:readLine()
        end
    end)
    pcall(function() reader:close() end)
    if not ok then
        log("players file read-back aborted (IO error); offline history RESTARTS from now -- external tools must treat offline list as incomplete (offlineSince)")
        return
    end
    -- 第二回傳值：成功＝條目數、失敗＝原因字串
    local parsed, detail, head = parseExportLines(lines, ln, cachedSave)
    if not parsed then
        log("players file read-back rejected (" .. tostring(detail)
            .. "); offline history RESTARTS from now -- external tools must treat offline list as incomplete (offlineSince)")
        return
    end
    registry = parsed
    registryCount = detail
    if head and head.offlineIncluded and type(head.offlineSince) == "number"
        and head.offlineSince > 0 then
        offlineSince = head.offlineSince
    end
    if head and head.offlineTruncated then offlineTruncated = true end
    log("players file read-back ok (" .. registryCount .. " known players, save "
        .. cachedSave .. ", offlineSince " .. tostring(offlineSince or "new")
        .. ", truncated " .. tostring(offlineTruncated) .. ")")
end

-- 掃在線玩家：dedicated 用 getOnlinePlayers()（LuaManager.java:4454-4464 →
-- GameServer.getPlayers()，GameServer.java:3522-3541；單機回空 list），單機走
-- getNumActivePlayers()/getSpecificPlayer()——分支慣例同原版 XpUpdate.lua:300-303。
-- idx＝p:getPlayerNum()（IsoPlayer.java:966-974，@UsedFromLua；原版 server 用例
-- ISPickDungCursor.lua:8）；伺服器端的值由 GameServer.java:2785 指派。
-- 回傳 (out, n) 或 (nil, reason)：任何一個在線玩家無法無損寫出、或出現重複的
-- (name, idx) 鍵時一律 abort 整輪——寧可讓檔案過期被工具擋下，也不能交出一份
-- 「少了某個在線玩家」的清單（那會讓工具以為那塊地沒人）。
local function collectOnline(now)
    local out, n = {}, 0
    local keys = {}
    local server = isServer()
    local players = nil
    if server then players = getOnlinePlayers() end
    local last
    if server then
        last = players:size() - 1
    else
        last = getNumActivePlayers() - 1
    end
    for i = 0, last do
        local p
        if server then p = players:get(i) else p = getSpecificPlayer(i) end
        if p then
            local rawName = nil
            local okName, got = pcall(function() return p:getUsername() end)
            if okName then rawName = got end
            local name, nameOk = escapeJson(rawName)
            if not nameOk then
                return nil, "username not representable (slot " .. i .. ")"
            end
            local idx = 0
            local okIdx, num = pcall(function() return p:getPlayerNum() end)
            if okIdx and type(num) == "number" and num >= 0 and num <= 3 then
                idx = math.floor(num)
            end
            local key = regKey(name, idx)
            if p:isDead() then
                -- 屍體座標無保護意義；同時清掉 registry 舊值
                if registry[key] then
                    registry[key] = nil
                    registryCount = registryCount - 1
                end
            else
                if keys[key] then
                    return nil, "duplicate (name, idx) key " .. key
                end
                keys[key] = true
                -- steamId：客戶端回報並經一致性檢查後的值（見 rememberSteamId）。
                -- 先看本輪快取，沒有就沿用 registry 既有值（玩家重連時客戶端會
                -- 再回報一次；沿用讓「離線前的 Steam ID」不會因為重連而消失）。
                local sid = reportedSteamIds[key]
                if not isSteam64(sid) then
                    local prev = registry[key]
                    sid = prev and prev.steamId or ""
                end
                if not isSteam64(sid) then sid = "" end
                n = n + 1
                out[n] = { name = name, idx = idx, steamId = sid,
                    x = math.floor(p:getX()),
                    y = math.floor(p:getY()), z = math.floor(p:getZ()) }
                if not registry[key] then registryCount = registryCount + 1 end
                registry[key] = { name = name, idx = idx, steamId = sid,
                    x = out[n].x, y = out[n].y, z = out[n].z, seen = now }
            end
        end
    end
    return out, n
end

local function logIoFail(msg)
    if not ioFailLogged then
        ioFailLogged = true
        log(msg)
    end
end

local function writeExport(text)
    local writer = getFileWriter(exportPath, true, false)
    if not writer then
        logIoFail("players export FAILED (getFileWriter unavailable) -- the players file is now STALE; external tools must verify ts freshness before use")
        return false
    end
    -- pcall 只防 Java wrapper 例外炸掉 tick 事件、不漏 close；PrintWriter 內吞
    -- IO 錯誤（LuaManager.java:12751-12770），寫失敗這裡接不到——靠下方
    -- verifyWritten 的低頻整份抽驗才看得見（見檔頭取捨）。
    local ok = pcall(function()
        writer:write(text)
        writer:close()
    end)
    if not ok then
        pcall(function() writer:close() end)
        logIoFail("players export write raised; the players file may be TORN/STALE")
        return false
    end
    return true
end

-- 低頻抽驗：整份讀回並重新嚴格解析，比對 ts/count/online。只讀第一行不夠——
-- header 落地、後面條目或 `]}` 被截斷的 partial write 會被誤判成功。
local function verifyWritten(expectTs, expectCount, expectOnline)
    local reader = getFileReader(exportPath, false)
    if not reader then return false end
    local lines, ln = {}, 0
    local ok = pcall(function()
        local line = reader:readLine()
        while line ~= nil do
            ln = ln + 1
            lines[ln] = line
            line = reader:readLine()
        end
    end)
    pcall(function() reader:close() end)
    if not ok then return false end
    local parsed, _, head = parseExportLines(lines, ln, cachedSave)
    if not parsed or not head then return false end
    return head.ts == expectTs and head.count == expectCount
        and head.online == expectOnline
end

local function exportTick()
    if not sbBool("ExportPlayerPositions", false) then
        wasDisabled = true
        return
    end
    local now = getTimestampMs()
    -- 停用期間完全不觀測（上面那行就 return 了），所以那段時間登出的角色不會進
    -- registry——離線歷史有一段空窗。重新啟用時 offlineSince 必須重設成當下，
    -- 否則檔案會宣稱「早於原起點登出的角色都在清單裡」，而空窗期的人其實缺席，
    -- 這正是 offlineSince 這個欄位存在的意義（見檔頭與 _README_*.txt）。
    -- 初值 false：啟動後第一輪若主開關本來就開著，不會誤傷讀回繼承來的起點。
    if wasDisabled then
        wasDisabled = false
        if offlineSince ~= nil then
            log("player position export re-enabled; offline history RESTARTS from now (nothing was observed while it was disabled)")
        end
        offlineSince = now
        -- 也要清掉節流，否則「關掉再開」若發生在一個 interval 之內，下面的節流會
        -- 直接 return，檔案在最長一個 interval（管理員可設到 300 秒）內仍然帶著
        -- 舊的 offlineSince ＋ 還算新鮮的 ts——工具會以為歷史沒斷過。
        lastExportMs = nil
    end
    -- 節流以「上次寫檔時刻＋當前 interval」判斷，不快取絕對到期時刻：沙盒
    -- interval 被管理員改小時要立刻生效（存到期時刻會讓改動等到舊的長間隔過完）。
    local interval = math.floor(sbNumber("PlayerExportInterval", 5))
    if interval < 1 then interval = 1 end
    if interval > 300 then interval = 300 end
    if lastExportMs ~= nil then
        local elapsed = now - lastExportMs
        -- elapsed < 0＝系統時鐘被往回調，視為到期，否則會卡到真實時間追上為止
        if elapsed >= 0 and elapsed < interval * 1000 then return end
    end
    lastExportMs = now
    if offlineSince == nil then offlineSince = now end
    local online, onlineN = collectOnline(now)
    if online == nil then
        logIoFail("players export ABORTED (" .. tostring(onlineN)
            .. ") -- refusing to write an incomplete online list; the players file is now STALE, external tools must verify ts freshness")
        return
    end
    local newCount, truncated = pruneRegistry(registry, registryCount, REG_KEEP)
    registryCount = newCount
    if truncated then offlineTruncated = true end
    local includeOffline = sbBool("ExportOfflinePlayers", true)
    local entries, n, onlineCount = mergeEntries(online, onlineN, registry,
        includeOffline, now)
    local wrote = writeExport(buildPlayersJson(entries, n, onlineCount, {
        modversion = cachedModVersion, save = cachedSave,
        ts = now, interval = interval, offlineIncluded = includeOffline,
        offlineSince = offlineSince, offlineTruncated = offlineTruncated,
    }))
    if not wrote then return end
    local dueVerify = (lastVerifyMs == nil)
    if not dueVerify then
        local since = now - lastVerifyMs
        dueVerify = (since < 0) or (since >= VERIFY_EVERY_MS)
    end
    if dueVerify then
        lastVerifyMs = now
        if verifyWritten(now, n, onlineCount) then
            if ioFailLogged then
                ioFailLogged = false
                log("players export recovered (write verified)")
            end
        else
            logIoFail("players export write-back verify FAILED -- writes are silently not landing or are truncated (disk full / read-only?); the players file is STALE, external tools must verify ts freshness")
        end
    end
end

local function startExport()
    if started then return end
    started = true
    cachedModVersion = readModVersion()
    local rawSave = readSaveName()
    local escSave, saveOk = escapeJson(rawSave)
    if not saveOk then escSave = "" end
    cachedSave = escSave
    exportPath = buildExportPath(rawSave)
    loadRegistry()
    Events.OnTickEvenPaused.Add(exportTick)
    log("player position export armed (" .. exportPath
        .. ", sandbox ExportPlayerPositions="
        .. tostring(sbBool("ExportPlayerPositions", false))
        .. ", ctrl-escape entries " .. CTRL_ESCAPE_N .. ")")
end

-- Steam64 回報（客戶端 → 伺服器）。**這個欄位不是伺服器權威值**，用途只有
-- 「比對／稽核時的人類可讀識別」，絕不可拿來做授權、封鎖或所有權判定：
--   · 伺服器端拿不到精確值：`IsoPlayer.getSteamID()` 回 Java long
--     （IsoPlayer.java:6412-6414），經 Kahlua 的 NumberToLuaConverter 一律轉成
--     Double（KahluaNumberConverter.java:141-142）。Steam64 約 7.66e16，該量級
--     double 的 ULP 是 16，末一兩位會被靜默捨去，`tostring` 還會給科學記號。
--   · 引擎唯一會把 SteamID 字串化的兩個 Lua 入口都擋在客戶端：
--     `getCurrentUserSteamID()` 條件含 `!GameServer.server`（LuaManager.java:9371）、
--     `getSteamIDFromUsername()` 條件含 `GameClient.client`（:9470-9479）；
--     `SteamUtils` 未 setExposed。字串化的值只出現在 ScoreboardUpdatePacket 的
--     steamIdsString，而那個 triggerEvent 也只在客戶端（:82）。
-- 所以只能由客戶端回報。伺服器做兩道檢查：格式（17 位、≥ individual 區段起點）
-- 與一致性——把回報字串 tonumber 後和 `p:getSteamID()` 比對。兩邊都是「同一個
-- long 的 double 投影」，投影是確定性的，所以任意亂填會被擋下；但**同一個 double
-- bucket 裡有 15-16 個相鄰 Steam64（實測 76561198012345678 的 bucket 是
-- ...673~...687 共 15 個），而 Steam64 ＝固定基底＋任意 32-bit accountID，所以那些
-- 相鄰值多半也是實際存在的帳號**——惡意客戶端可以挑其中任一個通過比對。這就是它
-- 只能標成 client-reported, consistency-checked、不可拿來做授權／封鎖／所有權判定
-- 的原因；需要權威值請在停機後讀 players.db 的 networkPlayers.steamid（字串欄位）。
-- 回傳 (accepted, idx)：只有真的存下來（或已經是同一個值）才算 accepted，呼叫端
-- 據此決定要不要回 ack。**失敗一律不 ack**——客戶端會照自己的節流重試，而
-- 「格式錯／double 不符／伺服器沒有 SteamID」重試也不會變好，靠客戶端的次數上限
-- 收尾就夠；反過來若失敗也 ack，客戶端就會誤以為完成而停手。
local function rememberSteamId(player, claimed)
    local okName, raw = pcall(function() return player:getUsername() end)
    if not okName then return false end
    local name, nameOk = escapeJson(raw)
    if not nameOk then return false end
    local idx = 0
    local okIdx, num = pcall(function() return player:getPlayerNum() end)
    if okIdx and type(num) == "number" and num >= 0 and num <= 3 then
        idx = math.floor(num)
    end
    if not isSteam64(claimed) then return false, idx end
    local okSid, actual = pcall(function() return player:getSteamID() end)
    if not okSid or type(actual) ~= "number" or actual == 0 then return false, idx end
    if tonumber(claimed) ~= actual then
        log("steamId report rejected for " .. name .. "#" .. idx
            .. " (does not match the server's value)")
        return false, idx
    end
    local key = regKey(name, idx)
    if reportedSteamIds[key] ~= claimed then
        reportedSteamIds[key] = claimed
        local entry = registry[key]
        if entry then entry.steamId = claimed end
        log("steamId accepted for " .. name .. "#" .. idx)
    end
    return true, idx
end

Events.OnClientCommand.Add(function(module, command, player, args)
    if module ~= "MinidoracatMiniMap" or command ~= "reportSteamId" then return end
    if not player then return end
    if not (args and type(args.steamId) == "string") then return end
    local accepted, idx = rememberSteamId(player, args.steamId)
    -- ack 帶 slot：客戶端逐 slot 記帳（分屏時每個 slot 各自要回報一次，第一個
    -- slot 的 ack 不能把其他 slot 一起停掉）。sendClientCommand 沒有回傳值，
    -- 客戶端只能靠這條回程確認送到了。
    if accepted then
        sendServerCommand(player, "MinidoracatMiniMap", "steamIdAck", { idx = idx })
    end
end)

Events.OnServerStarted.Add(startExport)
Events.OnGameStart.Add(function()
    if not isClient() then startExport() end
end)
