-- MinidoracatMiniMap_Skin.lua
-- 本檔範圍：圓角皮膚與色票（搜尋視窗等本 MOD 現代化 UI 共用）。移植自家族
-- MinidoracatNoticeBoardFor42 的 NBSkin（貼圖同一套 9-slice 資產拷入
-- media/ui/MinidoracatMiniMap/；設計文件見該 repo docs/UI_SKIN_TEXTURES.md、
-- docs/UI_DESIGN.md）。
--
-- 圓角走引擎原生 9-slice `NinePatchTexture`（zombie/core/textures/
-- NinePatchTexture.java，Lua 曝露 LuaManager.java:1850）：切線寫在 PNG 第一列/
-- 第一欄、角落 1:1、拉伸區 GL_NEAREST；render 吃絕對螢幕座標且不 floor，
-- 這裡先 getAbsoluteX/Y 再 math.floor 防 1px 抖動。
--
-- 退回紅線（同 NBSkin）：**任何貼圖缺失都不可讓視窗開不了或畫面空白**——
-- 載入只在首次繪製發生（載入期不碰 getTexture）、pcall＋nil 檢查，壞掉記
-- false 永不重試，之後一律走 drawRect/drawRectBorder 直角退回。
-- NinePatchTexture 全域不存在（dedicated/離線測試）也是同一條退回路徑。
local Core = MinidoracatMiniMapCore
if not (Core and Core.ready) then return end

MinidoracatMiniMapSkin = MinidoracatMiniMapSkin or {}
local Skin = MinidoracatMiniMapSkin

local TEXTURE_DIR = "media/ui/MinidoracatMiniMap/"
local CORNER = 6 -- 貼圖角落＝圓角半徑；矩形短於兩角之和不走 9-slice（角落重疊會疊 alpha）

-- 色票（與 NoticeBoard 同源，UI 家族一致；r,g,b,a 皆 0-1）
-- 色票與 reset()/alphaScale 依 NoticeBoard 基準整包保留（含目前未引用項）：
-- 刻意與家族共用色票同步、勿依本 MOD 當下用量裁剪——後續 UI（toast/浮鈕等）
-- 沿用同一套，跨 MOD 視覺一致性優先（claude review 裁決：保留並明示）
Skin.COLORS = {
    BG_PANEL = { r = 0, g = 0, b = 0, a = 0.8 },
    BORDER = { r = 0.4, g = 0.4, b = 0.4, a = 1.0 },
    TITLE_TEXT = { r = 1, g = 1, b = 1, a = 1.0 },
    TITLEBAR_FILL = { r = 1, g = 1, b = 1, a = 0.10 },
    ROW_HOVER = { r = 1, g = 1, b = 1, a = 0.06 },
    ROW_SELECTED = { r = 1, g = 1, b = 1, a = 0.12 },
    TEXT_PRIMARY = { r = 1, g = 1, b = 1, a = 1.0 },
    TEXT_MUTED = { r = 0.62, g = 0.62, b = 0.62, a = 1.0 },
    ACCENT_AMBER = { r = 1, g = 0.85, b = 0.4, a = 1.0 },
    FIELD_BG = { r = 0, g = 0, b = 0, a = 0.5 },
    PLACEHOLDER_TEXT = { r = 0.55, g = 0.55, b = 0.55, a = 1.0 },
}

local textures = {} -- 檔名 -> NinePatchTexture；false = 載入失敗，session 內不再重試

function Skin.reset()
    textures = {}
end

function Skin.fits(width, height, topOnly)
    local minimumHeight = CORNER * 2
    if topOnly then minimumHeight = CORNER end
    return width >= CORNER * 2 and height >= minimumHeight
end

local function ninePatch(name)
    local cached = textures[name]
    if cached ~= nil then
        if cached == false then return nil end
        return cached
    end
    if not NinePatchTexture or not NinePatchTexture.getSharedTexture then
        textures[name] = false
        return nil
    end
    local ok, loaded = pcall(function()
        local path = TEXTURE_DIR .. name
        -- getSharedTexture 第一次呼叫必回 null（載入完直接 return null，
        -- NinePatchTexture.java:56-63），第二次才命中快取（:46-48）；已在快取
        -- 時第一次就命中，or 短路不多呼叫。兩次都 nil＝檔案不存在或已進黑名單
        return NinePatchTexture.getSharedTexture(path)
            or NinePatchTexture.getSharedTexture(path)
    end)
    if not ok or not loaded then
        textures[name] = false
        return nil
    end
    textures[name] = loaded
    return loaded
end

-- pcall 用具名頂層函式＋傳參（review：inline closure 會在每次 fill/border
-- 配置一個捕捉外層變數的匿名函式——皮膚視窗每幀 3+ 呼叫＝穩定 GC 壓力；
-- pcall(luaFn, args...) 零配置。NBSkin 原版用 closure，此為本 MOD 改良）
local function renderNine(npt, ax, ay, w, h, r, g, b, a)
    npt:render(ax, ay, w, h, r, g, b, a)
end

-- 回 true＝已用 9-slice 畫完；false＝呼叫端走直角退回
local function drawNinePatch(element, name, x, y, width, height, color, alpha)
    local npt = ninePatch(name)
    if not npt then return false end
    -- 絕對座標＋自身捲動位移：getAbsoluteX/Y 只含 parent 鏈 scroll、不含自身
    -- （UIElement.java:930-948），而 drawRect 系繪製上下文吃自身 scroll——
    -- 9-slice 走絕對螢幕座標必須手補，否則捲動清單內的列高亮會錯位
    -- （codex review；非捲動視窗 getXScroll()=0 無害）
    local ax = math.floor(element:getAbsoluteX() + element:getXScroll() + x)
    local ay = math.floor(element:getAbsoluteY() + element:getYScroll() + y)
    local ok = pcall(renderNine, npt, ax, ay, math.floor(width), math.floor(height),
        color.r, color.g, color.b, alpha)
    if not ok then
        textures[name] = false
        return false
    end
    return true
end

-- 圓角填色。topOnly=true 只圓上兩角（標題列）。alphaScale＝動畫 alpha 乘數
function Skin.fill(element, x, y, width, height, color, topOnly, alphaScale)
    local alpha = color.a * (alphaScale or 1)
    if Skin.fits(width, height, topOnly) then
        local name = topOnly and "nb_roundtop_fill.png" or "nb_round_fill.png"
        if drawNinePatch(element, name, x, y, width, height, color, alpha) then
            return
        end
    end
    element:drawRect(x, y, width, height, alpha, color.r, color.g, color.b)
end

-- 1px 圓角邊框。topOnly=true 上圓、底邊開放
function Skin.border(element, x, y, width, height, color, topOnly, alphaScale)
    local alpha = color.a * (alphaScale or 1)
    if Skin.fits(width, height, topOnly) then
        local name = topOnly and "nb_roundtop_border.png" or "nb_round_border.png"
        if drawNinePatch(element, name, x, y, width, height, color, alpha) then
            return
        end
    end
    element:drawRectBorder(x, y, width, height, alpha, color.r, color.g, color.b)
end

Core.Skin = Skin
