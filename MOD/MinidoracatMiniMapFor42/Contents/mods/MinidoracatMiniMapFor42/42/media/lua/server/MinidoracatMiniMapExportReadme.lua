-- MinidoracatMiniMapExportReadme.lua — 在 Zomboid/Lua/MinidoracatMiniMap/ 放一份
-- 目錄說明，讓看到那些 JSON 的人（伺服器管理員、寫外部工具的人）不必翻 MOD 原始碼
-- 就知道每個欄位是什麼、哪些結論可以下、哪些不行。
--
-- 說明文字放在 MOD 的靜態檔（42/media/exportdoc/_README_<LANG>.txt），啟動時原封
-- 不動複製到 Zomboid/Lua/MinidoracatMiniMap/。**不可以把中日文直接寫在這個 .lua
-- 的字串字面量裡**：Lua 原始檔由 IndieFileLoader.getStreamReader 載入，主路徑是
-- UTF-8（IndieFileLoader.java:22-24），但 fallback 到
-- Core.getMyDocumentFolder()/mods 時用的是 new InputStreamReader(fisx)＝平台預設
-- 編碼（:25-27）；本機 linked-mod 走的就是 fallback，實測整段中文被讀成 U+FFFD
-- 寫出來全是亂碼。改走靜態檔就全程 UTF-8：
--   讀 getModFileReader（LuaManager.java:5971-6018，明確 StandardCharsets.UTF_8
--   於 :6005；先找 versionDir 再找 commonDir，與家族的 42/ 佈局一致）
--   寫 getFileWriter（LuaManager.java:6725-6760，明確 UTF-8 於 :6753-6754）
-- 這也是本 MOD 所有使用者可見文字都走 Translate/*.json、不寫在 Lua 字面量的原因。
--
-- **只在檔案不存在時寫**，之後永遠不碰它：管理員可能在上面加自己的註記，MOD 不該
-- 蓋掉。已存在時只做一次 getFileReader（開了就關），不讀不寫來源檔。刪掉它下次
-- 啟動會補回。文字第一行帶格式版本字串，讀者自己看得出它對應哪一版；未來格式若
-- 改版，換檔名（_README_v2_*.txt）或在 CHANGELOG 提醒刪舊檔，不做自動覆寫。
--
-- 無條件寫（不看沙盒開關）：poi_blocks.json 每次啟動都會產生，所以這個目錄一定
-- 存在、一定有人會好奇它是什麼。
--
-- 執行位置與閘門同 PlayerExport：dedicated／Host 的 server 行程走 OnServerStarted
-- （GameServer.java:1514），單機走 OnGameStart（IngameState.java:761），MP 客戶端
-- （isClient()）不寫——server 目錄在 MP 客戶端也會被載入
-- （GameLoadingState.java:149 無條件補載）。

local MOD_ID = "MinidoracatMiniMapFor42"

-- 來源（相對 MOD 的 versionDir／commonDir）→ 目的（相對 Zomboid/Lua/）
local DOCS = {
    { src = "media/exportdoc/_README_CH.txt",
      dest = "MinidoracatMiniMap/_README_CH.txt" },
    { src = "media/exportdoc/_README_EN.txt",
      dest = "MinidoracatMiniMap/_README_EN.txt" },
    { src = "media/exportdoc/_README_JP.txt",
      dest = "MinidoracatMiniMap/_README_JP.txt" },
}

-- 存在就跳過，不看內容：管理員可能編修過，MOD 不該覆寫（見檔頭）。
-- 用 cacheFileExists（LuaManager.java:5542-5550，基準就是 <cacheDir>/Lua/、只做
-- File.exists；原版用例 MainOptions.lua:3522）而不是 getFileReader：後者對「不存在」
-- 與 IOException 都回 null，檔案存在但一時開不起來（被鎖、權限）會被誤判成不存在，
-- 然後覆寫掉管理員的編修。
local function alreadyThere(path)
    local ok, exists = pcall(cacheFileExists, path)
    if ok then return exists == true end
    -- 連檢查都失敗：寧可不寫（保住既有檔案），下次啟動再試
    return true
end

-- 逐行讀來源（BufferedReader；readLine 會剝掉行尾，寫回時自己補 "\n"）。
-- 任何一步失敗就回 nil，寧可這次不產生說明檔，也不要寫出半截的檔案——它是
-- exists-only，半截的會永遠留著。
local function readSource(src)
    local ok, reader = pcall(getModFileReader, MOD_ID, src, false)
    if not ok or not reader then return nil end
    local lines, n = {}, 0
    local okRead = pcall(function()
        local line = reader:readLine()
        while line ~= nil do
            n = n + 1
            lines[n] = line
            line = reader:readLine()
        end
    end)
    pcall(function() reader:close() end)
    if not okRead or n == 0 then return nil end
    return table.concat(lines, "\n", 1, n) .. "\n"
end

local function writeDoc(path, text)
    local writer = getFileWriter(path, true, false)
    if not writer then return false end
    local ok = pcall(function()
        writer:write(text)
        writer:close()
    end)
    if not ok then
        pcall(function() writer:close() end)
        return false
    end
    return true
end

local done = false
local function exportReadme()
    if done then return end
    done = true
    local wrote, failed = 0, 0
    for i = 1, #DOCS do
        local doc = DOCS[i]
        if not alreadyThere(doc.dest) then
            local text = readSource(doc.src)
            if text == nil then
                failed = failed + 1
            elseif writeDoc(doc.dest, text) then
                wrote = wrote + 1
            else
                failed = failed + 1
            end
        end
    end
    if wrote > 0 or failed > 0 then
        print("[MinidoracatMiniMap] export readme: wrote " .. wrote
            .. ", failed " .. failed)
    end
end

Events.OnServerStarted.Add(exportReadme)
Events.OnGameStart.Add(function()
    if not isClient() then exportReadme() end
end)
