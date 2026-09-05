# Project Zomboid MOD 測試啟動器
# MinidoracatMiniMapFor42 小地圖模組

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ============================================
# 設定區 - 請根據你的環境修改
# ============================================
$PZ_PATH = "D:\SteamLibrary\steamapps\common\ProjectZomboid"
$SERVER_NAME = "servertest"
$SERVER_MEMORY = "3072m"
# 統一漢化（B42Trans_CN）對照伺服器：設定檔自 servertest 複製、只換 Mods=（最小組合：
# UI 框架＋本 MOD＋統一漢化置底），驗證多人下街名／hover／導航兜底。已存在不覆蓋
$CNTRANS_NAME = "cntrans"
$CNTRANS_MODS = "Mods=\MinidoracatUIFor42;\MinidoracatMiniMapFor42;\B42Trans_CN"

# 驗證遊戲路徑
if (-not (Test-Path (Join-Path $PZ_PATH "ProjectZomboid64.exe"))) {
    Write-Host ""
    Write-Host "[錯誤] 找不到 Project Zomboid:" -ForegroundColor Red
    Write-Host "  $PZ_PATH" -ForegroundColor Red
    Write-Host ""
    Write-Host "請修改此腳本頂部的 `$PZ_PATH 變數。" -ForegroundColor Yellow
    Read-Host "按 Enter 結束"
    exit 1
}

# ============================================
# 功能函式
# ============================================

function Start-PZClient {
    param([switch]$Debug)
    $args_list = @("-nosteam")
    if ($Debug) { $args_list += "-debug" }
    $mode = if ($Debug) { "Debug 模式" } else { "一般模式" }

    Write-Host ""
    Write-Host "[客戶端] 啟動客戶端 ($mode)..." -ForegroundColor Cyan
    Start-Process -FilePath (Join-Path $PZ_PATH "ProjectZomboid64.exe") `
        -ArgumentList $args_list -WorkingDirectory $PZ_PATH
    Write-Host "[客戶端] 客戶端已啟動！" -ForegroundColor Green
    Write-Host ""
}

function Ensure-CNTransConfig {
    $dir = Join-Path $env:USERPROFILE "Zomboid\Server"
    $ini = Join-Path $dir "$CNTRANS_NAME.ini"
    if (Test-Path $ini) {
        Write-Host "[漢化對照] 沿用既有 $ini" -ForegroundColor DarkGray
        return
    }
    $src = Join-Path $dir "$SERVER_NAME.ini"
    if (-not (Test-Path $src)) {
        Write-Host "[漢化對照] 找不到來源 $src，先用 [3] 跑一次 $SERVER_NAME 產生設定" -ForegroundColor Red
        return
    }
    $text = Get-Content -Raw -Encoding UTF8 $src
    $text = $text -replace '(?m)^Mods=.*$', $CNTRANS_MODS
    [IO.File]::WriteAllText($ini, $text, (New-Object Text.UTF8Encoding $false))
    foreach ($suffix in @("_SandboxVars.lua", "_spawnpoints.lua", "_spawnregions.lua")) {
        $from = Join-Path $dir "$SERVER_NAME$suffix"
        if (Test-Path $from) { Copy-Item $from (Join-Path $dir "$CNTRANS_NAME$suffix") }
    }
    # 帳號庫（admin／白名單）一起帶過去，免得重建帳號。登入用 whitelist.world 比對伺服器名
    # （ServerWorldDatabase.java:1069 `WHERE username=? AND world=?`），複製後必改欄位
    $dbDir = Join-Path $env:USERPROFILE "Zomboid\db"
    $dbFrom = Join-Path $dbDir "$SERVER_NAME.db"
    $dbTo = Join-Path $dbDir "$CNTRANS_NAME.db"
    if (Test-Path $dbFrom) {
        Copy-Item $dbFrom $dbTo -Force
        # SQL 用 ? 參數＋argv 傳值：PowerShell → 原生程序會剝掉引號，內嵌雙引號活不了
        python -c "import sys,sqlite3;c=sqlite3.connect(sys.argv[1]);c.execute('update whitelist set world=?',(sys.argv[2],));c.commit()" $dbTo $CNTRANS_NAME
        if ($LASTEXITCODE -ne 0) { Write-Host "[漢化對照] 帳號庫 world 欄位改寫失敗（需要 python），帳號可能登不進" -ForegroundColor Red }
    }
    Write-Host "[漢化對照] 已自 $SERVER_NAME 複製設定＋帳號庫 → $CNTRANS_NAME（$CNTRANS_MODS）" -ForegroundColor Green
}

function Start-PZServer {
    param([string]$Name = $SERVER_NAME)
    Write-Host ""
    Write-Host "[伺服器] 啟動專用伺服器..." -ForegroundColor Cyan
    Write-Host "[伺服器] 名稱: $Name"
    Write-Host "[伺服器] 記憶體: $SERVER_MEMORY"
    Write-Host ""

    $javaPath = Join-Path $PZ_PATH "jre64\bin\java.exe"
    $javaArgs = @(
        "-XX:+UseZGC",
        "-XX:-CreateCoredumpOnCrash",
        "-XX:-OmitStackTraceInFastThrow",
        "-Xmx$SERVER_MEMORY",
        "-Djava.library.path=natives/;natives/win64/;./",
        "-cp", ".;projectzomboid.jar",
        "zombie.network.GameServer",
        "-servername", $Name
    )

    Start-Process -FilePath $javaPath -ArgumentList $javaArgs -WorkingDirectory $PZ_PATH
    Write-Host "[伺服器] 伺服器已在新視窗啟動！" -ForegroundColor Green
    Write-Host "[伺服器] 可在伺服器視窗輸入指令，例如: grantadmin Minidoracat" -ForegroundColor DarkGray
    Write-Host ""
}

function Stop-AllPZ {
    Write-Host ""
    Write-Host "[停止] 正在停止所有 PZ 相關進程..." -ForegroundColor Yellow
    $stopped = 0

    Get-Process -Name "java" -ErrorAction SilentlyContinue | ForEach-Object {
        $_ | Stop-Process -Force
        $stopped++
    }
    Get-Process -Name "ProjectZomboid64" -ErrorAction SilentlyContinue | ForEach-Object {
        $_ | Stop-Process -Force
        $stopped++
    }

    if ($stopped -gt 0) {
        Write-Host "[停止] 已停止 $stopped 個進程。" -ForegroundColor Green
    } else {
        Write-Host "[停止] 沒有找到執行中的 PZ 進程。" -ForegroundColor DarkGray
    }
    Write-Host ""
}

# ============================================
# 主選單
# ============================================
$Host.UI.RawUI.WindowTitle = "PZ Mod Test Launcher - MinidoracatMiniMapFor42"

while ($true) {
    Clear-Host
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host "  Project Zomboid MOD 測試啟動器" -ForegroundColor Cyan
    Write-Host "  MinidoracatMiniMapFor42 小地圖模組" -ForegroundColor Cyan
    Write-Host "========================================" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "  [1] 啟動客戶端"
    Write-Host "  [2] 啟動客戶端 (Debug 模式)"
    Write-Host ""
    Write-Host "  [3] 啟動專用伺服器 (Dedicated Server)"
    Write-Host "  [4] 一鍵啟動：伺服器 + 1 個客戶端"
    Write-Host "  [5] 一鍵啟動：伺服器 + 2 個客戶端"
    Write-Host "  [6] 僅啟動兩個客戶端 (Host 模式用)"
    Write-Host "  [7] 一鍵啟動：統一漢化對照伺服器 ($CNTRANS_NAME) + 1 個客戶端"
    Write-Host ""
    Write-Host "  [0] 停止所有 PZ 進程"
    Write-Host "  [Q] 離開"
    Write-Host ""
    $choice = Read-Host "請選擇"

    switch ($choice.ToUpper()) {
        "1" {
            Start-PZClient
            Read-Host "按 Enter 繼續"
        }
        "2" {
            Start-PZClient -Debug
            Read-Host "按 Enter 繼續"
        }
        "3" {
            Start-PZServer
            Read-Host "按 Enter 繼續"
        }
        "4" {
            Start-PZServer
            Write-Host "[自動] 等待伺服器啟動 (15秒)..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 15
            Start-PZClient -Debug
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "  全部啟動完成！" -ForegroundColor Green
            Write-Host "  伺服器: $SERVER_NAME"
            Write-Host "  連線位址: 127.0.0.1"
            Write-Host "========================================" -ForegroundColor Green
            Write-Host ""
            Read-Host "按 Enter 繼續"
        }
        "5" {
            Start-PZServer
            Write-Host "[自動] 等待伺服器啟動 (15秒)..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 15
            Write-Host "[自動] 啟動第一個客戶端..." -ForegroundColor Cyan
            Start-PZClient -Debug
            Start-Sleep -Seconds 3
            Write-Host "[自動] 啟動第二個客戶端..." -ForegroundColor Cyan
            Start-PZClient -Debug
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "  全部啟動完成！" -ForegroundColor Green
            Write-Host "  伺服器: $SERVER_NAME"
            Write-Host "  連線位址: 127.0.0.1"
            Write-Host "  客戶端數: 2"
            Write-Host "========================================" -ForegroundColor Green
            Write-Host ""
            Read-Host "按 Enter 繼續"
        }
        "6" {
            Write-Host ""
            Write-Host "[Host模式] 啟動第一個客戶端 (作為 Host)..." -ForegroundColor Cyan
            Start-PZClient -Debug
            Write-Host "[Host模式] 等待 5 秒..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 5
            Write-Host "[Host模式] 啟動第二個客戶端..." -ForegroundColor Cyan
            Start-PZClient -Debug
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "  兩個客戶端已啟動！" -ForegroundColor Green
            Write-Host "  第一個視窗: 選擇 HOST 建立伺服器"
            Write-Host "  第二個視窗: 選擇 JOIN - LAN - 127.0.0.1"
            Write-Host "========================================" -ForegroundColor Green
            Write-Host ""
            Read-Host "按 Enter 繼續"
        }
        "7" {
            Ensure-CNTransConfig
            Start-PZServer -Name $CNTRANS_NAME
            Write-Host "[自動] 等待伺服器啟動 (15秒)..." -ForegroundColor DarkGray
            Start-Sleep -Seconds 15
            Start-PZClient -Debug
            Write-Host "========================================" -ForegroundColor Green
            Write-Host "  全部啟動完成！" -ForegroundColor Green
            Write-Host "  伺服器: $CNTRANS_NAME（統一漢化 B42Trans_CN，無 LangFor42）"
            Write-Host "  連線位址: 127.0.0.1"
            Write-Host "  驗收: 世界地圖街名中文、hover 變藍、導航沿路；"
            Write-Host "        console.txt 應有 'street data loaded via carrier fallback (B42Trans_CN)'"
            Write-Host "========================================" -ForegroundColor Green
            Write-Host ""
            Read-Host "按 Enter 繼續"
        }
        "0" {
            Stop-AllPZ
            Read-Host "按 Enter 繼續"
        }
        "Q" {
            Write-Host ""
            Write-Host "再見！"
            exit 0
        }
    }
}
