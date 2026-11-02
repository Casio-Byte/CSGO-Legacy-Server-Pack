@echo off
setlocal
title CS:GO FastDL (map downloads for players)

rem ------------------------------------------------------------------
rem  FastDL: lets players download maps from this PC quickly, instead of
rem  CS:GO's very slow built-in download.
rem
rem  Put this file in your server's "csgo" folder and run it whenever the
rem  server is running (leave the window open). The first time it asks
rem  for admin rights to open port 27020 in Windows Firewall.
rem
rem  It writes cfg\csgo_match\fastdl.cfg, which the match plugin loads
rem  every map to tell players where to download from.
rem
rem  Only map/content files are shared (maps, materials, models, sound,
rem  particles, resource) - nothing else on this PC.
rem ------------------------------------------------------------------

set "CSGO_DIR=%~dp0"
set "BATCH_SELF=%~f0"
set "FASTDL_PORT=27020"
set "BG="
if /i "%~1"=="background" set "BG=1"

if not exist "%CSGO_DIR%maps" (
    echo.
    echo Could not find a "maps" folder next to this file.
    echo Move start_fastdl.bat into your server's csgo folder and run it again.
    echo.
    pause
    exit /b 1
)

rem One-time setup (needs admin): firewall rule + permission to use the port.
rem After that it runs without admin, so it can start with the server.
set "NEEDSETUP="
netsh http show urlacl url=http://+:%FASTDL_PORT%/ | find /i ":%FASTDL_PORT%/" >nul || set "NEEDSETUP=1"
netsh advfirewall firewall show rule name="CS:GO FastDL" >nul 2>&1 || set "NEEDSETUP=1"
if not defined NEEDSETUP goto :run

net session >nul 2>&1
if errorlevel 1 (
    echo First-time setup needs admin rights - asking now...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -ArgumentList '%~1' -Verb RunAs"
    exit /b 0
)
netsh http delete urlacl url=http://+:%FASTDL_PORT%/ >nul 2>&1
netsh http add urlacl url=http://+:%FASTDL_PORT%/ sddl=D:(A;;GX;;;WD) >nul
netsh advfirewall firewall delete rule name="CS:GO FastDL" >nul 2>&1
netsh advfirewall firewall add rule name="CS:GO FastDL" dir=in action=allow protocol=TCP localport=%FASTDL_PORT% >nul
echo Firewall and port permission set up.

:run

powershell -NoProfile -ExecutionPolicy Bypass -Command "$f=[IO.File]::ReadAllText($env:BATCH_SELF); iex ($f.Substring($f.LastIndexOf('#POWERSHELL#') + 12))"
if defined BG exit /b 0
echo.
pause
exit /b 0

#POWERSHELL#
$ErrorActionPreference = 'Continue'
$root = [IO.Path]::GetFullPath($env:CSGO_DIR.TrimEnd('\', '/'))
$port = [int]$env:FASTDL_PORT

# --- Work out the address players should use, and write fastdl.cfg ---
$ip = $null
try {
    $ip = Get-NetIPConfiguration -ErrorAction Stop |
          Where-Object { $_.IPv4DefaultGateway -and $_.NetAdapter.Status -eq 'Up' } |
          ForEach-Object { $_.IPv4Address.IPAddress } | Select-Object -First 1
} catch {}
if (-not $ip) {
    $ip = [Net.Dns]::GetHostAddresses([Net.Dns]::GetHostName()) |
          Where-Object { $_.AddressFamily -eq 'InterNetwork' -and -not $_.ToString().StartsWith('127.') -and -not $_.ToString().StartsWith('169.254.') } |
          ForEach-Object { $_.ToString() } | Select-Object -First 1
}

$cfgDir = Join-Path $root 'cfg\csgo_match'
$cfg = Join-Path $cfgDir 'fastdl.cfg'
New-Item -ItemType Directory -Force -Path $cfgDir | Out-Null
if (-not (Test-Path $cfg) -or -not (Select-String -Path $cfg -Pattern '^\s*sv_downloadurl' -Quiet)) {
    $url = "http://${ip}:$port/"
    Set-Content -Path $cfg -Value @(
        '// Written by start_fastdl.bat - loaded by the match plugin every map.',
        '// Players download missing maps from this address. Change the IP if',
        '// players connect another way (e.g. your public IP for friends over the',
        '// internet, or your Tailscale/ZeroTier IP for a virtual LAN).',
        'sv_allowdownload 1',
        "sv_downloadurl `"$url`""
    )
    Write-Host "Created cfg\csgo_match\fastdl.cfg" -ForegroundColor DarkGray
}
$current = (Select-String -Path $cfg -Pattern 'sv_downloadurl\s+"([^"]+)"' | Select-Object -First 1).Matches.Groups[1].Value

# --- Web server ---
$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://+:$port/")
try { $listener.Start() } catch {
    Write-Host ''
    Write-Host "Couldn't start on port $port : $($_.Exception.Message)" -ForegroundColor Red
    Write-Host 'Is another copy of start_fastdl.bat already running?'
    return
}

Write-Host ''
Write-Host "FastDL is running on port $port." -ForegroundColor Green
Write-Host "Players are sent to:  $current"
Write-Host "Sharing files from:   $root  (maps, materials, models, sound, particles, resource)"
Write-Host ''
Write-Host 'Leave this window open while the server runs. Restart the server (or change map)'
Write-Host 'once after the first run so it picks up fastdl.cfg.'
Write-Host 'Friends over the internet: forward TCP port 27020 on your router and put your'
Write-Host 'public IP in cfg\csgo_match\fastdl.cfg (or use your virtual-LAN IP).'
Write-Host ''

$handler = {
    param($ctx, $root)
    $res = $ctx.Response
    try {
        $rel = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath).TrimStart('/').Replace('/', '\')
        $first = ($rel -split '\\')[0].ToLowerInvariant()
        $ext = [IO.Path]::GetExtension($rel).ToLowerInvariant()
        $dirs = @('maps', 'materials', 'models', 'sound', 'particles', 'resource')
        $exts = @('.bsp', '.nav', '.bz2', '.vtf', '.vmt', '.mdl', '.vvd', '.vtx', '.phy', '.ani',
                  '.wav', '.mp3', '.pcf', '.res', '.png', '.jpg', '.txt', '.kv3', '.ain')

        $full = [IO.Path]::GetFullPath([IO.Path]::Combine($root, $rel))
        $inside = $full.StartsWith($root + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)

        if (-not $inside -or ($dirs -notcontains $first) -or ($exts -notcontains $ext) -or -not [IO.File]::Exists($full)) {
            $res.StatusCode = 404
        }
        else {
            $res.ContentType = 'application/octet-stream'
            $fs = [IO.File]::OpenRead($full)
            try {
                $res.ContentLength64 = $fs.Length
                $fs.CopyTo($res.OutputStream, 1048576)
            } finally { $fs.Dispose() }
        }
    } catch {
        try { $res.StatusCode = 500 } catch {}
    } finally {
        try { $res.Close() } catch {}
    }
}

$pool = [RunspaceFactory]::CreateRunspacePool(1, 8)
$pool.Open()
$jobs = New-Object System.Collections.ArrayList

while ($listener.IsListening) {
    $ctx = $listener.GetContext()
    $path = [Uri]::UnescapeDataString($ctx.Request.Url.AbsolutePath)
    if (-not $path.EndsWith('.bz2')) {
        Write-Host ("{0}  {1}  {2}" -f (Get-Date -Format 'HH:mm:ss'), $ctx.Request.RemoteEndPoint.Address, $path)
    }

    $ps = [PowerShell]::Create()
    $ps.RunspacePool = $pool
    [void]$ps.AddScript($handler).AddArgument($ctx).AddArgument($root)
    [void]$jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke() })

    # Tidy up finished transfers.
    for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
        if ($jobs[$i].Handle.IsCompleted) {
            try { $jobs[$i].PS.EndInvoke($jobs[$i].Handle) } catch {}
            $jobs[$i].PS.Dispose()
            $jobs.RemoveAt($i)
        }
    }
}
