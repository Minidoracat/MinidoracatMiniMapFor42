param(
    [ValidateSet('client', 'server', 'combo', 'cntrans', 'sync', 'stop')][string]$Action,
    [string]$ServerName = 'servertest',
    [ValidateRange(1, 2)][int]$Clients = 1,
    [switch]$NoSteam,
    [switch]$DebugClient,
    [switch]$ForceVerify,
    [switch]$LoadOnly
)

# Project Zomboid MOD 測試啟動器
# MinidoracatMiniMapFor42 小地圖模組

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

# ============================================
# 設定區 - 請根據你的環境修改
# ============================================
# 可用 $env:PZ_PATH 覆寫（隔離測試用），沒設就用預設安裝路徑
$PZ_PATH = if ($env:PZ_PATH) { $env:PZ_PATH } else { "D:\SteamLibrary\steamapps\common\ProjectZomboid" }
$script:SERVER_NAME = $ServerName
$script:PZForceVerify = [bool]$ForceVerify
$SERVER_MEMORY = "3072m"
# 統一漢化（B42Trans_CN）對照伺服器：設定檔自 servertest 複製、只換 Mods=（最小組合：
# UI 框架＋本 MOD＋統一漢化置底），驗證多人下街名／hover／導航兜底。已存在不覆蓋
$CNTRANS_NAME = "cntrans"
$CNTRANS_MODS = "Mods=\MinidoracatUIFor42;\MinidoracatMiniMapFor42;\B42Trans_CN"

# 專案根（.bat 以 & ScriptBlock 執行，沒有 $PSScriptRoot，PROJECT_ROOT 由 .bat 帶入）
if ($env:PROJECT_ROOT) { $ProjectRoot = $env:PROJECT_ROOT.TrimEnd('\') }
elseif ($PSScriptRoot) { $ProjectRoot = Split-Path -Parent $PSScriptRoot }
else { $ProjectRoot = (Get-Location).Path }
$ZomboidDir = Join-Path $env:USERPROFILE "Zomboid"
$ServerIniDir = Join-Path $ZomboidDir "Server"

# 實體同步引擎：symlink 掛載會讓 PZ 把來源目錄串到別的 MOD（已用真 jar 證實），改成啟動前把
# 來源複製成實體副本。引擎缺失一律 fail-closed：寧可不啟動，也不要讓遊戲載到舊副本。
foreach ($candidate in @((Join-Path $ProjectRoot "scripts\sync_mod.ps1"), $(if ($PSScriptRoot) { Join-Path $PSScriptRoot "sync_mod.ps1" }))) {
    if ($candidate -and (Test-Path -LiteralPath $candidate)) { . $candidate; break }
}

# 驗證遊戲路徑
if (-not $LoadOnly -and -not (Test-Path (Join-Path $PZ_PATH "ProjectZomboid64.exe"))) {
    $message = "找不到 Project Zomboid：$PZ_PATH。請設定 PZ_PATH 後重試。"
    if (-not $Action) {
        Add-Type -AssemblyName System.Windows.Forms
        [void][Windows.Forms.MessageBox]::Show($message, 'PZ 測試啟動器')
    }
    Write-Error $message
    exit 1
}

# ============================================
# 功能函式
# ============================================

function Invoke-PZLaunch {
    param([scriptblock]$Launch)
    try {
        . (Join-Path $ProjectRoot 'scripts\sync_mod.ps1')
        return (Invoke-PZSyncLaunch -ZomboidDir $ZomboidDir -Launch $Launch)
    } catch {
        Write-Host "[啟動] 同步引擎未就緒：$($_.Exception.Message)" -ForegroundColor Red
        return $false
    }
}

function Sync-PZBeforeLaunch {
    # 回傳 $true = 副本已同步（或已驗證一致）可以啟動；$false = 不可啟動
    # -CheckOnly：唯讀檢查，給「遊戲已在跑、不能換檔」的場合（既有 server、多開的第 2+ 個客戶端）
    param([string]$Name = $SERVER_NAME, [switch]$CheckOnly)
    if (-not (Get-Command Invoke-PZModSync -ErrorAction SilentlyContinue)) {
        Write-Host "[同步] 找不到同步引擎 scripts\sync_mod.ps1，為避免遊戲載到舊副本，本次不啟動。" -ForegroundColor Red
        return $false
    }
    $iniPath = Join-Path $ServerIniDir "$Name.ini"
    $result = Invoke-PZModSync -ProjectRoot $ProjectRoot -ZomboidDir $ZomboidDir -ServerIniPath $iniPath -CheckOnly:$CheckOnly -ForceVerify:$script:PZForceVerify
    if (-not ($result -is [bool] -and $result)) {
        $reason = if ($CheckOnly) { "副本與來源不一致，且遊戲執行中不能換檔" } else { "同步失敗" }
        Write-Host "[同步] $reason，本次不啟動。" -ForegroundColor Red
        return $false
    }
    $script:PZForceVerify = $false
    return $true
}

function Start-PZClient {
    # 回傳 $true = 已啟動；$false = 同步／檢查未過，未啟動
    param([switch]$Debug, [switch]$NoSteam, [switch]$CheckSyncOnly, [string]$Name = $SERVER_NAME)
    return (Invoke-PZLaunch {
    if (-not (Sync-PZBeforeLaunch -Name $Name -CheckOnly:$CheckSyncOnly)) {
        Write-Host "[客戶端] 已中止，未啟動客戶端。" -ForegroundColor Red
        return $false
    }
    $args_list = @()
    if ($NoSteam) { $args_list += "-nosteam" }
    if ($Debug) { $args_list += "-debug" }
    $mode = if ($Debug) { "Debug 模式" } else { "一般模式" }
    $steamTag = if ($NoSteam) { "no-Steam" } else { "Steam" }
    $exe = Join-Path $PZ_PATH "ProjectZomboid64.exe"

    Write-Host ""
    Write-Host "[客戶端] 啟動客戶端 ($steamTag / $mode)..." -ForegroundColor Cyan
    # Steam 一般模式沒有任何參數：Start-Process 不吃空的 -ArgumentList，必須整個省略
    if ($args_list.Count -gt 0) {
        Start-Process -FilePath $exe -ArgumentList $args_list -WorkingDirectory $PZ_PATH -ErrorAction Stop
    } else {
        Start-Process -FilePath $exe -WorkingDirectory $PZ_PATH -ErrorAction Stop
    }
    Write-Host "[客戶端] 客戶端已啟動！" -ForegroundColor Green
    Write-Host ""
    return $true
    })
}

function Ensure-CNTransConfig {
    $dir = $ServerIniDir
    $ini = Join-Path $dir "$CNTRANS_NAME.ini"
    if (Test-Path $ini) {
        Write-Host "[漢化對照] 沿用既有 $ini" -ForegroundColor DarkGray
        return $true
    }
    $src = Join-Path $dir "$SERVER_NAME.ini"
    if (-not (Test-Path $src)) {
        Write-Host "[漢化對照] 找不到來源 $src，請先啟動一次 $SERVER_NAME 伺服器產生設定。" -ForegroundColor Red
        return $false
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
        if ($LASTEXITCODE -ne 0) { Write-Host "[漢化對照] 帳號庫 world 欄位改寫失敗，取消啟動。" -ForegroundColor Red; return $false }
    }
    Write-Host "[漢化對照] 已自 $SERVER_NAME 複製設定＋帳號庫 → $CNTRANS_NAME（$CNTRANS_MODS）" -ForegroundColor Green
    return $true
}

function Get-PZServerProcess {
    param([string]$Name)
    # 用 CommandLine 認人：同名 server 才算同一台，避免 servertest／cntrans 互相誤判
    $processes = @(Get-CimInstance Win32_Process -Filter "Name = 'java.exe'" -ErrorAction Stop)
    if (@($processes | Where-Object { [string]::IsNullOrWhiteSpace($_.CommandLine) }).Count -gt 0) {
        throw '無法讀取 Java 程序命令列，不能確認是否已有測試伺服器。'
    }
    # 隔離 E2E 輪次（-cachedir= 指向別的使用者目錄）可能用同一個 -servername，但它是另一台伺服器，不能當成「已在執行」沿用；
    # -cachedir= 指向 $ZomboidDir 本身仍是這台，解析不了就無法確認（Get-PZSyncProfileKind 在 sync_mod.ps1）
    $processes | Where-Object {
            $_.CommandLine -match 'zombie\.network\.GameServer' -and
            $_.CommandLine -match ('-servername\s+"?' + [regex]::Escape($Name) + '"?(\s|$)')
        } | Where-Object {
            $kind = Get-PZSyncProfileKind $_.CommandLine $ZomboidDir
            if ($kind -eq 'unknown') { throw "無法確認 PID $($_.ProcessId) 的 -cachedir= 使用者目錄，不能確認是否已有測試伺服器。" }
            $kind -eq 'managed'
        }
}

function Start-PZServer {
    # 回傳 $true = 新啟動或既有同模式可直接用；$false = 模式不符（不 kill 舊的）或副本同步／檢查未過
    param([string]$Name = $SERVER_NAME, [switch]$NoSteam)
    return (Invoke-PZLaunch {
    $wantSteam = -not $NoSteam
    $steamTag = if ($wantSteam) { "Steam" } else { "no-Steam" }

    $running = @(Get-PZServerProcess -Name $Name)
    foreach ($process in $running) {
        $steam = $process.CommandLine -match '(?:^|\s)-Dzomboid\.steam=1(?:\s|$)' -and $process.CommandLine -notmatch '(?:^|\s)-nosteam(?:\s|$)'
        if ($steam -ne $wantSteam) {
            Write-Host "[伺服器] $Name 已在另一連線模式執行。請先於原伺服器輸入 quit 正常關服，再切換為 $steamTag；本次不啟動。" -ForegroundColor Red
            return $false
        }
    }
    if ($running.Count -gt 0) {
        # 既有 server 正持有 MOD 副本：只能唯讀檢查，不可換檔，也不停掉它
        if (-not (Sync-PZBeforeLaunch -Name $Name -CheckOnly)) {
            Write-Host "[伺服器] $Name 已在執行且副本需要更新。請先於原伺服器輸入 quit 關服，再重跑本選項讓副本同步；本次不啟動。" -ForegroundColor Red
            return $false
        }
        Write-Host "[伺服器] $Name ($steamTag) 已在執行，沿用原程序。" -ForegroundColor Yellow
        return $true
    }

    if (-not (Sync-PZBeforeLaunch -Name $Name)) {
        Write-Host "[伺服器] 已中止，未啟動伺服器。" -ForegroundColor Red
        return $false
    }

    Write-Host ""
    Write-Host "[伺服器] 啟動專用伺服器 ($steamTag)..." -ForegroundColor Cyan
    Write-Host "[伺服器] 名稱: $Name"
    Write-Host "[伺服器] 記憶體: $SERVER_MEMORY"
    Write-Host ""

    $javaPath = Join-Path $PZ_PATH "jre64\bin\java.exe"
    $javaArgs = @(
        "-XX:+UseZGC",
        "-XX:-CreateCoredumpOnCrash",
        "-XX:-OmitStackTraceInFastThrow",
        "-Xmx$SERVER_MEMORY",
        # 明確標記 Steam 屬性：客戶端 Steam／no-Steam 必須和伺服器一致才連得上
        "-Dzomboid.steam=$(if ($wantSteam) { 1 } else { 0 })",
        "-Djava.library.path=natives/;natives/win64/;./",
        "-cp", ".;projectzomboid.jar",
        "zombie.network.GameServer",
        "-servername", ('"' + $Name + '"')
    )

    Start-Process -FilePath $javaPath -ArgumentList $javaArgs -WorkingDirectory $PZ_PATH -ErrorAction Stop
    Write-Host "[伺服器] 伺服器已在新視窗啟動！" -ForegroundColor Green
    Write-Host "[伺服器] 可在伺服器視窗輸入指令，例如: grantadmin Minidoracat" -ForegroundColor DarkGray
    Write-Host ""
    return $true
    })
}

function Start-ServerAndClients {
    param(
        [int]$Clients = 1,
        [switch]$Debug,
        [switch]$NoSteam,
        [string]$Name = $SERVER_NAME
    )
    if (-not (Start-PZServer -Name $Name -NoSteam:$NoSteam)) {
        Write-Host "[一鍵] 伺服器未就緒（模式不符或副本同步未過），已中止，未啟動任何客戶端。" -ForegroundColor Red
        Write-Host ""
        return $false
    }

    Write-Host "[自動] 等待伺服器啟動 (15秒)..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 15
    for ($i = 1; $i -le $Clients; $i++) {
        if ($i -gt 1) { Start-Sleep -Seconds 3 }
        Write-Host "[自動] 啟動第 $i 個客戶端..." -ForegroundColor Cyan
        # server 已在跑：副本只驗不寫，避免對執行中的遊戲抽換檔案
        if (-not (Start-PZClient -Debug:$Debug -NoSteam:$NoSteam -CheckSyncOnly -Name $Name)) {
            Write-Host "[一鍵] 第 $i 個客戶端未通過副本檢查，後續客戶端一併中止。" -ForegroundColor Red
            Write-Host ""
            return $false
        }
    }

    $steamTag = if ($NoSteam) { "no-Steam" } else { "Steam" }
    $mode = if ($Debug) { "Debug" } else { "一般" }
    Write-Host "========================================" -ForegroundColor Green
    Write-Host "  全部啟動完成！" -ForegroundColor Green
    Write-Host "  伺服器: $Name ($steamTag)"
    Write-Host "  連線位址: 127.0.0.1"
    Write-Host "  客戶端數: $Clients（$steamTag / $mode 模式）"
    Write-Host "========================================" -ForegroundColor Green
    Write-Host ""
    return $true
}

function Stop-AllPZ {
    # 只停用 $ZomboidDir 的 PZ：-cachedir= 指向別的目錄是隔離 E2E 輪次（pz_e2e.py），由它自己 stop；
    # 讀不到命令列（含 java／javaw）、-cachedir= 解析不了或可能是別名的不猜、不殺，回 $false 讓使用者自行處理
    . (Join-Path $ProjectRoot 'scripts\sync_mod.ps1')
    $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop |
        Where-Object { $_.Name -in @('ProjectZomboid64.exe', 'ProjectZomboid32.exe') -or
            ($_.Name -in @('java.exe', 'javaw.exe') -and ([string]::IsNullOrWhiteSpace($_.CommandLine) -or
                $_.CommandLine -match 'zombie\.(network\.GameServer|gameStates\.MainScreenState)')) })
    $stopped = 0
    $unknown = @()
    foreach ($process in $processes) {
        $kind = Get-PZSyncProfileKind $process.CommandLine $ZomboidDir
        if ($kind -eq 'managed') { Stop-Process -Id $process.ProcessId -Force -ErrorAction Stop; $stopped++ }
        elseif ($kind -eq 'unknown') { $unknown += $process.ProcessId }
    }
    Write-Host "[停止] 已停止 $stopped 個 PZ 程序（隔離 E2E 輪次不受影響）。" -ForegroundColor Yellow
    if ($unknown.Count -gt 0) {
        Write-Host "[停止] PID $($unknown -join ', ') 無法確認使用者目錄（命令列讀不到、-cachedir= 解析不了或可能是別名），未停止；請自行確認後關閉。" -ForegroundColor Red
        return $false
    }
    return $true
}

function Write-CNTransHints {
    Write-Host "  伺服器: $CNTRANS_NAME（統一漢化 B42Trans_CN，無 LangFor42）"
    Write-Host "  驗收: 世界地圖街名中文、hover 變藍、導航沿路；"
    Write-Host "        console.txt 應有 'street data loaded via carrier fallback (B42Trans_CN)'"
    Write-Host ""
}

function Invoke-PZLauncherAction {
    param(
        [ValidateSet('client', 'server', 'combo', 'cntrans', 'sync', 'stop')][string]$Action,
        [string]$ServerName = 'servertest',
        [ValidateRange(1, 2)][int]$Clients = 1,
        [switch]$NoSteam,
        [switch]$DebugClient,
        [switch]$ForceVerify
    )
    if ([string]::IsNullOrWhiteSpace($ServerName) -or $ServerName -in @('.', '..') -or
        $ServerName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -ge 0 -or $ServerName.EndsWith('.')) {
        Write-Host '[啟動] 伺服器設定名稱不合法。' -ForegroundColor Red
        return $false
    }
    $script:SERVER_NAME = $ServerName
    $script:PZForceVerify = [bool]$ForceVerify
    if (-not $NoSteam -and $Clients -gt 1) {
        Write-Host '[啟動] Steam 模式僅能啟動一個客戶端；多開請選 no-Steam。' -ForegroundColor Red
        return $false
    }
    switch ($Action) {
        'client' {
            for ($i = 0; $i -lt $Clients; $i++) {
                if ($i -gt 0) { Start-Sleep -Seconds 3 }
                if (-not (Start-PZClient -NoSteam:$NoSteam -Debug:$DebugClient -CheckSyncOnly:($i -gt 0))) { return $false }
            }
            return $true
        }
        'server' { return (Start-PZServer -NoSteam:$NoSteam) }
        'combo' { return (Start-ServerAndClients -Clients $Clients -NoSteam:$NoSteam -Debug:$DebugClient) }
        'sync' { return (Sync-PZBeforeLaunch) }
        'stop' { return (Stop-AllPZ) }
        'cntrans' {
            if (-not (Ensure-CNTransConfig)) { return $false }
            if (-not (Start-ServerAndClients -Clients 1 -Debug -NoSteam:$NoSteam -Name $CNTRANS_NAME)) { return $false }
            Write-CNTransHints
            return $true
        }
    }
}

if ($LoadOnly) { return }
if ($Action) {
    $ErrorActionPreference = 'Stop'
    try {
        if (Invoke-PZLauncherAction -Action $Action -ServerName $ServerName -Clients $Clients `
            -NoSteam:$NoSteam -DebugClient:$DebugClient -ForceVerify:$ForceVerify) { exit 0 }
    } catch { Write-Host "[啟動] $($_.Exception.Message)" -ForegroundColor Red }
    exit 1
}

try {
    . (Join-Path $ProjectRoot 'scripts\PZ_Test_UI.ps1')
    Show-PZTestLauncher -ProjectRoot $ProjectRoot -LauncherPath (Join-Path $ProjectRoot 'scripts\PZ_Test.ps1') `
        -ZomboidDir $ZomboidDir -ModLabel 'MinidoracatMiniMapFor42 小地圖模組' -SupportsCNTrans
} catch {
    Add-Type -AssemblyName System.Windows.Forms
    [void][Windows.Forms.MessageBox]::Show($_.Exception.Message, 'PZ 啟動器無法開啟')
    exit 1
}
