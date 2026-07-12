# MinidoracatMiniMapFor42 基底 pyramid 產生腳本
#
# 呼叫 MinidoracatMapRendering 的 pzmap.exe render-minimap，
# 把基底地圖渲染成 ImagePyramid zip，輸出到：
#   MOD/.../42/media/minimap/Muldraugh_KY.pyramid.zip
#
# 支援地圖 MOD：用 pzmap Studio（GUI）選該地圖 →「遊戲內小地圖」模式輸出
# <地圖名>.pyramid.zip（預設輸出名，免改名），放進本 MOD 的 media/minimap/
# 並在 MinidoracatMiniMap.lua 的 MAPS manifest 加一行對應該地圖 mod ID。
# 第三方 MOD 自帶支援則沿用同名約定 minidoracat_minimap.pyramid.zip（零 Lua）。
#
# 用法：
#   pwsh -NoProfile -File scripts/build_pyramids.ps1
#   pwsh -NoProfile -File scripts/build_pyramids.ps1 -GamePath "E:\Steam\...\ProjectZomboid" -MapName "Muldraugh, KY"
#
# 注意：render-minimap 會把整張輸出圖放在 RAM（全圖約 1.3 GB），耗時數分鐘。

param(
    [string]$GamePath = "",
    [string]$MapName  = "Muldraugh, KY",
    [string]$PzmapExe = "D:\github\MinidoracatMapRendering\target\release\pzmap.exe"
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ProjectRoot = Split-Path -Parent $PSScriptRoot
# 輸出檔名從地圖名衍生（同 pzmap Studio safeName 規則："Muldraugh, KY" → Muldraugh_KY），
# 避免 -MapName 指定其他地圖時內容冒充基底檔名；非基底地圖記得在 MAPS manifest 登記
$SafeName = ($MapName -replace '[^A-Za-z0-9]+', '_').Trim('_')
$OutFile = Join-Path $ProjectRoot "MOD\MinidoracatMiniMapFor42\Contents\mods\MinidoracatMiniMapFor42\42\media\minimap\$SafeName.pyramid.zip"

# ============================================
# 驗證 pzmap.exe 與 render-minimap 子命令
# ============================================
if (-not (Test-Path $PzmapExe)) {
    Write-Host "[錯誤] 找不到 pzmap.exe:" -ForegroundColor Red
    Write-Host "  $PzmapExe" -ForegroundColor Red
    Write-Host "請先在 MinidoracatMapRendering 專案執行 cargo build --release，" -ForegroundColor Yellow
    Write-Host "或用 -PzmapExe 參數指定路徑。" -ForegroundColor Yellow
    exit 1
}

$usage = & $PzmapExe 2>&1 | Out-String
if ($usage -notmatch "render-minimap") {
    Write-Host "[錯誤] 此版 pzmap.exe 沒有 render-minimap 子命令。" -ForegroundColor Red
    Write-Host "請更新 MinidoracatMapRendering 並重新 cargo build --release。" -ForegroundColor Yellow
    exit 1
}

# ============================================
# 自動偵測遊戲路徑（未以 -GamePath 指定時）
# ============================================
if (-not $GamePath) {
    $candidates = @(
        "D:\SteamLibrary\steamapps\common\ProjectZomboid",
        "C:\Program Files (x86)\Steam\steamapps\common\ProjectZomboid",
        "C:\SteamLibrary\steamapps\common\ProjectZomboid",
        "E:\SteamLibrary\steamapps\common\ProjectZomboid"
    )
    $GamePath = $candidates | Where-Object { Test-Path (Join-Path $_ "ProjectZomboid64.exe") } | Select-Object -First 1
    if (-not $GamePath) {
        Write-Host "[錯誤] 自動偵測不到 Project Zomboid 安裝目錄。" -ForegroundColor Red
        Write-Host "請用 -GamePath 參數指定，例如：" -ForegroundColor Yellow
        Write-Host '  pwsh -File scripts/build_pyramids.ps1 -GamePath "D:\SteamLibrary\steamapps\common\ProjectZomboid"' -ForegroundColor Yellow
        exit 1
    }
    Write-Host "[偵測] 遊戲路徑: $GamePath" -ForegroundColor DarkGray
}

# ============================================
# 渲染
# ============================================
Write-Host ""
Write-Host "[渲染] 地圖: $MapName" -ForegroundColor Cyan
Write-Host "[渲染] 輸出: $OutFile" -ForegroundColor Cyan
Write-Host ""

& $PzmapExe render-minimap --game $GamePath --map $MapName --out $OutFile
if ($LASTEXITCODE -ne 0) {
    Write-Host ""
    Write-Host "[錯誤] pzmap render-minimap 失敗（exit $LASTEXITCODE）。" -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host ""
Write-Host "[完成] pyramid zip 已產生：" -ForegroundColor Green
Write-Host "  $OutFile" -ForegroundColor Green
if ($SafeName -ne "Muldraugh_KY") {
    Write-Host "[提醒] 非基底地圖：記得在 MinidoracatMiniMap.lua 的 MAPS manifest 加一行對應該地圖 mod ID" -ForegroundColor Yellow
}
