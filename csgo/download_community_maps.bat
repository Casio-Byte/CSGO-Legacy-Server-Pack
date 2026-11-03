@echo off
setlocal
title Download community maps (1v1 / Multi-1v1 arenas)

rem ------------------------------------------------------------------
rem  Downloads the 1v1 and Multi-1v1 arena maps listed in
rem      maps\modes\1v1\downloads.txt
rem      maps\modes\arena\downloads.txt
rem  from varq.net or the Steam Workshop and puts each .bsp into its
rem  mode folder. Edit those downloads.txt files to change what it gets.
rem
rem  Put this file in your server's "csgo" folder and double-click it.
rem  Maps you already have are skipped, so it's safe to run again.
rem  start_server.bat runs it automatically ("auto" mode: no key presses).
rem ------------------------------------------------------------------

set "CSGO_DIR=%~dp0"
set "BATCH_SELF=%~f0"
set "AUTO="
if /i "%~1"=="auto" set "AUTO=1"
if not exist "%CSGO_DIR%maps" (
    echo.
    echo Could not find a "maps" folder next to this file.
    echo Move download_community_maps.bat into your server's csgo folder and run it again.
    echo.
    if not defined AUTO pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -Command "$f=[IO.File]::ReadAllText($env:BATCH_SELF); iex ($f.Substring($f.LastIndexOf('#POWERSHELL#') + 12))"
if defined AUTO exit /b 0
echo.
pause
exit /b 0

#POWERSHELL#
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 } catch {}

$csgo  = $env:CSGO_DIR.TrimEnd('\')
$temp  = Join-Path $csgo '_map_downloads'
$modes = @('arena', '1v1')
$ua    = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0 Safari/537.36'
$curl  = (Get-Command curl.exe -ErrorAction SilentlyContinue).Source
$sevenZip = @("$env:ProgramFiles\7-Zip\7z.exe", "${env:ProgramFiles(x86)}\7-Zip\7z.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1

New-Item -ItemType Directory -Force -Path $temp | Out-Null
$failed = New-Object System.Collections.ArrayList
$added  = New-Object System.Collections.ArrayList

function Get-Page([string]$url) {
    try {
        return (Invoke-WebRequest -Uri $url -UserAgent $ua -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop).Content
    } catch { return $null }
}

function Get-File([string]$url, [string]$out, [string]$referer) {
    if (Test-Path $out) { Remove-Item $out -Force }
    if ($curl) {
        & $curl -s -L --fail -A $ua -e $referer -o $out $url
        return ($LASTEXITCODE -eq 0 -and (Test-Path $out))
    }
    try {
        Invoke-WebRequest -Uri $url -OutFile $out -UserAgent $ua -Headers @{ Referer = $referer } -UseBasicParsing -TimeoutSec 600 -ErrorAction Stop
        return (Test-Path $out)
    } catch { return $false }
}

function Get-Kind([string]$file) {
    $b = New-Object byte[] 6
    $fs = [IO.File]::OpenRead($file); [void]$fs.Read($b, 0, 6); $fs.Close()
    $s = [Text.Encoding]::ASCII.GetString($b)
    if ($s.StartsWith('Rar!')) { return 'rar' }
    if ($s.StartsWith('PK'))   { return 'zip' }
    if ($s.StartsWith('BZh'))  { return 'bz2' }
    if ($s.StartsWith('VBSP')) { return 'bsp' }
    if ($b[0] -eq 0x37 -and $b[1] -eq 0x7A -and $b[2] -eq 0xBC -and $b[3] -eq 0xAF) { return '7z' }
    if ($b[0] -eq 0x34 -and $b[1] -eq 0x12 -and $b[2] -eq 0xAA -and $b[3] -eq 0x55) { return 'vpk' }
    if ($s.StartsWith('<'))    { return 'html' }
    return 'unknown'
}

# Steam Workshop: Steam's public file API gives a direct download link for
# Workshop items (no login needed).
function Get-WorkshopFile([string]$id) {
    try {
        $r = Invoke-RestMethod -Method Post -Uri 'https://api.steampowered.com/ISteamRemoteStorage/GetPublishedFileDetails/v1/' `
             -Body @{ 'itemcount' = '1'; 'publishedfileids[0]' = $id } -TimeoutSec 30 -ErrorAction Stop
        $d = @($r.response.publishedfiledetails)[0]
        if ($null -eq $d -or $d.result -ne 1 -or [string]::IsNullOrEmpty($d.file_url)) { return $null }
        return @{ Url = $d.file_url; Name = $d.filename; Title = $d.title }
    } catch { return $null }
}

function Expand-Download([string]$file, [string]$kind, [string]$dest) {
    New-Item -ItemType Directory -Force -Path $dest | Out-Null
    if ($sevenZip) {
        & $sevenZip x -y "-o$dest" $file | Out-Null
        if ($kind -eq 'bz2') {
            # .bsp.bz2 unpacks to a single file without the .bsp extension sometimes
            Get-ChildItem $dest -File | Where-Object { $_.Extension -eq '' } | ForEach-Object { Rename-Item $_.FullName ($_.Name + '.bsp') }
        }
        return $true
    }
    switch ($kind) {
        'zip' { try { Expand-Archive -Path $file -DestinationPath $dest -Force -ErrorAction Stop; return $true } catch { return $false } }
        'rar' { & tar.exe -xf $file -C $dest 2>$null; return ($LASTEXITCODE -eq 0) }
        '7z'  { & tar.exe -xf $file -C $dest 2>$null; return ($LASTEXITCODE -eq 0) }
        default { return $false }
    }
}

Write-Host ''
Write-Host 'Downloading community maps into' (Join-Path $csgo 'maps\modes') -ForegroundColor Cyan
if (-not $sevenZip) { Write-Host '(7-Zip not found - using Windows'' built-in unpacking. Installing 7-Zip makes this more reliable.)' -ForegroundColor DarkGray }
Write-Host ''

# Built-in standard maps (map name, varq.net page name) - used when a mode
# folder has no downloads.txt yet, e.g. on a server set up with an older pack.
$defaults = @{
    # Multi-1v1 arena maps (Steam Workshop, original CS:GO uploads)
    'arena' = @(
        @('am_must2', 'workshop:279708083'), @('am_dust2', 'workshop:280544066'),
        @('am_texture2', 'workshop:279705991'), @('am_aztec2', 'workshop:279177142'),
        @('am_grass2', 'workshop:279697343'), @('am_warehouse2', 'workshop:279702034'),
        @('am_water', 'workshop:256601025'), @('am_trainyard', 'workshop:298621139'),
        @('am_skybound', 'workshop:303440740'), @('am_crashz_dust', 'workshop:302869851'),
        @('am_inferno_banana_dolnma', 'workshop:515898943'))
    # 1v1 match aim maps (Steam Workshop)
    '1v1' = @(
        @('aim_redline', 'workshop:125995702'), @('aim_map', 'workshop:122443683'),
        @('aim_map_pro', 'workshop:701833987'), @('awp_lego_2', 'workshop:534427561'),
        @('aim_pillars', 'workshop:405447392'), @('awp_india_csgo', 'workshop:391889933'),
        @('aim_biove_texture', 'workshop:535541366'), @('aim_crashz_dust_1on1', 'workshop:305726849'),
        @('aim_map_usp_s', 'workshop:270124159'), @('aim_dust_go', 'workshop:127178068'))
}
# Earlier packs' default lists - replaced automatically (edited lists are left alone).
$oldDefaults = @{
    'arena' = @('am_dust2 am_redline am_trainyard', 'am_inferno_banana_dolnma am_walterv2')
    '1v1'   = @('de_shortdust de_lake de_shortnuke gd_rialto')
}
$oldDownloads = @{
    'arena' = @('am_inferno_banana_dolnma am_inferno_banana-1v1-arena am_walterv2')
}

function Update-Lists([string]$mode, [string]$folder) {
    $dl = Join-Path $folder 'downloads.txt'
    $ml = Join-Path $folder 'maplist.txt'
    $maps = $defaults[$mode]

    # maplist.txt: swap the old default list for the new one
    $current = @()
    if (Test-Path $ml) {
        $current = Get-Content $ml | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('//') }
    }
    if (-not (Test-Path $ml) -or (@($oldDefaults[$mode]) -contains ($current -join ' '))) {
        $lines = @('// Standard maps - one map name per line.',
                   '// Installed maps are listed at the top of the !gamemode map menu;',
                   '// missing ones are shown greyed out as (not installed).',
                   '// Edit freely. Lines starting with // are ignored.') + ($maps | ForEach-Object { $_[0] })
        Set-Content -Path $ml -Value $lines
        Write-Host "  [list]   $mode\maplist.txt updated" -ForegroundColor DarkGray
    }

    # downloads.txt: replace an older pack's default list
    if ((Test-Path $dl) -and $oldDownloads.ContainsKey($mode)) {
        $cur = (Get-Content $dl | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('//') }) -join ' '
        $cur = ($cur -replace '\s+', ' ')
        if (@($oldDownloads[$mode]) -contains $cur) {
            Remove-Item $dl -Force
            Write-Host "  [list]   $mode\downloads.txt updated (Workshop maps)" -ForegroundColor DarkGray
        }
    }

    # downloads.txt: create it if missing
    if (-not (Test-Path $dl)) {
        $lines = @('// Used by download_community_maps.bat - one map per line:',
                   '//     <map name>  <varq.net page name>',
                   '// The page name is the last part of the map''s varq.net address.',
                   '// Leave it out if it''s the same as the map name.',
                   '// Only maps whose varq.net page has a download file will work.') +
                 ($maps | ForEach-Object { if ($_[0] -eq $_[1]) { $_[0] } else { "$($_[0])  $($_[1])" } })
        Set-Content -Path $dl -Value $lines
        Write-Host "  [list]   $mode\downloads.txt created" -ForegroundColor DarkGray
    }
}

foreach ($mode in $modes) {
    $folder = Join-Path $csgo "maps\modes\$mode"
    New-Item -ItemType Directory -Force -Path $folder | Out-Null
    Update-Lists $mode $folder
    $list   = Join-Path $folder 'downloads.txt'
    if (-not (Test-Path $list)) { $list = Join-Path $folder 'maplist.txt' }
    if (-not (Test-Path $list)) { continue }
    New-Item -ItemType Directory -Force -Path $folder | Out-Null

    # Each line: <map name> [varq.net page name]
    $entries = Get-Content $list | ForEach-Object { $_.Trim() } | Where-Object { $_ -and -not $_.StartsWith('//') }

    foreach ($entry in $entries) {
        $parts = $entry -split '\s+'
        $map   = $parts[0] -replace '\.bsp$', ''
        $page  = if ($parts.Count -gt 1) { $parts[1] } else { $map }

        $target = Join-Path $folder "$map.bsp"
        $inWorkshop = @(Get-ChildItem -Path (Join-Path $csgo 'maps\workshop') -Filter "$map.bsp" -Recurse -ErrorAction SilentlyContinue).Count -gt 0
        if ((Test-Path $target) -or (Test-Path (Join-Path $csgo "maps\$map.bsp")) -or $inWorkshop) {
            Write-Host "  [have]   $mode\$map" -ForegroundColor DarkGray
            continue
        }
        Write-Host "  [get]    $mode\$map ... " -NoNewline

        # Find the map's page and its download link.
        $pageUrl = $null; $dlUrl = $null
        if ($page -match '^workshop:(\d+)$') {
            # Steam Workshop item
            $wid = $matches[1]
            $pageUrl = "https://steamcommunity.com/sharedfiles/filedetails/?id=$wid"
            $w = Get-WorkshopFile $wid
            if (-not $w) {
                Write-Host 'no download from the Workshop' -ForegroundColor Yellow
                [void]$failed.Add("$mode\$map  (Steam gave no download for Workshop item $wid - subscribe to it in CS:GO Legacy, start the game once, then copy csgo\maps\workshop\$wid\$map.bsp into maps\modes\$mode\)")
                continue
            }
            $dlUrl = $w.Url
        }
        $slugs = @($page, $map, ($map -replace '_', '-')) | Select-Object -Unique
        if ($dlUrl) { $slugs = @() }
        foreach ($game in @('counter-strike-go', 'counter-strike-2')) {
            if ($dlUrl) { break }
            foreach ($slug in $slugs) {
                $u = "https://varq.net/en/maps/$game/$slug"
                $html = Get-Page $u
                if (-not $html) { continue }
                $m = [regex]::Match($html, 'href="([^"]*\?download=[0-9A-Za-z]+)"')
                if ($m.Success) {
                    $pageUrl = $u
                    $href = [Net.WebUtility]::HtmlDecode($m.Groups[1].Value)
                    $dlUrl = ([Uri]::new([Uri]$u, $href)).AbsoluteUri
                    break
                }
            }
            if ($dlUrl) { break }
        }
        if (-not $dlUrl) {
            Write-Host 'not found on varq.net' -ForegroundColor Yellow
            [void]$failed.Add("$mode\$map  (no download file on varq.net - find a CS:GO version elsewhere, e.g. GameBanana)")
            continue
        }

        $archive = Join-Path $temp "$map.download"
        if (-not (Get-File $dlUrl $archive $pageUrl)) {
            Write-Host 'download failed' -ForegroundColor Yellow
            [void]$failed.Add("$mode\$map  (download failed - get it from $pageUrl)")
            continue
        }

        $kind = Get-Kind $archive
        if ($kind -eq 'vpk') {
            Write-Host 'only a CS2 version' -ForegroundColor Yellow
            [void]$failed.Add("$mode\$map  (the download is a CS2 map (.vpk), which CS:GO can't load - get the CS:GO .bsp, e.g. from your own csgo\maps\workshop folder)")
            continue
        }
        if ($kind -eq 'html') {
            Write-Host 'site blocked the download' -ForegroundColor Yellow
            [void]$failed.Add("$mode\$map  (site asked for a browser - get it from $pageUrl)")
            continue
        }

        $out = Join-Path $temp $map
        if (Test-Path $out) { Remove-Item $out -Recurse -Force }
        if ($kind -eq 'bsp') {
            New-Item -ItemType Directory -Force -Path $out | Out-Null
            Copy-Item $archive (Join-Path $out "$map.bsp")
        }
        elseif (-not (Expand-Download $archive $kind $out)) {
            Write-Host "couldn't unpack ($kind)" -ForegroundColor Yellow
            [void]$failed.Add("$mode\$map  (couldn't unpack the $kind file - install 7-Zip and run this again, or get it from $pageUrl)")
            continue
        }

        $bsp = Get-ChildItem $out -Recurse -Filter '*.bsp' | Sort-Object Length -Descending | Select-Object -First 1
        if (-not $bsp) {
            Write-Host 'no .bsp inside' -ForegroundColor Yellow
            [void]$failed.Add("$mode\$map  (no .bsp in the download - get it from $pageUrl)")
            continue
        }

        # Keep the map's real file name - the map won't load if it's renamed.
        $real = $bsp.BaseName
        Copy-Item $bsp.FullName (Join-Path $folder "$real.bsp") -Force
        $nav = Get-ChildItem $out -Recurse -Filter "$real.nav" | Select-Object -First 1
        if ($nav) { Copy-Item $nav.FullName (Join-Path $folder "$real.nav") -Force }

        # If the real name differs, update the lists so the menu and re-runs match.
        if ($real -ne $map) {
            $pattern = '^\s*' + [regex]::Escape($map) + '(\s|$)'
            $ml = Join-Path $folder 'maplist.txt'
            if (Test-Path $ml) {
                Set-Content -Path $ml -Value (Get-Content $ml | ForEach-Object { if ($_ -match $pattern) { $real } else { $_ } })
            }
            $dl = Join-Path $folder 'downloads.txt'
            if (Test-Path $dl) {
                Set-Content -Path $dl -Value (Get-Content $dl | ForEach-Object { if ($_ -match $pattern) { "$real  $page" } else { $_ } })
            }
            $map = $real
        }

        # Extra content folders that some maps ship with.
        foreach ($extra in @('materials', 'models', 'sound', 'particles', 'resource')) {
            $src = Get-ChildItem $out -Recurse -Directory -Filter $extra | Select-Object -First 1
            if ($src) {
                $dst = Join-Path $csgo $extra
                New-Item -ItemType Directory -Force -Path $dst | Out-Null
                Copy-Item (Join-Path $src.FullName '*') $dst -Recurse -Force -ErrorAction SilentlyContinue
            }
        }

        $mb = [math]::Round($bsp.Length / 1MB, 1)
        Write-Host "ok ($mb MB)" -ForegroundColor Green
        [void]$added.Add("$mode\$map")
    }
}

Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ''
Write-Host "Added $($added.Count) map(s)." -ForegroundColor Cyan
if ($failed.Count -gt 0) {
    Write-Host ''
    Write-Host "Couldn't get $($failed.Count) map(s):" -ForegroundColor Yellow
    $failed | ForEach-Object { Write-Host "  - $_" }
    Write-Host ''
    Write-Host 'Download those by hand and put the .bsp in the mode''s folder (maps\modes\<mode>\).'
}
Write-Host ''
Write-Host 'No restart needed - the maps show up the next time you open !gamemode.'
