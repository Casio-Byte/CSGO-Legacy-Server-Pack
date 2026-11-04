@echo off
setlocal
title CS:GO server pack - uninstall

rem ==================================================================
rem  Removes everything the server pack added, so the server is back to
rem  plain CS:GO (no Metamod, no SourceMod, no plugins, no launcher).
rem
rem  Put it in your server's csgo folder (next to addons, cfg, maps) and
rem  double-click it. It shows what it will remove and asks first.
rem  By default everything is MOVED to a backup folder, so you can put it
rem  back - choose "delete" to remove it for good.
rem
rem  Not touched: the game itself, steam.inf, mapcycle.txt, maplist.txt,
rem  your official maps, and anything else CS:GO installed.
rem
rem  Option: keep start_server.bat (and FastDL / the map downloader) so you can
rem  still start the server the same way, just without Metamod/SourceMod and
rem  the plugins. Your server name, passwords and LAN/internet setting keep
rem  working (server.cfg loads them).
rem ==================================================================

set "CSGO_DIR=%~dp0"
set "BATCH_SELF=%~f0"

if not exist "%CSGO_DIR%maps" (
    echo.
    echo Could not find a "maps" folder next to this file.
    echo Put uninstall_server_pack.bat in your server's csgo folder and run it again.
    echo.
    pause
    exit /b 1
)

tasklist /FI "IMAGENAME eq srcds.exe" 2>nul | find /i "srcds.exe" >nul
if not errorlevel 1 (
    echo.
    echo The CS:GO server is still running. Close it first, then run this again.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$f=[IO.File]::ReadAllText($env:BATCH_SELF); iex ($f.Substring($f.LastIndexOf('#POWERSHELL#') + 12))"
set "RESULT=%ERRORLEVEL%"
echo.
pause
if "%RESULT%"=="9" (
    rem Remove this file too (after the window's pause).
    (goto) 2>nul & del "%~f0"
)
exit /b 0

#POWERSHELL#
$ErrorActionPreference = 'Continue'
$csgo = $env:CSGO_DIR.TrimEnd('\', '/')

# Everything the pack (and its launcher/plugins) adds. Paths are relative to csgo\.
$items = @(
    @('addons\metamod',                     'Metamod:Source'),
    @('addons\sourcemod',                   'SourceMod, all plugins, extensions, player loadouts and logs'),
    @('addons\metamod.vdf',                 'Metamod loader'),
    @('addons\metamod_x64.vdf',             'Metamod 64-bit loader (old)'),
    @('cfg\sourcemod',                      'SourceMod settings'),
    @('cfg\csgo_match',                     'match/mode configs, server name, passwords, FastDL address'),
    @('cfg\server.cfg',                     'server.cfg from the pack'),
    @('cfg\setup.cfg',                      'ESL setup config'),
    @('cfg\solo.cfg',                       'solo/test config'),
    @('cfg\s.cfg',                          'game mode placeholder config'),
    @('cfg\server_last.cfg',                'game mode placeholder config'),
    @('cfg\esl1on1.cfg', ''), @('cfg\esl1on1aml.cfg', ''), @('cfg\esl1on1awp.cfg', ''), @('cfg\esl1on1usp.cfg', ''),
    @('cfg\esl2on2.cfg', ''), @('cfg\esl2on2aml.cfg', ''), @('cfg\esl2on2awp.cfg', ''), @('cfg\esl5on5.cfg', 'ESL rule configs'),
    @('GameModes_Server.txt',               'custom game modes / map groups'),
    @('materials\decals\eitems',            'spray images (eSprays)'),
    @('start_server.bat',                   'launcher'),
    @('start_fastdl.bat',                   'FastDL map server'),
    @('download_community_maps.bat',        'map downloader'),
    @('launcher_settings.cmd',              'launcher settings + login token'),
    @('README_server_pack.txt',             'pack manual')
)
$maps = @('maps\modes', 'map folders per game mode, incl. downloaded community maps')

# Copies of mode-folder maps that start_server.bat put into csgo\maps
$copyLog = Join-Path $csgo 'maps\modes\copied_to_maps.txt'
if (Test-Path $copyLog) {
    $copied = @(Get-Content $copyLog | Where-Object { $_ -match '^[^\\/:*?"<>|]+\.(bsp|nav)$' })
    foreach ($c in $copied) { $items += ,@("maps\$c", '') }
    if ($copied.Count) { $items[-1] = @($items[-1][0], 'copies of the mode-folder maps in csgo\maps') }
}

$found = New-Object System.Collections.ArrayList
foreach ($i in $items) {
    if (Test-Path (Join-Path $csgo $i[0])) { [void]$found.Add($i) }
}
$hasMaps = Test-Path (Join-Path $csgo $maps[0])

Write-Host ''
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host '  Uninstall the CS:GO server pack' -ForegroundColor Cyan
Write-Host '=============================================' -ForegroundColor Cyan
Write-Host "Server folder: $csgo"
Write-Host ''
if ($found.Count -eq 0 -and -not $hasMaps) {
    Write-Host 'Nothing from the pack was found - the server is already plain CS:GO.' -ForegroundColor Green
    exit 0
}
Write-Host 'This will remove:'
foreach ($i in $found) {
    if ($i[1]) { Write-Host ("  {0,-34} {1}" -f $i[0], $i[1]) } else { Write-Host ("  {0}" -f $i[0]) }
}
if ($hasMaps) {
    $n = @(Get-ChildItem (Join-Path $csgo $maps[0]) -Recurse -Filter '*.bsp' -ErrorAction SilentlyContinue).Count
    Write-Host ''
    Write-Host ("  {0,-34} {1} ({2} .bsp maps) - you choose below" -f $maps[0], $maps[1], $n)
}
Write-Host ''
Write-Host 'Kept: the game, steam.inf, mapcycle.txt, maplist.txt, official maps.' -ForegroundColor DarkGray
Write-Host ''

# Community maps: keep by default.
$removeMaps = $false
if ($hasMaps) {
    $a = Read-Host 'Also remove the community maps in maps\modes? (Y/N) [N]'
    $removeMaps = ($a -match '^[Yy]')
}

# Keep the launcher (start_server.bat) so the server still starts the same way, without plugins.
$keepLauncher = $false
if (Test-Path (Join-Path $csgo 'start_server.bat')) {
    Write-Host ''
    Write-Host 'Keep start_server.bat so you can still start the server with it (same name,'
    Write-Host 'passwords and LAN/internet setting, FastDL and the map downloader) - just'
    $a = Read-Host 'without Metamod, SourceMod and the plugins? (Y/N) [N]'
    $keepLauncher = ($a -match '^[Yy]')
}
$keepFiles = @('start_server.bat', 'start_fastdl.bat', 'download_community_maps.bat', 'launcher_settings.cmd',
               'cfg\server.cfg', 'cfg\csgo_match\server_settings.cfg', 'cfg\csgo_match\fastdl.cfg')
if ($keepLauncher) {
    # Remove cfg\csgo_match file by file, keeping the launcher's two settings files.
    $expanded = New-Object System.Collections.ArrayList
    foreach ($i in $found) {
        if ($i[0] -eq 'cfg\csgo_match') {
            Get-ChildItem (Join-Path $csgo 'cfg\csgo_match') -File -ErrorAction SilentlyContinue | ForEach-Object {
                [void]$expanded.Add(@("cfg\csgo_match\$($_.Name)", ''))
            }
        } else { [void]$expanded.Add($i) }
    }
    $found = @($expanded | Where-Object { $keepFiles -notcontains $_[0] })
    Write-Host '  Keeping: start_server.bat, start_fastdl.bat, download_community_maps.bat,' -ForegroundColor DarkGray
    Write-Host '           launcher_settings.cmd, cfg\server.cfg and your server settings.' -ForegroundColor DarkGray
}

Write-Host ''
Write-Host '  B = move everything to a backup folder (can be put back)  [default]'
Write-Host '  D = delete permanently'
Write-Host '  C = cancel'
$how = Read-Host 'Choose B, D or C [B]'
if ($how -match '^[Cc]') { Write-Host 'Cancelled - nothing was changed.'; exit 0 }
$delete = ($how -match '^[Dd]')

if ($delete) {
    $confirm = Read-Host 'Type DELETE to permanently remove these files'
    if ($confirm -cne 'DELETE') { Write-Host 'Cancelled - nothing was changed.'; exit 0 }
}

$list = @($found | ForEach-Object { $_[0] })
if ($removeMaps) { $list += $maps[0] }

$backup = $null
if (-not $delete) {
    $backup = Join-Path $csgo ('_server_pack_backup_' + (Get-Date -Format 'yyyyMMdd_HHmmss'))
    New-Item -ItemType Directory -Force -Path $backup | Out-Null
}

$failed = 0
foreach ($rel in $list) {
    $src = Join-Path $csgo $rel
    try {
        if ($delete) {
            Remove-Item -LiteralPath $src -Recurse -Force -ErrorAction Stop
        } else {
            $dst = Join-Path $backup $rel
            New-Item -ItemType Directory -Force -Path (Split-Path $dst -Parent) | Out-Null
            Move-Item -LiteralPath $src -Destination $dst -Force -ErrorAction Stop
        }
        Write-Host "  removed  $rel" -ForegroundColor DarkGray
    } catch {
        $failed++
        Write-Host "  FAILED   $rel  ($($_.Exception.Message))" -ForegroundColor Yellow
    }
}

# Empty folders the pack created.
foreach ($d in @('materials\decals', 'addons')) {
    $p = Join-Path $csgo $d
    if ((Test-Path $p) -and -not (Get-ChildItem $p -Force -ErrorAction SilentlyContinue)) { Remove-Item $p -Force -ErrorAction SilentlyContinue }
}

# Without the plugins nothing loads the launcher's settings any more, so
# server.cfg loads them (server name, passwords, LAN/internet, FastDL address).
if ($keepLauncher) {
    $cfgFile = Join-Path $csgo 'cfg\server.cfg'
    $lines = @()
    if (Test-Path $cfgFile) { $lines = @(Get-Content $cfgFile) }
    $add = @()
    if (-not ($lines -match '^\s*exec\s+csgo_match/server_settings')) { $add += 'exec csgo_match/server_settings.cfg' }
    if (-not ($lines -match '^\s*exec\s+csgo_match/fastdl'))          { $add += 'exec csgo_match/fastdl.cfg' }
    if ($add.Count -gt 0) {
        $lines += ''
        $lines += '// Added by uninstall_server_pack.bat: the launcher''s settings (no plugins load them now)'
        $lines += $add
        Set-Content -Path $cfgFile -Value $lines
        Write-Host '  server.cfg now loads your server settings' -ForegroundColor DarkGray
    }
}

# Windows firewall rules / port permission added by FastDL and the setup.
$rules = @(netsh advfirewall firewall show rule name=all 2>$null | Select-String -Pattern '^Rule Name:\s+(CS:GO FastDL|CSGO-server-\d+)\s*$' | ForEach-Object { $_.Matches[0].Groups[1].Value }) | Select-Object -Unique
$acl = [bool](netsh http show urlacl url=http://+:27020/ 2>$null | Select-String ':27020/')
if (($rules.Count -gt 0 -or $acl) -and -not $keepLauncher) {
    Write-Host ''
    $a = Read-Host 'Also remove the Windows Firewall rules and port permission the pack added? (asks for admin) (Y/N) [Y]'
    if (-not ($a -match '^[Nn]')) {
        $cmds = @()
        foreach ($r in $rules) { $cmds += "netsh advfirewall firewall delete rule name=`"$r`"" }
        if ($acl) { $cmds += 'netsh http delete urlacl url=http://+:27020/' }
        try {
            Start-Process -FilePath 'cmd.exe' -Verb RunAs -Wait -WindowStyle Hidden -ArgumentList ('/c ' + ($cmds -join ' & '))
            Write-Host '  firewall rules removed' -ForegroundColor DarkGray
        } catch { Write-Host '  skipped (no admin) - remove "CS:GO FastDL" / "CSGO-server-..." in Windows Firewall yourself.' -ForegroundColor Yellow }
    }
}

Write-Host ''
if ($failed -gt 0) {
    Write-Host "$failed item(s) couldn't be removed - is the server or FastDL still running? Close them and run this again." -ForegroundColor Yellow
    exit 1
}
if ($delete) {
    Write-Host 'Done - the server pack is removed.' -ForegroundColor Green
} else {
    Write-Host 'Done - the server pack is removed. Everything is in:' -ForegroundColor Green
    Write-Host "  $backup"
    Write-Host 'To undo: move the contents of that folder back into csgo. Delete the folder when you no longer need it.'
}
if ($keepLauncher) {
    Write-Host 'Start the server with start_server.bat as before - it now runs plain CS:GO.'
    Write-Host 'Run uninstall_server_pack.bat again (and answer N to keeping the launcher) to remove it too.'
    Write-Host ''
    exit 0
}
Write-Host 'Start the server with your own launch line now (srcds.exe -game csgo ...).'
Write-Host ''
exit 9
