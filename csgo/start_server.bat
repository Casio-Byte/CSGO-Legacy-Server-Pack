@echo off
setlocal
title CS:GO server launcher

rem ==================================================================
rem  Starts the CS:GO server. Double-click to run.
rem
rem  First run: asks a few questions (server name, passwords, LAN or
rem  internet...) and saves the answers. After that it just starts:
rem    1. downloads any missing community maps (1v1 arenas)
rem    2. starts FastDL so players can download maps quickly
rem    3. starts the server, and restarts it if it crashes
rem
rem  To change your answers later:  start_server.bat setup
rem  (or delete launcher_settings.cmd and run it again)
rem ==================================================================

set "CSGO_DIR=%~dp0"
set "BATCH_SELF=%~f0"
set "SETTINGS=%~dp0launcher_settings.cmd"
set "SRCDS=%~dp0..\srcds.exe"

if not exist "%SRCDS%" (
    echo.
    echo Could not find srcds.exe one folder above this file:
    echo   "%SRCDS%"
    echo start_server.bat must be in your server's csgo folder ^(the folder that
    echo contains addons, cfg and maps - srcds.exe is in the folder above it^).
    echo.
    pause
    exit /b 1
)

if /i "%~1"=="setup" goto :setup
if not exist "%SETTINGS%" goto :setup
if not exist "%CSGO_DIR%cfg\csgo_match\server_settings.cfg" goto :setup
findstr /c:"SETUP_PENDING" "%CSGO_DIR%cfg\csgo_match\server_settings.cfg" >nul 2>&1 && goto :setup
goto :start

:setup
powershell -NoProfile -ExecutionPolicy Bypass -Command "$f=[IO.File]::ReadAllText($env:BATCH_SELF); iex ($f.Substring($f.LastIndexOf('#POWERSHELL#') + 12))"
if not exist "%SETTINGS%" (
    echo.
    echo Setup didn't finish - nothing was saved.
    pause
    exit /b 1
)
title CS:GO server launcher

:start
call "%SETTINGS%"
rem Deathmatch now runs on Casual with the match plugin's rules (older setups used the game's own DM).
if /i "%SETUP_GAMEMODE%"=="deathmatch" set "MODE_ARGS=+game_type 0 +game_mode 0 -match_mode deathmatch"
if not defined MODE_ARGS (
    echo.
    echo New setting: default game mode and first map. Press Enter to keep your other answers.
    goto :setup
)

set "TOKEN_ARG="
if defined GSLT set "TOKEN_ARG=+sv_setsteamaccount %GSLT%"

if "%AUTO_DOWNLOAD_MAPS%"=="1" (
    if exist "%CSGO_DIR%download_community_maps.bat" (
        echo Checking for missing community maps...
        call "%CSGO_DIR%download_community_maps.bat" auto
        title CS:GO server launcher
    ) else (
        echo download_community_maps.bat not found next to this file - skipping map downloads.
    )
)

if "%START_FASTDL%"=="1" (
    if exist "%CSGO_DIR%start_fastdl.bat" (
        echo Starting FastDL in the background...
        start "CS:GO FastDL" /min cmd /c ""%CSGO_DIR%start_fastdl.bat" background"
    ) else (
        echo start_fastdl.bat not found next to this file - skipping FastDL.
    )
)

:findmap
rem The map's real path: its mode folder, csgo\maps, or a Workshop folder.
set "MAP_PATH="
if exist "%CSGO_DIR%maps\modes\%SETUP_GAMEMODE%\%SETUP_MAP%.bsp" set "MAP_PATH=modes/%SETUP_GAMEMODE%/%SETUP_MAP%"
if not defined MAP_PATH if exist "%CSGO_DIR%maps\%SETUP_MAP%.bsp" set "MAP_PATH=%SETUP_MAP%"
if not defined MAP_PATH if exist "%CSGO_DIR%maps\workshop\" for /d %%D in ("%CSGO_DIR%maps\workshop\*") do if exist "%%~fD\%SETUP_MAP%.bsp" set "MAP_PATH=workshop/%%~nxD/%SETUP_MAP%"
set "START_ARGS=%MODE_ARGS% +map %MAP_PATH%"
if defined MAP_PATH goto :server
echo.
echo The first map %SETUP_MAP% isn't on the server - starting Competitive on de_dust2 instead.
echo Put the map in csgo\maps\modes\%SETUP_GAMEMODE%\ or run "start_server.bat setup" to pick another.
set "START_ARGS=+game_type 0 +game_mode 1 +map de_dust2"

:server
echo.
echo [%date% %time%] Starting the CS:GO server...
pushd "%~dp0.."
start "CS:GO server" /wait "%SRCDS%" %LAUNCH_OPTIONS% %START_ARGS% %TOKEN_ARG%
popd
echo [%date% %time%] The server closed.

if "%AUTO_RESTART%"=="1" (
    echo Restarting in 10 seconds - close this window to stop for good.
    timeout /t 10 >nul
    goto :findmap
)

rem Server is done: stop FastDL too.
if "%START_FASTDL%"=="1" (
    taskkill /FI "WINDOWTITLE eq CS:GO FastDL*" /T /F >nul 2>&1
    echo FastDL stopped.
)
echo.
pause
exit /b 0

#POWERSHELL#
# ---------------- First-run setup ----------------
$ErrorActionPreference = 'Continue'
$csgo = $env:CSGO_DIR.TrimEnd('\', '/')
$settingsFile = $env:SETTINGS

# Characters that would break the batch file or a cfg line.
function Clean([string]$v) { if ($null -eq $v) { return '' }; return ($v -replace '["%^&|<>;\r\n]', '').Trim() }

function Ask([string]$question, [string]$default) {
    $hint = if ($default) { " [$default]" } else { '' }
    $answer = Read-Host "$question$hint"
    if ([string]::IsNullOrWhiteSpace($answer)) { return $default }
    return $answer.Trim()
}

function AskYesNo([string]$question, [bool]$default) {
    $d = if ($default) { 'Y' } else { 'N' }
    while ($true) {
        $a = Ask "$question (Y/N)" $d
        if ($a -match '^[Yy]') { return $true }
        if ($a -match '^[Nn]') { return $false }
    }
}

function AskNumber([string]$question, [int]$default, [int]$min, [int]$max) {
    while ($true) {
        $a = Ask $question "$default"
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge $min -and $n -le $max) { return $n }
        Write-Host "  Please enter a number from $min to $max." -ForegroundColor Yellow
    }
}

# Existing values make good defaults: previous answers, then server.cfg.
$old = @{}
if (Test-Path $settingsFile) {
    Get-Content $settingsFile | ForEach-Object { if ($_ -match '^set "([A-Z_]+)=(.*)"$') { $old[$matches[1]] = $matches[2] } }
}
$cfgOld = @{}
foreach ($f in @((Join-Path $csgo 'cfg\server.cfg'), (Join-Path $csgo 'cfg\autoexec.cfg'), (Join-Path $csgo 'cfg\csgo_match\server_settings.cfg'))) {
    if (Test-Path $f) {
        Get-Content $f | ForEach-Object {
            if ($_ -match '^\s*(hostname|sv_password|rcon_password|match_admin_password)\s+"?([^"]*)"?') { $cfgOld[$matches[1]] = $matches[2].Trim() }
        }
    }
}
function OldOr([string]$key, [string]$fallback) { if ($old.ContainsKey($key) -and $old[$key]) { return $old[$key] }; return $fallback }

Clear-Host
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host '  CS:GO server - first-run setup' -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host 'Press Enter to keep the value in [brackets].'
Write-Host ''

$hostname = Clean (Ask 'Server name' $(if ($cfgOld.hostname) { $cfgOld.hostname } else { 'My CS:GO Server' }))
$joinPass = Clean (Ask 'Password to join (leave empty for none)' $cfgOld.sv_password)

$rcon = Clean (Ask 'RCON password (leave empty to make a random one)' $cfgOld.rcon_password)
if (-not $rcon) {
    $chars = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKLMNPQRSTUVWXYZ23456789'
    $rcon = -join (1..16 | ForEach-Object { $chars[(Get-Random -Maximum $chars.Length)] })
    Write-Host "  RCON password: $rcon" -ForegroundColor DarkGray
}

Write-Host ''
Write-Host 'Admin password: type /login <password> in game to become admin.'
$adminPass = Clean (Ask 'Admin password (leave empty to turn /login off)' $cfgOld.match_admin_password)

Write-Host ''
$maxPlayers = AskNumber 'Max players' ([int](OldOr 'SETUP_MAXPLAYERS' '16')) 2 64
$tickrate   = AskNumber 'Tickrate (64 or 128)' ([int](OldOr 'SETUP_TICKRATE' '128')) 64 128
$port       = AskNumber 'Port' ([int](OldOr 'SETUP_PORT' '27015')) 1024 65535

# ---- Default game mode and first map (menus) ----
# name, folder (csgo\maps\modes\<folder>), game_type, game_mode, -match_mode, default map
$modes = @(
    @('Competitive 5v5',  'competitive', 0, 1, '',         'de_dust2'),
    @('Wingman 2v2',      'wingman',     0, 2, '',         'de_shortdust'),
    @('Casual',           'casual',      0, 0, '',         'de_dust2'),
    @('Deathmatch (free-for-all, AK + Deagle)', 'deathmatch', 0, 0, 'deathmatch', 'de_dust2'),
    @('Arms Race',        'armsrace',    1, 0, '',         'ar_baggage'),
    @('Demolition',       'demolition',  1, 1, '',         'de_lake'),
    @('Practice',         'practice',    0, 1, 'practice', 'de_mirage'),
    @('1v1 duels',        '1v1',         0, 1, '1v1',      'aim_redline'),
    @('Multi-1v1 arenas', 'arena',       0, 0, 'arena',    'am_must2'),
    @('Retakes (!guns loadouts)', 'retakes', 0, 1, 'retakes', 'de_dust2')
)

# Which modes a map suits (same rules as the match plugin).
function MapFits([string]$m, [string]$folder) {
    # A map in the mode's own folder always counts for that mode.
    if (Test-Path (Join-Path $csgo "maps\modes\$folder\$m.bsp")) { return $true }
    $m = $m.ToLower()
    if ($m -match '^(kz_|bhop_|surf_)') { return $false }
    if ($m.StartsWith('am_'))  { return $folder -eq 'arena' }
    if ($m -match '^(aim_|awp_|1v1_|training_aim)') { return $folder -eq '1v1' }
    if ($m.StartsWith('ar_'))  { return $folder -eq 'armsrace' }
    if ($folder -eq 'retakes') {
        # bomb maps with retakes spawns (the pack has them for 24 maps)
        return (Test-Path (Join-Path $csgo "addons\sourcemod\configs\retakes\$m.cfg"))
    }
    return @('competitive', 'wingman', 'casual', 'deathmatch', 'demolition', 'practice') -contains $folder
}

function MapState([string]$m, [string]$folder) {
    if (Test-Path (Join-Path $csgo "maps\modes\$folder\$m.bsp")) { return '' }
    if (Test-Path (Join-Path $csgo "maps\$m.bsp")) { return '' }
    if (@(Get-ChildItem -Path (Join-Path $csgo 'maps\workshop') -Filter "$m.bsp" -Recurse -ErrorAction SilentlyContinue).Count -gt 0) { return '' }
    $dl = Join-Path $csgo "maps\modes\$folder\downloads.txt"
    if ((Test-Path $dl) -and (Select-String -Path $dl -Pattern ('^\s*' + [regex]::Escape($m) + '(\s|$)') -Quiet)) { return ' (downloads on start)' }
    return ' (not installed)'
}

$oldModeIdx = 1
for ($i = 0; $i -lt $modes.Count; $i++) { if ($modes[$i][1] -eq (OldOr 'SETUP_GAMEMODE' 'competitive')) { $oldModeIdx = $i + 1 } }

Write-Host ''
Write-Host 'Default game mode (the server starts in this one; admins can still change it with !gamemode):'
for ($i = 0; $i -lt $modes.Count; $i++) { Write-Host ("  {0} = {1}" -f ($i + 1), $modes[$i][0]) }
$modeIdx = AskNumber "Choose 1-$($modes.Count)" $oldModeIdx 1 $modes.Count
$gm = $modes[$modeIdx - 1]
$gmFolder = $gm[1]

# Map menu from the mode's maplist.txt (falls back to the mode's default map).
$maps = @()
$listFile = Join-Path $csgo "maps\modes\$gmFolder\maplist.txt"
if (Test-Path $listFile) {
    $maps = @(Get-Content $listFile | ForEach-Object { ($_.Trim() -split '\s+')[0] } |
              Where-Object { $_ -and -not $_.StartsWith('//') } | ForEach-Object { $_ -replace '\.bsp$', '' } |
              Where-Object { MapFits $_ $gmFolder } | Select-Object -Unique)
}
if ($maps.Count -eq 0) { $maps = @($gm[5]) }

$oldMap = OldOr 'SETUP_MAP' ''
$defMap = 1
for ($i = 0; $i -lt $maps.Count; $i++) { if ($maps[$i] -eq $oldMap) { $defMap = $i + 1 } }
if ($defMap -eq 1 -and $oldMap -and -not ($maps -contains $oldMap) -and (MapFits $oldMap $gmFolder) -and ((OldOr 'SETUP_GAMEMODE' '') -eq $gmFolder)) { $defMap = 0 }

Write-Host ''
Write-Host "First map for $($gm[0]):"
for ($i = 0; $i -lt $maps.Count; $i++) { Write-Host ("  {0,2} = {1}{2}" -f ($i + 1), $maps[$i], (MapState $maps[$i] $gmFolder)) }
Write-Host "   0 = type a map name$(if ($defMap -eq 0) { " (currently $oldMap)" })"
$mapIdx = AskNumber "Choose 0-$($maps.Count)" $defMap 0 $maps.Count
if ($mapIdx -gt 0) {
    $map = $maps[$mapIdx - 1]
} else {
    while ($true) {
        $map = (Clean (Ask 'Map name (e.g. de_dust2)' $(if ($defMap -eq 0) { $oldMap } else { '' }))) -replace '\.bsp$', ''
        $map = ($map -split '[\\/]')[-1]
        if (-not $map) { continue }
        if (MapFits $map $gmFolder) { break }
        Write-Host "  $map doesn't suit $($gm[0]) - pick a map made for it." -ForegroundColor Yellow
    }
    $st = MapState $map $gmFolder
    if ($st -eq ' (not installed)') { Write-Host "  $map isn't on the server yet - put it in csgo\maps\modes\$gmFolder\ (or csgo\maps\) before starting." -ForegroundColor Yellow }
}
$modeArgs = "+game_type $($gm[2]) +game_mode $($gm[3])"
if ($gm[4]) { $modeArgs += " -match_mode $($gm[4])" }

Write-Host ''
Write-Host 'How will people connect?'
Write-Host '  1 = LAN / virtual LAN (home network, Tailscale, ZeroTier) - most reliable for CS:GO now'
Write-Host '  2 = Internet (needs a login token and port forwarding)'
$mode = AskNumber 'Choose 1 or 2' ([int](OldOr 'SETUP_NETWORK' '1')) 1 2

$gslt = ''
if ($mode -eq 2) {
    Write-Host ''
    Write-Host 'Login token: steamcommunity.com/dev/managegameservers  (App ID 730)'
    $gslt = Clean (Ask 'Login token' (OldOr 'GSLT' ''))
    if (-not $gslt) { Write-Host '  No token - the server will only accept LAN players.' -ForegroundColor Yellow }
}

# Address players download maps from (FastDL): LAN IP, or public IP for internet.
$lanIp = $null
try {
    $lanIp = Get-NetIPConfiguration -ErrorAction Stop |
             Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
             ForEach-Object { $_.IPv4Address.IPAddress } | Select-Object -First 1
} catch {}
$dlIp = $lanIp
if ($mode -eq 2) {
    $publicIp = $null
    try { $publicIp = (Invoke-RestMethod -Uri 'https://api.ipify.org' -TimeoutSec 5).ToString().Trim() } catch {}
    Write-Host ''
    Write-Host 'Map downloads (FastDL) need your public IP so friends over the internet can reach it.'
    $dlIp = Clean (Ask 'Public IP' $(if ($publicIp) { $publicIp } else { '' }))
    if (-not $dlIp) { $dlIp = $lanIp }
} else {
    Write-Host ''
    Write-Host 'Map downloads (FastDL): players download from this PC. Use your Tailscale/ZeroTier IP'
    Write-Host 'here if friends join over a virtual LAN.'
    $dlIp = Clean (Ask 'IP players use to reach this PC' $(OldOr 'SETUP_DOWNLOAD_IP' $lanIp))
}

Write-Host ''
$autoMaps    = AskYesNo 'Download missing community maps on start' ((OldOr 'AUTO_DOWNLOAD_MAPS' '1') -eq '1')
$fastdl      = AskYesNo 'Run FastDL (fast map downloads for players)' ((OldOr 'START_FASTDL' '1') -eq '1')
$autoRestart = AskYesNo 'Restart the server automatically if it crashes' ((OldOr 'AUTO_RESTART' '1') -eq '1')

# ---- Build the launch options ----
# Game mode and map are added at each start (start_server.bat finds the map's
# real path after the map downloads have run).
$launch = "-game csgo -console -usercon -port $port -tickrate $tickrate -maxplayers_override $maxPlayers +mapgroup mg_active"
if ($mode -eq 1) { $launch += ' -insecure +sv_lan 1' } else { $launch += ' +sv_lan 0' }

# ---- launcher_settings.cmd ----
$b = { param($v) if ($v) { '1' } else { '0' } }
Set-Content -Path $settingsFile -Value @(
    '@rem Written by start_server.bat setup. Run "start_server.bat setup" to change.',
    "set `"LAUNCH_OPTIONS=$launch`"",
    "set `"GSLT=$gslt`"",
    "set `"AUTO_DOWNLOAD_MAPS=$(& $b $autoMaps)`"",
    "set `"START_FASTDL=$(& $b $fastdl)`"",
    "set `"AUTO_RESTART=$(& $b $autoRestart)`"",
    "set `"SETUP_MAXPLAYERS=$maxPlayers`"",
    "set `"SETUP_TICKRATE=$tickrate`"",
    "set `"SETUP_PORT=$port`"",
    "set `"SETUP_MAP=$map`"",
    "set `"SETUP_GAMEMODE=$gmFolder`"",
    "set `"MODE_ARGS=$modeArgs`"",
    "set `"SETUP_NETWORK=$mode`"",
    "set `"SETUP_DOWNLOAD_IP=$dlIp`""
)

# ---- cfg\csgo_match\server_settings.cfg (the match plugin loads it every map) ----
$cfgDir = Join-Path $csgo 'cfg\csgo_match'
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
Set-Content -Path (Join-Path $cfgDir 'server_settings.cfg') -Value @(
    '// Written by start_server.bat setup - loaded by the match plugin every map.',
    '// Run "start_server.bat setup" to change these, or edit them here.',
    "hostname `"$hostname`"",
    "sv_password `"$joinPass`"",
    "rcon_password `"$rcon`"",
    "match_admin_password `"$adminPass`"",
    $(if ($mode -eq 1) { 'sv_lan 1' } else { 'sv_lan 0' })
)

# ---- cfg\csgo_match\fastdl.cfg ----
if ($dlIp) {
    Set-Content -Path (Join-Path $cfgDir 'fastdl.cfg') -Value @(
        '// Written by start_server.bat setup - loaded by the match plugin every map.',
        '// Where players download missing maps from (start_fastdl.bat serves them).',
        'sv_allowdownload 1',
        "sv_downloadurl `"http://${dlIp}:27020/`""
    )
}

# ---- Remove settings the setup owns from other cfgs, so they can't override it ----
# (e.g. an old "sv_lan 1" in server.cfg forces LAN-only even in Internet mode)
$owned = '^\s*(hostname|sv_password|rcon_password|sv_lan|sv_setsteamaccount|match_admin_password|sv_downloadurl)\b'
foreach ($f in @((Join-Path $csgo 'cfg\server.cfg'), (Join-Path $csgo 'cfg\autoexec.cfg'))) {
    if (-not (Test-Path $f)) { continue }
    $lines = @(Get-Content $f)
    $changed = $false
    $out = foreach ($l in $lines) {
        if ($l -match $owned) { $changed = $true; "// set by start_server.bat setup instead: $l" } else { $l }
    }
    if ($changed) {
        Set-Content -Path $f -Value $out
        Write-Host "  Moved server name/password/LAN lines out of $(Split-Path $f -Leaf)" -ForegroundColor DarkGray
    }
}

# ---- Internet: firewall rule for the game port ----
if ($mode -eq 2) {
    $ruleName = "CSGO-server-$port"
    $null = netsh advfirewall firewall show rule name="$ruleName" 2>$null
    if ($LASTEXITCODE -ne 0) {
        Write-Host ''
        Write-Host "Opening UDP port $port in Windows Firewall (asks for admin)..."
        try {
            Start-Process -FilePath 'netsh' -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList "advfirewall firewall add rule name=`"$ruleName`" dir=in action=allow protocol=UDP localport=$port"
        } catch { Write-Host '  Skipped - add an inbound UDP rule for the port yourself.' -ForegroundColor Yellow }
    }
    $steamfix = Join-Path $csgo 'addons\sourcemod\extensions\csgo_steamfix.ext.dll'
    Write-Host ''
    Write-Host 'Internet checklist:' -ForegroundColor Cyan
    Write-Host "  - On your router, forward UDP $port (game) and TCP 27020 (map downloads) to this PC."
    Write-Host "    Don't forward TCP $port - that's RCON."
    if (-not (Test-Path $steamfix)) {
        Write-Host '  - CS:GO Legacy players may be refused by Steam ticket checks without the'
        Write-Host '    optional CS:GO SteamFix extension - see README_server_pack.txt, "Internet".'
    }
}

Write-Host ''
Write-Host 'Saved.' -ForegroundColor Green
Write-Host "  Server name:  $hostname"
Write-Host "  Join with:    $(if ($joinPass) { "password $joinPass; connect <server IP>:$port" } else { "connect <server IP>:$port" })"
Write-Host "  Admin:        $(if ($adminPass) { "/login $adminPass  (in game chat)" } else { '/login is off' })"
Write-Host "  Network:      $(if ($mode -eq 1) { 'LAN / virtual LAN' } else { 'Internet' })"
Write-Host "  Starts in:    $($gm[0]) on $map"
Write-Host "  Map downloads: http://${dlIp}:27020/"
Write-Host ''
Write-Host 'Change these any time with:  start_server.bat setup'
Write-Host ''
