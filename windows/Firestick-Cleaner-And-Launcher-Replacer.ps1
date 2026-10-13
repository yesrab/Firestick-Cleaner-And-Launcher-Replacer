# Firestick Cleanup - Windows console implementation (Windows PowerShell 5.1 or PowerShell 7).
#
# Entry point: double-click Firestick-Cleaner-And-Launcher-Replacer.bat, or run
#   powershell -NoProfile -ExecutionPolicy Bypass -File Firestick-Cleaner-And-Launcher-Replacer.ps1 [options]
#
# Package and launcher definitions live in ..\common\packages.conf and
# ..\common\launchers.conf and are shared with the Mac/Linux script and the
# WinForms app. Options mirror the shell script; run with --help to see them.

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 } catch { }

$Version       = '2.0.0'
$PlatformDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$CommonDir     = Join-Path (Split-Path -Parent $PlatformDir) 'common'
$PackagesConf  = Join-Path $CommonDir 'packages.conf'
$LaunchersConf = Join-Path $CommonDir 'launchers.conf'
$DownloadDir   = Join-Path $PlatformDir 'downloads'
$LastIpFile    = Join-Path $PlatformDir '.last_ip'
$DeviceTmp     = '/data/local/tmp'
# Folder your browser saves downloads to (override with the FSC_DOWNLOADS_DIR environment variable).
$DownloadsWatch = $env:FSC_DOWNLOADS_DIR
if (-not $DownloadsWatch) {
    try { $DownloadsWatch = (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders' -ErrorAction Stop).'{374DE290-123F-4565-9164-39C4925E467B}' } catch { }
    if (-not $DownloadsWatch) { $DownloadsWatch = Join-Path $env:USERPROFILE 'Downloads' }
}
# APKMirror serves app metadata (versions, variants, signing certs) to the open-source APKUpdater
# app through this endpoint; the key ships inside that app. APKMirror does not allow scripted
# file downloads, so the download itself happens in your browser.
$ApkMirrorApi  = 'https://www.apkmirror.com/wp-json/apkm/v1/app_exists/'
$ApkMirrorAuth = 'Basic YXBpLWFwa3VwZGF0ZXI6cm01cmNmcnVVakt5MDRzTXB5TVBKWFc4'
$LogFile       = Join-Path $PlatformDir ('firestick_cleanup_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
$EntryName     = 'Firestick-Cleaner-And-Launcher-Replacer.bat'

$Mode = 'install'; $FireIp = ''; $Port = 5555; $LauncherKey = ''
$AddonsWith = @(); $AddonsWithout = @(); $ChosenAddons = ''
$DisableGroups = ''; $NonInteractive = $false; $ADB = ''; $Target = ''; $StateFile = ''
$State = New-Object System.Collections.ArrayList
$TotalDisabled = 0; $TotalProtected = 0; $Passes = 0; $Reapplied = 0
$Dev = @{ Sdk = 0; Abis = ''; Release = ''; FireOs = ''; Model = '' }
$ExpectedVCode = ''

# ------------------------------------------------------------
# CLI
# ------------------------------------------------------------
function Show-Usage {
    Write-Host @"
Firestick Cleanup $Version - replace the Fire TV launcher and disable Amazon bloat.

Usage: $EntryName [options]

Modes (default: full install)
  --revert            Undo everything recorded for this device and restore stock
  --reapply           Re-disable packages using the saved choices (after a Fire OS update)
  --status            Show launcher, Home on Fire and disabled-package state; change nothing
  --dry-run           Show what would be done; change nothing
  --test-boot         Reboot the Fire TV and check the launcher and add-ons come up

Options
  --ip <ip[:port]>    Fire TV address (skips the prompt)
  --launcher <key>    projectivy | at4k | couchy   (default: projectivy)
  --with <a,b,..>     Add-ons: homeonfire, youtubetv, googleapp, smarttube (see common\launchers.conf)
  --without <a,b,..>  Add-ons to skip
  --home-on-fire      Same as --with homeonfire      --no-home-on-fire: --without homeonfire
  --disable <a,b,..>  Optional groups to disable, comma-separated (see common\packages.conf)
  -y, --non-interactive
                      Never prompt; requires --ip. Uses --launcher/--with/--disable,
                      or the saved choices for --reapply.
  -h, --help          This help

Examples
  $EntryName
  $EntryName --ip 10.0.0.20 --launcher couchy --with homeonfire,youtubetv --disable video,appstore -y
  $EntryName --ip 10.0.0.20 --reapply -y
  $EntryName --revert
"@
}

$argv = @($args)
for ($i = 0; $i -lt $argv.Count; $i++) {
    $a = [string]$argv[$i]
    switch -Regex ($a) {
        '^(--|-|/)revert$'          { $Mode = 'revert'; break }
        '^(--|-|/)reapply$'         { $Mode = 'reapply'; break }
        '^(--|-|/)status$'          { $Mode = 'status'; break }
        '^(--|-|/)dry-?run$'        { $Mode = 'dry-run'; break }
        '^(--|-|/)test-?boot$'      { $Mode = 'test-boot'; break }
        '^(--|-|/)ip$'              { $i++; $FireIp = [string]$argv[$i]; break }
        '^(--|-|/)ip=(.+)$'         { $FireIp = $Matches[2]; break }
        '^(--|-|/)launcher$'        { $i++; $LauncherKey = [string]$argv[$i]; break }
        '^(--|-|/)launcher=(.+)$'   { $LauncherKey = $Matches[2]; break }
        '^(--|-|/)with$'            { $i++; $AddonsWith += @([string]$argv[$i] -split ','); break }
        '^(--|-|/)with=(.+)$'       { $AddonsWith += @($Matches[2] -split ','); break }
        '^(--|-|/)without$'         { $i++; $AddonsWithout += @([string]$argv[$i] -split ','); break }
        '^(--|-|/)without=(.+)$'    { $AddonsWithout += @($Matches[2] -split ','); break }
        '^(--|-|/)home-?on-?fire$'  { $AddonsWith += 'homeonfire'; break }
        '^(--|-|/)no-?home-?on-?fire$' { $AddonsWithout += 'homeonfire'; break }
        '^(--|-|/)disable$'         { $i++; $DisableGroups = [string]$argv[$i]; break }
        '^(--|-|/)disable=(.+)$'    { $DisableGroups = $Matches[2]; break }
        '^(--|-|/)(y|non-?interactive)$' { $NonInteractive = $true; break }
        '^(--|-|/)(h|help|\?)$'     { Show-Usage; exit 0 }
        default                     { Write-Host "Unknown option: $a"; Show-Usage; exit 2 }
    }
}

# ------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------
function Write-Log($t) { Add-Content -Path $LogFile -Value $t -Encoding UTF8 }
function Say($t)  { Write-Host $t; Write-Log $t }
function Ok($t)   { Say "  [OK] $t" }
function Info($t) { Say "  [..] $t" }
function Warn($t) { Say "  [--] $t" }
function Err($t)  { Say "  [!!] $t" }
function Banner($t) { Say ''; Say '  ========================================'; Say "    $t"; Say '  ========================================' }

function Wait-Enter($msg = 'Press Enter to continue...') {
    if (-not $NonInteractive) { Read-Host "  $msg" | Out-Null }
}

function Die($t) {
    Err $t; Say ''; Say "  Log: $LogFile"
    Wait-Enter 'Press Enter to exit...'
    exit 1
}

# Ask-YesNo "Question?" 'y'|'n'  -> $true for yes
function Ask-YesNo($prompt, $default = 'n') {
    $hint = if ($default -eq 'y') { '[Y/n]' } else { '[y/N]' }
    if ($NonInteractive) { return ($default -eq 'y') }
    while ($true) {
        $r = Read-Host "  $prompt $hint"
        if ($r -eq '') { return ($default -eq 'y') }
        if ($r -match '^[Yy]') { return $true }
        if ($r -match '^[Nn]') { return $false }
    }
}

# ------------------------------------------------------------
# Config parsing (packages.conf / launchers.conf)
# ------------------------------------------------------------
function Get-Groups {
    $list = @()
    foreach ($line in Get-Content $PackagesConf) {
        if ($line -match '^\[([a-z0-9_-]+)\]\s*(.*)$') {
            $list += [pscustomobject]@{ Key = $Matches[1]; Prompt = $Matches[2] }
        }
    }
    return ,$list
}

function Get-GroupPackages($key) {
    $cur = ''; $pk = @()
    foreach ($line in Get-Content $PackagesConf) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        if ($line -match '^\[([^\]]+)\]') { $cur = $Matches[1]; continue }
        if ($cur -eq $key) {
            $p = ($line.Trim() -split '\s+')[0]
            if ($p -and -not $p.StartsWith('#')) { $pk += $p }
        }
    }
    return ,$pk
}

function Get-Conf($section, $key) {
    $cur = ''; $vals = @()
    foreach ($line in Get-Content $LaunchersConf) {
        if ($line -match '^\s*#' -or $line -match '^\s*$') { continue }
        if ($line -match '^\[([^\]]+)\]') { $cur = $Matches[1]; continue }
        if ($cur -eq $section -and $line.StartsWith("$key=")) { $vals += $line.Substring($key.Length + 1) }
    }
    return ,$vals
}

function Get-Conf1($section, $key) {
    $v = Get-Conf $section $key
    if ($v.Count -gt 0) { return $v[0] } else { return '' }
}

function Get-Sections {
    $s = @()
    foreach ($line in Get-Content $LaunchersConf) {
        if ($line -match '^\[([^\]]+)\]') { $s += $Matches[1] }
    }
    return ,$s
}

function Get-LauncherKeys {
    return ,@(Get-Sections | Where-Object { (Get-Conf1 $_ 'type') -eq 'launcher' })
}

function Get-AddonKeys {
    return ,@(Get-Sections | Where-Object { (Get-Conf1 $_ 'type') -eq 'addon' })
}

function Test-Group($key) {
    return @(Get-Groups | Where-Object { $_.Key -eq $key }).Count -gt 0
}

# ------------------------------------------------------------
# State file (what this tool changed on a given device)
# ------------------------------------------------------------
function Read-State {
    $script:State.Clear()
    if (Test-Path $StateFile) {
        foreach ($l in Get-Content $StateFile) { if ($l) { [void]$script:State.Add($l) } }
    }
}
function Save-State { Set-Content -Path $StateFile -Value $script:State -Encoding ASCII }
function Get-State($k)  { return ,@($script:State | Where-Object { $_.StartsWith("$k=") } | ForEach-Object { $_.Substring($k.Length + 1) }) }
function Get-State1($k) { $v = Get-State $k; if ($v.Count -gt 0) { return $v[0] } else { return '' } }
function Test-State($k) { return @($script:State | Where-Object { $_.StartsWith("$k=") }).Count -gt 0 }
function Set-State($k, $v) {
    $keep = @($script:State | Where-Object { -not $_.StartsWith("$k=") })
    $script:State.Clear(); $script:State.AddRange($keep); [void]$script:State.Add("$k=$v"); Save-State
}
function Add-State($k, $v) {
    if (-not ($script:State -contains "$k=$v")) { [void]$script:State.Add("$k=$v"); Save-State }
}

# ------------------------------------------------------------
# ADB discovery
# ------------------------------------------------------------
function Find-Adb {
    $bundled = Join-Path $PlatformDir 'adb\adb.exe'
    if (Test-Path $bundled) { $script:ADB = $bundled; return $true }
    $cmd = Get-Command adb.exe -ErrorAction SilentlyContinue
    if ($cmd) { $script:ADB = $cmd.Source; return $true }
    $url = 'https://dl.google.com/android/repository/platform-tools-latest-windows.zip'
    Say "  ADB was not found. It can be downloaded from Google ($url)."
    if (-not (Ask-YesNo 'Download platform-tools now?' 'y')) { return $false }
    $zip = Join-Path $PlatformDir 'platform-tools.zip'
    try { Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing } catch { Err "Download failed: $($_.Exception.Message)"; return $false }
    Expand-Archive -Path $zip -DestinationPath $PlatformDir -Force
    $dst = Join-Path $PlatformDir 'adb'
    New-Item -ItemType Directory -Force -Path $dst | Out-Null
    Copy-Item -Path (Join-Path $PlatformDir 'platform-tools\*') -Destination $dst -Recurse -Force
    Remove-Item -Path (Join-Path $PlatformDir 'platform-tools') -Recurse -Force
    Remove-Item -Path $zip -Force
    $script:ADB = $bundled
    return (Test-Path $bundled)
}

# ------------------------------------------------------------
# Device helpers
# ------------------------------------------------------------
function Invoke-Adb([string[]]$a) {
    $out = (& $script:ADB @a 2>&1 | ForEach-Object { $_.ToString() }) -join "`n"
    $out = $out -replace "`r", ''
    Write-Log "[adb $($a -join ' ')] => $out"
    return $out
}

function Invoke-Dsh([string[]]$a) { return Invoke-Adb (@('-s', $Target, 'shell') + $a) }

# Pushes a script to the device and runs it there (avoids command-length limits).
function Invoke-DeviceScript([string]$text) {
    $tmp = [IO.Path]::GetTempFileName()
    [IO.File]::WriteAllText($tmp, (($text -replace "`r`n", "`n") + "`n"), (New-Object System.Text.UTF8Encoding $false))
    Invoke-Adb @('-s', $Target, 'push', $tmp, "$DeviceTmp/fsc_script.sh") | Out-Null
    Remove-Item -Path $tmp -Force -ErrorAction SilentlyContinue
    Write-Log "[adb script] $text"
    $out = Invoke-Dsh @('sh', "$DeviceTmp/fsc_script.sh")
    Invoke-Dsh @('rm', '-f', "$DeviceTmp/fsc_script.sh") | Out-Null
    return $out
}

function Get-DeviceState {
    $out = Invoke-Adb @('devices')
    $esc = [regex]::Escape($Target)
    foreach ($l in ($out -split "`n")) { if ($l -match "^$esc\s+(\S+)") { return $Matches[1] } }
    return ''
}

function Wait-ForDevice($timeout = 120) {
    $sw = [Diagnostics.Stopwatch]::StartNew(); $hinted = $false
    while ($sw.Elapsed.TotalSeconds -lt $timeout) {
        Invoke-Adb @('connect', $Target) | Out-Null
        $st = Get-DeviceState
        if ($st -eq 'device') {
            if ((Invoke-Dsh @('echo', 'fsc_ok')) -match 'fsc_ok') { return $true }
        } elseif ($st -eq 'unauthorized' -and -not $hinted) {
            Say ''; Say "  Look at your TV: select 'Always allow from this computer' and press OK."; $hinted = $true
        }
        Start-Sleep -Seconds 2
    }
    return $false
}

function Connect-Device {
    Banner "STEP 1: Connecting to Fire TV at $Target"
    Invoke-Adb @('disconnect') | Out-Null
    Info 'Sending connection request (accept the prompt on your TV if it appears)...'
    if (Wait-ForDevice 120) {
        Ok "Connected to $Target"
        try { Set-Content -Path $LastIpFile -Value $FireIp -Encoding ASCII } catch { }
        return $true
    }
    Err 'Could not connect. Make sure:'
    Say '      1. Fire TV and this computer are on the same network'
    Say '      2. ADB Debugging is enabled (Settings > My Fire TV > Developer Options)'
    Say '      3. You accepted the connection prompt on the TV screen'
    return $false
}

function Restart-Device {
    # The package manager persists package state asynchronously; rebooting straight after
    # a batch of pm commands loses the last few changes.
    Info 'Letting the Fire TV save its package state...'
    Start-Sleep -Seconds 15
    # Best effort: ask Fire OS to keep ADB debugging enabled across the reboot.
    Invoke-Dsh @('settings', 'put', 'global', 'adb_enabled', '1') | Out-Null
    Invoke-Dsh @('settings', 'put', 'global', 'adb_wifi_enabled', '1') | Out-Null
    Info 'Rebooting Fire TV...'
    Invoke-Dsh @('reboot') | Out-Null
    Start-Sleep -Seconds 20
    if (Wait-ForDevice 180) { Start-Sleep -Seconds 5; Ok 'Device is back online'; return $true }
    # Some Fire OS builds switch ADB debugging off at boot; let the user turn it back on.
    while ($true) {
        Warn 'The Fire TV did not come back on ADB. Fire OS can switch ADB Debugging off at boot.'
        Say '      On the TV: Settings > My Fire TV > Developer Options > ADB Debugging > ON'
        Say "      (then accept the 'Allow USB debugging' prompt again if it appears)"
        if ($NonInteractive) {
            Info 'Waiting up to 5 more minutes for ADB to come back...'
            if (Wait-ForDevice 300) { Start-Sleep -Seconds 5; Ok 'Device is back online'; return $true }
            return $false
        }
        if (-not (Ask-YesNo 'ADB Debugging is on again; try to reconnect?' 'y')) { return $false }
        if (Wait-ForDevice 120) { Start-Sleep -Seconds 5; Ok 'Device is back online'; return $true }
    }
}

# Reads Android/Fire OS version and CPU ABIs; used to pick matching APK variants.
function Read-DeviceInfo {
    $sdk = (Invoke-Dsh @('getprop', 'ro.build.version.sdk')) -replace '\D', ''
    $script:Dev.Sdk = if ($sdk) { [int]$sdk } else { 0 }
    $script:Dev.Release = (Invoke-Dsh @('getprop', 'ro.build.version.release')).Trim()
    $script:Dev.FireOs = (Invoke-Dsh @('getprop', 'ro.build.version.fireos')).Trim()
    $script:Dev.Abis = (Invoke-Dsh @('getprop', 'ro.product.cpu.abilist')).Trim()
    if (-not $script:Dev.Abis) { $script:Dev.Abis = (Invoke-Dsh @('getprop', 'ro.product.cpu.abi')).Trim() }
    $script:Dev.Model = (Invoke-Dsh @('getprop', 'ro.product.model')).Trim()
    $m = if ($Dev.Model) { $Dev.Model } else { 'unknown model' }
    $f = if ($Dev.FireOs) { $Dev.FireOs } else { '?' }
    $r = if ($Dev.Release) { $Dev.Release } else { '?' }
    $c = if ($Dev.Abis) { $Dev.Abis } else { '?' }
    Ok "Device: $m, Fire OS $f (Android $r, API $($Dev.Sdk)), CPU: $c"
}

function Get-Mem {
    $t = Invoke-Dsh @('grep MemTotal /proc/meminfo')
    $a = Invoke-Dsh @('grep MemAvailable /proc/meminfo')
    $p = Invoke-Dsh @('(ps -A 2>/dev/null || ps) | grep -c com.amazon')
    $total = 0; $avail = 0; $procs = 0
    if ($t -match '(\d+)\s*kB') { $total = [math]::Floor([int64]$Matches[1] / 1024) }
    if ($a -match '(\d+)\s*kB') { $avail = [math]::Floor([int64]$Matches[1] / 1024) }
    if ($p -match '(\d+)') { $procs = [int]$Matches[1] }
    return @{ Total = $total; Avail = $avail; Procs = $procs }
}

# Appends a component to a colon-separated secure setting, recording the original
# value in the state file the first time.
function Enable-SecureList($setting, $comp, $pkg) {
    $cur = (Invoke-Dsh @('settings', 'get', 'secure', $setting)).Trim()
    if ($cur -eq 'null') { $cur = '' }
    if (-not (Test-State "prev_$setting")) { Set-State "prev_$setting" $cur }
    if ($cur -like "*$pkg/*") { $new = $cur }
    elseif ($cur -eq '') { $new = $comp }
    else { $new = "${cur}:${comp}" }
    if ($new -ne $cur) { Invoke-Dsh @('settings', 'put', 'secure', $setting, $new) | Out-Null }
}

function Restore-SecureSetting($setting) {
    if (Test-State "prev_$setting") {
        $prev = Get-State1 "prev_$setting"
        if ($prev -eq '') { Invoke-Dsh @('settings', 'delete', 'secure', $setting) | Out-Null }
        else { Invoke-Dsh @('settings', 'put', 'secure', $setting, $prev) | Out-Null }
    } else {
        Invoke-Dsh @('settings', 'delete', 'secure', $setting) | Out-Null
    }
}

function Test-Installed($pkg) { return ((Invoke-Dsh @('pm', 'path', $pkg)) -match 'package:') }

# ------------------------------------------------------------
# APK download / install / configure (driven by launchers.conf)
# ------------------------------------------------------------
function Format-Size($bytes) {
    if ($bytes -ge 1048576) { return ('{0} MB' -f [math]::Floor($bytes / 1048576)) }
    return ('{0} KB' -f [math]::Floor($bytes / 1024))
}

# Get-GitHubLatest owner/repo [asset-glob]; {abi} in the glob is tried with each device ABI, then "universal".
function Get-GitHubLatest($repo, $pattern) {
    if (-not $pattern) { $pattern = '*.apk' }
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'firestick-cleanup' } -UseBasicParsing
    } catch { return $null }
    $assets = @($rel.assets)
    $abis = @($Dev.Abis -split ',' | Where-Object { $_ }) + @('universal')
    $cands = if ($pattern -like '*{abi}*') { @($abis | ForEach-Object { $pattern.Replace('{abi}', $_) }) } else { @($pattern) }
    foreach ($c in $cands) {
        $a = $assets | Where-Object { $_.name -like $c } | Select-Object -First 1
        if ($a) {
            $sha = ''
            if ($a.PSObject.Properties['digest'] -and ([string]$a.digest) -match '^sha256:([0-9a-f]+)$') { $sha = $Matches[1] }
            return @{ Url = [string]$a.browser_download_url; Sha = $sha; Asset = [string]$a.name }
        }
    }
    return $null
}

# SHA-256 of the v1 signing certificate inside an APK, or '' when there is none / it cannot be read.
function Get-ApkV1CertSha256($file) {
    try {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        Add-Type -AssemblyName System.Security
        $zip = [IO.Compression.ZipFile]::OpenRead($file)
        try {
            $entry = $zip.Entries | Where-Object { $_.FullName -match '^META-INF/[^/]+\.(RSA|DSA|EC)$' } | Select-Object -First 1
            if (-not $entry) { return '' }
            $ms = New-Object IO.MemoryStream
            $st = $entry.Open(); $st.CopyTo($ms); $st.Dispose()
            $cms = New-Object System.Security.Cryptography.Pkcs.SignedCms
            $cms.Decode($ms.ToArray())
            $cert = if ($cms.SignerInfos.Count -gt 0 -and $cms.SignerInfos[0].Certificate) { $cms.SignerInfos[0].Certificate } else { $cms.Certificates[0] }
            $sha = [Security.Cryptography.SHA256]::Create()
            return ([BitConverter]::ToString($sha.ComputeHash($cert.RawData)) -replace '-', '').ToLower()
        } finally { $zip.Dispose() }
    } catch { return '' }
}

# Test-Apk <file> [expected signing-cert sha256] -> $true when the file is acceptable
function Test-Apk($file, $want) {
    $fs = [IO.File]::OpenRead($file); $b = New-Object byte[] 2; [void]$fs.Read($b, 0, 2); $fs.Dispose()
    if (-not ($b[0] -eq 0x50 -and $b[1] -eq 0x4B)) { Err "$([IO.Path]::GetFileName($file)) is not an APK (not a zip file)."; return $false }
    if (-not $want) { return $true }
    $got = Get-ApkV1CertSha256 $file
    if (-not $got) { Info 'APK has no readable v1 signature block; the signing certificate cannot be checked here.'; return $true }
    if ($got -ne $want) { Err "Signing certificate mismatch (expected $want, got $got). Refusing to install."; return $false }
    Ok "Signing certificate matches APKMirror's record for this app"
    return $true
}

function Open-Url($url) {
    if ($env:FSC_BROWSER) { Start-Process -FilePath $env:FSC_BROWSER -ArgumentList $url | Out-Null; return }
    Start-Process $url | Out-Null
}

# Waits for a new, complete <package>_*.apk in the watched folders; returns its path or $null.
function Wait-ForDownload($pkg, [datetime]$since, $timeoutSec) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt $timeoutSec) {
        $f = Get-ChildItem -Path @($DownloadsWatch, $PlatformDir) -Filter "${pkg}_*.apk" -File -ErrorAction SilentlyContinue |
             Where-Object { $_.LastWriteTime -gt $since } | Select-Object -First 1
        if ($f) {
            $size1 = $f.Length; Start-Sleep -Seconds 2; $size2 = (Get-Item $f.FullName).Length
            if ($size1 -eq $size2 -and $size1 -gt 100000 -and -not (Test-Path "$($f.FullName).crdownload") -and -not (Test-Path "$($f.FullName).part")) { return $f.FullName }
        }
        Start-Sleep -Seconds 2
    }
    return $null
}

function Get-ApkMirrorRecord($pkg) {
    if ($env:FSC_APKMIRROR_JSON) { return (Get-Content -Raw -Path $env:FSC_APKMIRROR_JSON | ConvertFrom-Json) }
    return Invoke-RestMethod -Method Post -Uri $ApkMirrorApi -Headers @{ Authorization = $ApkMirrorAuth; 'User-Agent' = 'APKUpdater-v3.0.3' } `
        -ContentType 'application/json' -Body "{""pnames"":[""$pkg""]}" -UseBasicParsing
}

# Picks the newest APKMirror variant that fits this device (min API <= device API, matching CPU).
function Find-ApkMirrorVariant($pkg) {
    try { $rec = Get-ApkMirrorRecord $pkg } catch { return $null }
    $item = @($rec.data | Where-Object { $_.pname -eq $pkg }) | Select-Object -First 1
    if (-not $item -or -not $item.exists) { return $null }
    $abis = @($Dev.Abis -split ',' | Where-Object { $_ })
    $best = $null; $bestScore = -1
    foreach ($a in @($item.apks)) {
        $minapi = [int]$a.minapi
        if ($Dev.Sdk -gt 0 -and $minapi -gt $Dev.Sdk) { continue }
        $arches = @($a.arches); $fits = ($arches.Count -eq 0); $arm64 = 0
        foreach ($ar in $arches) {
            if ($ar -eq 'universal' -or $ar -eq 'noarch' -or $abis -contains $ar) { $fits = $true; if ($ar -eq 'arm64-v8a') { $arm64 = 1 } }
        }
        if (-not $fits) { continue }
        $score = $minapi * 10 + $arm64 * 5 + $(if (@($a.dpis) -contains 'nodpi') { 1 } else { 0 })
        if ($score -gt $bestScore) { $bestScore = $score; $best = $a }
    }
    if (-not $best) { return $null }
    $sha = ''
    if ($best.PSObject.Properties['signatures-sha256']) { $sha = [string](@($best.'signatures-sha256')[0]) }
    return @{ Version = [string]$item.release.version; VCode = [string]$best.version_code; MinApi = [int]$best.minapi
              Arches = (@($best.arches) -join ','); Sha = $sha; Page = 'https://www.apkmirror.com' + [string]$best.link }
}

# Browser-assisted APKMirror download. Returns the local APK path or $null.
function Get-ApkMirrorApk($sec, $pkg) {
    $name = Get-Conf1 $sec 'name'
    Info "Looking up $name on APKMirror for Android API $($Dev.Sdk) ($(if ($Dev.Abis) { $Dev.Abis } else { 'unknown CPU' }))..."
    $v = Find-ApkMirrorVariant $pkg
    if ($v) {
        Ok "Latest: $name $($v.Version) (build $($v.VCode), min API $($v.MinApi), $($v.Arches))"
        $page = $v.Page
        New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
        $cached = Get-ChildItem -Path $DownloadDir -Filter "${pkg}_*.apk" -File -ErrorAction SilentlyContinue |
                  Where-Object { $_.Name -like "*-$($v.VCode)_*" -or $_.Name -like "*-$($v.VCode).apk" } | Select-Object -First 1
        if ($cached) { $script:ExpectedVCode = $v.VCode; Ok "Already downloaded: $($cached.Name)"; return $cached.FullName }
    } else {
        Warn "Could not query APKMirror; you will have to pick a version yourself (min Android API $($Dev.Sdk) or lower)."
        $page = Get-Conf1 $sec 'page'
        if (-not $page) { Err "No APKMirror page configured for $name."; return $null }
    }
    if ($NonInteractive) {
        Err "APKMirror does not allow scripted downloads. Save the ${pkg}_*.apk file in $PlatformDir and run again."
        return $null
    }
    Say ''
    Say '  APKMirror does not let scripts download files, so your browser will open on the'
    Say "  download page for $name$(if ($v) { ' ' + $v.Version }) that matches this Fire TV."
    Say "  Click 'DOWNLOAD APK' there (and the 'here' link if nothing starts)."
    Say "  Watching $DownloadsWatch and $PlatformDir for the file..."
    $since = Get-Date
    Open-Url $page
    $found = Wait-ForDownload $pkg $since 900
    if (-not $found) { Err "No ${pkg}_*.apk appeared within 15 minutes. Save it in $PlatformDir and run again."; return $null }
    New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
    $apk = Join-Path $DownloadDir ([IO.Path]::GetFileName($found))
    if ($found -ne $apk) { Move-Item -Path $found -Destination $apk -Force }
    Ok "Got $([IO.Path]::GetFileName($apk)) ($(Format-Size (Get-Item $apk).Length))"
    if (-not (Test-Apk $apk $(if ($v) { $v.Sha } else { '' }))) { return $null }
    if ($v) { $script:ExpectedVCode = $v.VCode }
    return $apk
}

# Returns the local APK path for a section, or $null.
function Get-Apk($sec) {
    $name = Get-Conf1 $sec 'name'; $source = Get-Conf1 $sec 'source'
    $script:ExpectedVCode = ''
    foreach ($glob in ((Get-Conf1 $sec 'apk_glob') -split '\s+')) {
        if (-not $glob) { continue }
        $f = Get-ChildItem -Path $PlatformDir -Filter $glob -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { Ok "Using local APK: $($f.Name)"; return $f.FullName }
    }
    if ($source.StartsWith('github:')) {
        Info "Fetching latest $name release from GitHub..."
        $rel = Get-GitHubLatest $source.Substring(7) (Get-Conf1 $sec 'asset_match')
        if ($rel) { $url = $rel.Url; $sha = $rel.Sha; Info "Release asset: $($rel.Asset)" }
        else {
            $url = Get-Conf1 $sec 'fallback_url'; $sha = ''
            if (-not $url) { Err "Could not query GitHub releases for $name."; return $null }
            Warn 'Could not query GitHub releases; using known-good fallback URL.'
        }
        New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
        $apk = Join-Path $DownloadDir ([IO.Path]::GetFileName($url))
        if ((Test-Path $apk) -and $sha -and ((Get-FileHash -Path $apk -Algorithm SHA256).Hash.ToLower() -eq $sha)) {
            Ok "Already downloaded and verified: $([IO.Path]::GetFileName($apk))"; return $apk
        }
        Info "Downloading $([IO.Path]::GetFileName($url))"
        try { Invoke-WebRequest -Uri $url -OutFile $apk -UseBasicParsing }
        catch { Err "Download failed: $($_.Exception.Message)"; Remove-Item -Path $apk -Force -ErrorAction SilentlyContinue; return $null }
        $size = (Get-Item $apk).Length
        if ($size -lt 100000) { Err 'Downloaded file is too small to be an APK.'; Remove-Item -Path $apk -Force; return $null }
        if ($sha) {
            $got = (Get-FileHash -Path $apk -Algorithm SHA256).Hash.ToLower()
            if ($got -ne $sha) { Err "SHA-256 mismatch for $([IO.Path]::GetFileName($apk)); discarding download."; Remove-Item -Path $apk -Force; return $null }
            Ok "Downloaded ($(Format-Size $size)), SHA-256 verified"
        } else { Ok "Downloaded ($(Format-Size $size))" }
        return $apk
    }
    if ($source.StartsWith('apkmirror:')) { return (Get-ApkMirrorApk $sec $source.Substring(10)) }
    if ($source.StartsWith('manual:')) {
        Err "$name has to be downloaded by hand from $($source.Substring(7))"
        Say "       Save the APK in: $PlatformDir"
        Say "       Accepted file names: $(Get-Conf1 $sec 'apk_glob')"
        return $null
    }
    Err "Unknown source '$source' for $name in launchers.conf"
    return $null
}

function Install-Apk($sec, $apk) {
    $pkg = Get-Conf1 $sec 'package'; $name = Get-Conf1 $sec 'name'
    if (Test-Installed $pkg) { Info "$name is already installed; updating in place." }
    Info 'Pushing APK to device...'
    $out = Invoke-Adb @('-s', $Target, 'push', $apk, "$DeviceTmp/fsc_install.apk")
    if ($out -notmatch 'pushed') { Err "Failed to push APK: $out"; return $false }
    Info 'Installing...'
    $out = Invoke-Dsh @('pm', 'install', '-r', "$DeviceTmp/fsc_install.apk")
    Invoke-Dsh @('rm', '-f', "$DeviceTmp/fsc_install.apk") | Out-Null
    if ($out -notmatch 'Success') { Err "Install failed: $out"; return $false }
    if (-not (Test-Installed $pkg)) { Err "Install reported success but $pkg is not on the device."; return $false }
    Ok "$name installed"
    if ($script:ExpectedVCode) {
        $dump = Invoke-Dsh @('dumpsys', 'package', $pkg)
        if ($dump -match 'versionCode=(\d+)') {
            if ($Matches[1] -ne $script:ExpectedVCode) { Warn "Installed build $($Matches[1]) differs from the expected build $($script:ExpectedVCode)" }
            else { Ok "Installed build $($Matches[1])" }
        }
        $script:ExpectedVCode = ''
    }
    Add-State 'installed' $pkg
    return $true
}

function Start-App($sec) {
    $name = Get-Conf1 $sec 'name'; $act = Get-Conf1 $sec 'activity'
    if ($act) {
        $out = Invoke-Dsh @('am', 'start', '-n', $act)
        if ($out -notmatch 'Error') { Ok "$name launched"; return }
    }
    # No activity configured, or it failed: resolve the app's leanback launcher entry instead.
    $out = Invoke-Dsh @('monkey', '-p', (Get-Conf1 $sec 'package'), '-c', 'android.intent.category.LEANBACK_LAUNCHER', '1')
    if ($out -match 'Events injected') { Ok "$name launched" }
    else { Warn "Could not launch $name automatically; open it from the Fire TV app list." }
}

# Disables the packages an add-on replaces (its "disables=" line), recording them for revert.
function Disable-ReplacedPackages($sec) {
    $dis = @((Get-Conf1 $sec 'disables') -split '\s+' | Where-Object { $_ })
    if ($dis.Count -eq 0) { return }
    $now = Get-DisabledNow
    $pkgs = @()
    foreach ($p in $dis) {
        if ($now -contains $p) { Info "$p is already disabled" }
        elseif (Test-Installed $p) { $pkgs += $p }
        else { Info "$p is not on this device" }
    }
    if ($pkgs.Count -eq 0) { return }
    foreach ($r in (Invoke-DisableBatch $pkgs)) {
        if ($r.Status -eq 'disabled') { Ok "Disabled: $($r.Pkg) (replaced by $(Get-Conf1 $sec 'name'))"; Add-State 'disabled' $r.Pkg }
        else { Warn "Could not disable $($r.Pkg) ($($r.Status))" }
    }
}

function Set-AppConfig($sec) {
    $pkg = Get-Conf1 $sec 'package'; $act = Get-Conf1 $sec 'activity'
    $acc = Get-Conf1 $sec 'accessibility'; $nl = Get-Conf1 $sec 'notification_listener'
    foreach ($p in ((Get-Conf1 $sec 'grant') -split '\s+')) {
        if (-not $p) { continue }
        Invoke-Dsh @('pm', 'grant', $pkg, $p) | Out-Null
        Ok "Granted $($p.Split('.')[-1])"
    }
    if ($acc) {
        Enable-SecureList 'enabled_accessibility_services' $acc $pkg
        Invoke-Dsh @('settings', 'put', 'secure', 'accessibility_enabled', '1') | Out-Null
        if ((Invoke-Dsh @('settings', 'get', 'secure', 'enabled_accessibility_services')) -match [regex]::Escape($pkg)) { Ok 'Accessibility service enabled' }
        else { Err "Could not enable the accessibility service for $pkg"; return $false }
    }
    if ($nl) { Enable-SecureList 'enabled_notification_listeners' $nl $pkg; Ok 'Notification listener enabled' }
    foreach ($op in ((Get-Conf1 $sec 'appops') -split '\s+')) {
        if (-not $op) { continue }
        Invoke-Dsh @('appops', 'set', $pkg, $op, 'allow') | Out-Null
        Ok "App op $op allowed"
    }
    if ((Get-Conf1 $sec 'boot') -eq 'yes') { Set-BootReady $sec }
    if ((Get-Conf1 $sec 'type') -eq 'launcher') {
        Invoke-Dsh @('cmd', 'role', 'add-role-holder', 'android.app.role.HOME', $pkg) | Out-Null; Ok 'HOME role assigned'
        Invoke-Dsh @('cmd', 'package', 'set-home-activity', '--user', '0', $act) | Out-Null; Ok 'Default home activity set'
    }
    Disable-ReplacedPackages $sec
    Start-App $sec
    return $true
}

# Keeps an app's boot receiver and accessibility service from being throttled. Best effort per firmware.
function Set-BootReady($sec) {
    $pkg = Get-Conf1 $sec 'package'
    Invoke-Dsh @('dumpsys', 'deviceidle', 'whitelist', "+$pkg") | Out-Null
    Invoke-Dsh @('appops', 'set', $pkg, 'RUN_IN_BACKGROUND', 'allow') | Out-Null
    Invoke-Dsh @('appops', 'set', $pkg, 'RUN_ANY_IN_BACKGROUND', 'allow') | Out-Null
    Invoke-Dsh @('am', 'set-standby-bucket', $pkg, 'active') | Out-Null
    if ((Invoke-Dsh @('dumpsys', 'deviceidle', 'whitelist')) -like "*$pkg*") { Ok 'Allowed to run at boot and in the background' }
    else { Info "Could not add $pkg to the doze whitelist (not supported on this firmware)" }
}

# Package holding the HOME role. Android 12+ has get-role-holders; older firmware is asked who resolves HOME.
function Get-HomeRoleHolder {
    $out = (Invoke-Dsh @('cmd', 'role', 'get-role-holders', 'android.app.role.HOME')).Trim()
    if (-not $out -or $out -match 'Unknown command|Error|Exception') {
        # Android 11: read the role dump ("name=android.app.role.HOME" then "holders=pkg").
        $out = ''; $found = $false
        foreach ($l in ((Invoke-Dsh @('dumpsys', 'role')) -split "`n")) {
            if ($l -match 'name=android\.app\.role\.HOME\s*$') { $found = $true; continue }
            if ($found -and $l -match 'holders=(.*)$') { $out = $Matches[1].Trim(); break }
        }
    }
    return (($out -split "`n")[0] -replace '[/;,].*$', '')
}

# Package name of the window that currently has focus, or ''.
function Get-ForegroundPackage {
    $line = Invoke-Dsh @('dumpsys window 2>/dev/null | grep -m1 mCurrentFocus')
    if (-not $line.Trim()) { $line = Invoke-Dsh @('dumpsys activity activities 2>/dev/null | grep -m1 mResumedActivity') }
    if ($line -match ' u\d+ ([A-Za-z0-9_.]+)/') { return $Matches[1] }
    return ''
}

# After the reboot: waits for boot, checks the launcher and boot add-ons are running, tests the Home redirect.
function Test-BootState($launcher, [string[]]$addons) {
    Banner 'STEP 8: Checking what starts at boot'
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.Elapsed.TotalSeconds -lt 90 -and ((Invoke-Dsh @('getprop', 'sys.boot_completed')) -replace '\D', '') -ne '1') { Start-Sleep -Seconds 3 }
    Start-Sleep -Seconds 10
    foreach ($sec in (@($launcher) + @($addons))) {
        if ((Get-Conf1 $sec 'boot') -ne 'yes') { continue }
        $pkg = Get-Conf1 $sec 'package'; $name = Get-Conf1 $sec 'name'
        $count = (Invoke-Dsh @("(ps -A 2>/dev/null || ps) | grep -c $pkg")) -replace '\D', ''
        if ($count -and [int]$count -gt 0) { Ok "$name is running after boot" } else { Warn "$name is not running after boot" }
    }
    $pkg = Get-Conf1 $launcher 'package'; $name = Get-Conf1 $launcher 'name'
    $fg = Get-ForegroundPackage
    if ($fg -eq $pkg) { Ok "On screen after boot: $name"; return }
    Info "On screen after boot: $(if ($fg) { $fg } else { 'unknown' }). Pressing Home to test the redirect..."
    Invoke-Dsh @('input', 'keyevent', '3') | Out-Null
    Start-Sleep -Seconds 7
    $fg = Get-ForegroundPackage
    if ($fg -eq $pkg) { Ok "After pressing Home: $name takes over" }
    else {
        Warn "After pressing Home: $(if ($fg) { $fg } else { 'unknown' }) is still in front."
        Say "      On the TV, check: Home on Fire > 'Choose target app' is set and 'Launch on boot' is on;"
        Say "      Projectivy > Settings > General > 'Override current launcher' (OFF if you use Home on Fire)."
    }
}

function Show-Notes($sec) {
    Say ''
    Say '  +---------------------------------------------------------+'
    Say "  |  ACTION REQUIRED on your Fire TV ($(Get-Conf1 $sec 'name'))"
    Say '  |'
    foreach ($line in (Get-Conf $sec 'note')) { Say "  |  $line" }
    Say '  +---------------------------------------------------------+'
    Say ''
    Wait-Enter 'Press Enter when done...'
}

function Install-App($sec) {
    Banner "Installing $(Get-Conf1 $sec 'name')"
    $apk = Get-Apk $sec
    if (-not $apk) { return $false }
    if (-not (Install-Apk $sec $apk)) { return $false }
    if (-not (Set-AppConfig $sec)) { return $false }
    Show-Notes $sec
    return $true
}

# ------------------------------------------------------------
# Package disabling
# ------------------------------------------------------------
function Invoke-DisableBatch([string[]]$pkgs) {
    $lines = @($pkgs | ForEach-Object { "echo `"FSC $_ `$(pm disable-user --user 0 $_ 2>&1)`"" })
    $out = Invoke-DeviceScript ($lines -join "`n")
    $res = @()
    foreach ($l in ($out -split "`n")) {
        if ($l -match '^FSC (\S+) ?(.*)$') {
            $p = $Matches[1]; $m = $Matches[2]
            if ($m -match 'disabled-user') { $st = 'disabled' }
            elseif ($m -match 'SecurityException|rotected') { $st = 'protected' }
            else { $st = "failed: $m" }
            $res += [pscustomobject]@{ Pkg = $p; Status = $st }
        }
    }
    return ,$res
}

function Invoke-EnableBatch([string[]]$pkgs) {
    $lines = @($pkgs | ForEach-Object { "echo `"FSC $_ `$(pm enable --user 0 $_ 2>&1)`"" })
    $out = Invoke-DeviceScript ($lines -join "`n")
    $res = @()
    foreach ($l in ($out -split "`n")) {
        if ($l -match '^FSC (\S+) ?(.*)$') {
            $res += [pscustomobject]@{ Pkg = $Matches[1]; Status = $(if ($Matches[2] -match 'enabled') { 'enabled' } else { 'failed' }) }
        }
    }
    return ,$res
}

function Invoke-DisablePasses([string[]]$remaining) {
    $script:TotalDisabled = 0; $script:TotalProtected = 0; $pass = 0
    while ($true) {
        $pass++; $pd = 0; $pp = 0; $next = @()
        Banner "STEP 6: Disabling bloatware (pass $pass)"
        foreach ($r in (Invoke-DisableBatch $remaining)) {
            switch ($r.Status) {
                'disabled'  { Ok "Disabled: $($r.Pkg)"; Add-State 'disabled' $r.Pkg; $pd++ }
                'protected' { Warn "Protected: $($r.Pkg)"; $pp++; $next += $r.Pkg }
                default     { Warn "Failed: $($r.Pkg) ($($r.Status))" }
            }
        }
        $script:TotalDisabled += $pd; $script:TotalProtected = $pp
        Say ''; Say "  Pass ${pass}: disabled $pd, protected $pp"
        if ($pd -gt 0 -and $pp -gt 0 -and $pass -lt 3) {
            Info 'Some packages are protected; rebooting to retry them...'
            if (Restart-Device) { $remaining = $next; continue }
            Warn 'Could not reconnect after reboot; continuing with what we have.'
        }
        break
    }
    $script:Passes = $pass
}

function Get-DisabledNow {
    return ,@((Invoke-Dsh @('pm', 'list', 'packages', '-d')) -split "`n" | ForEach-Object { $_ -replace '^package:', '' } | Where-Object { $_ })
}

function Invoke-ReapplyDisabled {
    $script:Reapplied = 0
    $now = Get-DisabledNow
    $want = @(Get-State 'disabled' | Where-Object { $now -notcontains $_ })
    if ($want.Count -eq 0) { return }
    $script:Reapplied = @(Invoke-DisableBatch $want | Where-Object { $_.Status -eq 'disabled' }).Count
}

# ------------------------------------------------------------
# Interactive choices
# ------------------------------------------------------------
function Read-Ip {
    $last = ''
    if (Test-Path $LastIpFile) { $last = (Get-Content $LastIpFile | Select-Object -First 1) }
    while (-not $script:FireIp) {
        if ($NonInteractive) { Die '--non-interactive needs --ip <address>.' }
        if ($last) {
            $script:FireIp = Read-Host "  Enter your Fire TV IP address [$last]"
            if (-not $script:FireIp) { $script:FireIp = $last }
        } else {
            $script:FireIp = Read-Host '  Enter your Fire TV IP address (e.g. 10.0.0.20)'
        }
        $script:FireIp = ($script:FireIp -replace '\s', '')
        if ($script:FireIp -match '^(.+):(\d+)$') { $script:FireIp = $Matches[1]; $script:Port = [int]$Matches[2] }
        if ($script:FireIp -notmatch '^(\d{1,3}\.){3}\d{1,3}$' -and $script:FireIp -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]*$') {
            Err "'$($script:FireIp)' is not a valid IP address or host name."
            $script:FireIp = ''
        }
    }
    $script:Target = "$($script:FireIp):$($script:Port)"
    $script:StateFile = Join-Path $PlatformDir "firestick_cleanup_$($script:FireIp).state"
    Read-State
    Write-Log "[CONFIG] target=$Target state=$StateFile"
}

function Select-Launcher {
    $keys = Get-LauncherKeys
    if ($script:LauncherKey) {
        if ($keys -notcontains $script:LauncherKey) { Die "Unknown launcher '$($script:LauncherKey)'. Known: $($keys -join ' ')" }
        return
    }
    if ($NonInteractive) { $script:LauncherKey = 'projectivy'; return }
    Banner 'STEP 2: Choose a launcher'
    for ($i = 0; $i -lt $keys.Count; $i++) {
        Say ('  {0}) {1,-20} {2}' -f ($i + 1), (Get-Conf1 $keys[$i] 'name'), (Get-Conf1 $keys[$i] 'summary'))
    }
    Say ''
    while ($true) {
        $c = Read-Host '  Launcher [1]'
        if ($c -eq '') { $c = '1' }
        if ($c -match '^\d+$' -and [int]$c -ge 1 -and [int]$c -le $keys.Count) { $script:LauncherKey = $keys[[int]$c - 1]; break }
        Say "  Enter a number between 1 and $($keys.Count)."
    }
    Ok "Launcher: $(Get-Conf1 $script:LauncherKey 'name')"
}

# Sets $ChosenAddons (comma-separated) from --with/--without, the launcher's "needs"
# list, each add-on's default, and Y/N prompts.
function Select-Addons {
    $keys = Get-AddonKeys
    foreach ($a in @($AddonsWith + $AddonsWithout)) {
        if ($a -and $keys -notcontains $a) { Die "Unknown add-on '$a'. Known: $($keys -join ' ')" }
    }
    $needs = @((Get-Conf1 $script:LauncherKey 'needs') -split '\s+' | Where-Object { $_ })
    $chosen = @()
    foreach ($a in $keys) {
        if ($AddonsWithout -contains $a) { continue }
        if ($AddonsWith -contains $a) { $chosen += $a; continue }
        $def = if ((Get-Conf1 $a 'default') -eq 'yes' -or $needs -contains $a) { 'y' } else { 'n' }
        if ($NonInteractive) { if ($def -eq 'y') { $chosen += $a }; continue }
        Say ''
        Say "  $(Get-Conf1 $a 'name'): $(Get-Conf1 $a 'summary')"
        if (Ask-YesNo (Get-Conf1 $a 'prompt') $def) { $chosen += $a }
    }
    $script:ChosenAddons = ($chosen -join ',')
}

function Select-Groups {
    if ($NonInteractive) { return $DisableGroups }
    Banner 'STEP 3: Choose what to disable'
    Say ''
    Say '  Tracking, telemetry, ads and background bloat are always disabled.'
    Say '  The following are optional. Answer Y to disable, N to keep.'
    Say ''
    $chosen = @()
    foreach ($g in (Get-Groups)) {
        if ($g.Key -eq 'always') { continue }
        if (Ask-YesNo $g.Prompt 'n') { $chosen += $g.Key }
    }
    return ($chosen -join ',')
}

function Test-Groups($csv) {
    foreach ($g in ($csv -split ',')) {
        if ($g -and -not (Test-Group $g)) {
            Die "Unknown group '$g'. Known: $((Get-Groups | Where-Object { $_.Key -ne 'always' } | ForEach-Object { $_.Key }) -join ' ')"
        }
    }
}

function Get-BloatList($csv) {
    $list = @(Get-GroupPackages 'always')
    foreach ($g in ($csv -split ',')) { if ($g) { $list += Get-GroupPackages $g } }
    return ,$list
}

# Splits a package list into Present (installed and enabled), AlreadyDisabled and Absent.
function Split-Bloat([string[]]$bloat) {
    $all = @((Invoke-Dsh @('pm', 'list', 'packages')) -split "`n" | ForEach-Object { $_ -replace '^package:', '' })
    $dis = Get-DisabledNow
    $present = @(); $already = @(); $absent = @()
    foreach ($p in $bloat) {
        if ($dis -contains $p) { $already += $p }
        elseif ($all -contains $p) { $present += $p }
        else { $absent += $p }
    }
    return @{ Present = $present; AlreadyDisabled = $already; Absent = $absent }
}

# ------------------------------------------------------------
# Modes
# ------------------------------------------------------------
function Show-Status {
    Banner "STATUS for $Target"
    $acc = (Invoke-Dsh @('settings', 'get', 'secure', 'enabled_accessibility_services')).Trim()
    $role = Get-HomeRoleHolder
    $dis = Get-DisabledNow
    foreach ($k in (Get-Sections)) {
        $pkg = Get-Conf1 $k 'package'; $name = Get-Conf1 $k 'name'
        if (Test-Installed $pkg) {
            $extra = ''
            if ($acc -like "*$pkg*") { $extra += ', accessibility service on' }
            if ($role -like "*$pkg*") { $extra += ', holds HOME role' }
            Ok "${name}: installed$extra"
        } else { Warn "${name}: not installed" }
    }
    Say ''
    Say "  HOME role holder:        $(if ($role) { $role } else { 'unknown' })"
    Say "  Accessibility services:  $(if ($acc) { $acc } else { 'none' })"
    Say "  Disabled packages:       $($dis.Count)"
    foreach ($d in $dis) { Say "      $d" }
    Say ''
    if (Test-Path $StateFile) {
        Say "  Saved state ($StateFile):"
        Say "      launcher=$(Get-State1 'launcher') addons=$(Get-State1 'addons') groups=$(Get-State1 'groups')"
        Say "      recorded as disabled by this tool: $(@(Get-State 'disabled').Count)"
    } else {
        Say '  No saved state for this device (nothing recorded by this tool yet).'
    }
}

function Invoke-Revert {
    Banner "REVERTING CHANGES on $Target"
    if (Test-Path $StateFile) {
        Info "Using saved state: $StateFile"
        $pkgs = @(Get-State 'disabled')
    } else {
        Warn 'No saved state for this device. Falling back to re-enabling EVERY'
        Warn 'disabled package, including any you disabled yourself.'
        if (-not (Ask-YesNo 'Continue?' 'n')) { Die 'Revert cancelled.' }
        $pkgs = Get-DisabledNow
    }
    if ($pkgs.Count -gt 0) {
        Info "Re-enabling $($pkgs.Count) packages..."
        foreach ($r in (Invoke-EnableBatch $pkgs)) {
            if ($r.Status -eq 'enabled') { Ok "Enabled: $($r.Pkg)" } else { Warn "Could not enable: $($r.Pkg)" }
        }
    } else { Info 'No packages to re-enable.' }

    Restore-SecureSetting 'enabled_accessibility_services'
    Restore-SecureSetting 'enabled_notification_listeners'
    $accNow = (Invoke-Dsh @('settings', 'get', 'secure', 'enabled_accessibility_services')).Trim()
    if (-not $accNow -or $accNow -eq 'null') { Invoke-Dsh @('settings', 'put', 'secure', 'accessibility_enabled', '0') | Out-Null }
    Ok 'Accessibility and notification listener settings restored'

    if (Test-Path $StateFile) { $apps = @(Get-State 'installed') }
    else { $apps = @(Get-Sections | ForEach-Object { Get-Conf1 $_ 'package' }) }
    foreach ($pkg in $apps) {
        if (-not (Test-Installed $pkg)) { continue }
        Invoke-Dsh @('appops', 'set', $pkg, 'SYSTEM_ALERT_WINDOW', 'default') | Out-Null
        Invoke-Dsh @('cmd', 'role', 'remove-role-holder', 'android.app.role.HOME', $pkg) | Out-Null
        if ((Invoke-Dsh @('pm', 'uninstall', $pkg)) -match 'Success') { Ok "Uninstalled: $pkg" } else { Warn "Could not uninstall $pkg" }
    }
    Invoke-Dsh @('cmd', 'role', 'add-role-holder', 'android.app.role.HOME', 'com.amazon.tv.launcher') | Out-Null
    Ok 'HOME role returned to the Amazon launcher'
    Remove-Item -Path $StateFile -Force -ErrorAction SilentlyContinue
    $script:State.Clear()
    Banner 'REVERT COMPLETE'
}

function Test-App($sec) {
    $pkg = Get-Conf1 $sec 'package'; $name = Get-Conf1 $sec 'name'
    if (Test-Installed $pkg) { Ok "$name is installed" } else { Err "$name is NOT installed" }
    foreach ($p in ((Get-Conf1 $sec 'grant') -split '\s+')) {
        if (-not $p) { continue }
        $short = $p.Split('.')[-1]
        if ((Invoke-Dsh @('dumpsys', 'package', $pkg)) -like "*$p`: granted=true*") { Ok "$name has $short"; continue }
        # Grants made shortly before a reboot can be lost; grant again and re-check.
        Invoke-Dsh @('pm', 'grant', $pkg, $p) | Out-Null
        if ((Invoke-Dsh @('dumpsys', 'package', $pkg)) -like "*$p`: granted=true*") { Ok "$name has $short (granted again; the first grant did not persist)" }
        elseif ($p -eq 'android.permission.WRITE_SECURE_SETTINGS' -and (Get-Conf1 $sec 'accessibility')) {
            Warn "$short cannot be granted on this firmware."
            Say '      Not a problem: the accessibility service was enabled directly over adb instead;'
            Say "      only the app's own in-app accessibility toggle needs that permission."
        }
        else { Err "$name is missing $short (grant it with: adb shell pm grant $pkg $p)" }
    }
    if (Get-Conf1 $sec 'accessibility') {
        if ((Invoke-Dsh @('settings', 'get', 'secure', 'enabled_accessibility_services')) -like "*$pkg*") { Ok "$name accessibility service is active" }
        else { Err "$name accessibility service is NOT active" }
    }
    if ((Get-Conf1 $sec 'type') -eq 'launcher') {
        if ((Get-HomeRoleHolder) -eq $pkg) { Ok "$name holds the HOME role" }
        else { Warn "$name does not hold the HOME role (expected on some firmware; the Home-button service still works)" }
    }
}

function Invoke-Install {
    $before = Get-Mem
    Say "  RAM: $($before.Avail) MB available of $($before.Total) MB, $($before.Procs) Amazon processes running"

    Select-Launcher
    Select-Addons
    $groups = Select-Groups
    Test-Groups $groups
    $bloat = Get-BloatList $groups
    $split = Split-Bloat $bloat

    if ($Mode -eq 'dry-run') {
        Banner 'DRY RUN - nothing will be changed'
        Say "  Launcher:        $(Get-Conf1 $script:LauncherKey 'name')"
        Say "  Add-ons:         $(if ($script:ChosenAddons) { $script:ChosenAddons } else { 'none' })"
        Say "  Optional groups: $(if ($groups) { $groups } else { 'none' })"
        Say ''
        Say "  Would disable ($($split.Present.Count)):";        foreach ($p in $split.Present) { Say "      $p" }
        Say "  Already disabled ($($split.AlreadyDisabled.Count)):"; foreach ($p in $split.AlreadyDisabled) { Say "      $p" }
        Say "  Not on this device ($($split.Absent.Count)):";     foreach ($p in $split.Absent) { Say "      $p" }
        return
    }

    Set-State 'version' $Version
    Set-State 'launcher' $script:LauncherKey
    Set-State 'addons' $script:ChosenAddons
    Set-State 'groups' $groups

    if (-not (Install-App $script:LauncherKey)) { Die 'Launcher setup failed.' }
    foreach ($a in @($script:ChosenAddons -split ',' | Where-Object { $_ })) {
        if (-not (Install-App $a)) { Die "$(Get-Conf1 $a 'name') setup failed." }
    }

    if ($split.Present.Count -gt 0) { Invoke-DisablePasses $split.Present }
    else { $script:TotalDisabled = 0; $script:TotalProtected = 0; $script:Passes = 0; Info 'Nothing new to disable.' }
    if ($split.Absent.Count -gt 0) { Info "$($split.Absent.Count) packages are not on this device and were skipped." }

    if ($script:Passes -le 1) {
        Banner 'Rebooting to apply changes'
        if (-not (Restart-Device)) { Die 'Could not reconnect after reboot.' }
    }
    Invoke-ReapplyDisabled
    if ($script:Reapplied -gt 0) { Ok "Re-disabled $($script:Reapplied) packages that came back after the reboot" }
    else { Ok 'All packages stayed disabled after the reboot' }

    Banner 'STEP 7: Verifying'
    Test-App $script:LauncherKey
    foreach ($a in @($script:ChosenAddons -split ',' | Where-Object { $_ })) { Test-App $a }
    Say "  [OK] $((Get-DisabledNow).Count) packages are disabled on the device"
    Test-BootState $script:LauncherKey @($script:ChosenAddons -split ',' | Where-Object { $_ })

    $after = Get-Mem
    Banner 'RAM: before vs after'
    Say ('  {0,-20} {1,10} {2,10}' -f '', 'BEFORE', 'AFTER')
    Say ('  {0,-20} {1,7} MB {2,7} MB   (+{3} MB freed)' -f 'Available RAM', $before.Avail, $after.Avail, ($after.Avail - $before.Avail))
    Say ('  {0,-20} {1,10} {2,10}   (-{3})' -f 'Amazon processes', $before.Procs, $after.Procs, ($before.Procs - $after.Procs))

    Banner 'ALL DONE'
    Say "  Launcher:            $(Get-Conf1 $script:LauncherKey 'name')"
    Say "  Add-ons:             $(if ($script:ChosenAddons) { $script:ChosenAddons } else { 'none' })"
    Say "  Disabled this run:   $($script:TotalDisabled) (protected by Amazon: $($script:TotalProtected))"
    Say "  RAM freed:           $($after.Avail - $before.Avail) MB"
    Say ''
    Say "  After a Fire OS update, re-apply with:  $EntryName --ip $FireIp --reapply -y"
    Say "  To undo everything:                     $EntryName --ip $FireIp --revert"
    Say "  State: $StateFile"
}

function Invoke-Reapply {
    Banner "RE-APPLYING saved choices on $Target"
    if (Test-Path $StateFile) {
        $groups = Get-State1 'groups'
        if ($DisableGroups) { $groups = $DisableGroups }
        Info "Groups: $(if ($groups) { $groups } else { 'none' }) (from $StateFile)"
    } else {
        if (-not $DisableGroups -and $NonInteractive) { Die "No saved state for $FireIp and no --disable given." }
        $groups = if ($DisableGroups) { $DisableGroups } else { Select-Groups }
    }
    Test-Groups $groups
    Set-State 'groups' $groups
    $split = Split-Bloat (Get-BloatList $groups)
    if ($split.Present.Count -gt 0) {
        Invoke-DisablePasses $split.Present
        if ($script:Passes -le 1 -and $script:TotalDisabled -gt 0) {
            Banner 'Rebooting to apply changes'
            if (-not (Restart-Device)) { Die 'Could not reconnect after reboot.' }
            Invoke-ReapplyDisabled
        }
    } else {
        $script:TotalDisabled = 0; $script:TotalProtected = 0
        Ok 'Everything is already disabled; nothing to do.'
    }
    $lk = Get-State1 'launcher'
    if ($lk -and (Test-Installed (Get-Conf1 $lk 'package'))) {
        if (Set-AppConfig $lk) { Ok "$(Get-Conf1 $lk 'name') settings re-applied" }
    }
    foreach ($a in @((Get-State1 'addons') -split ',' | Where-Object { $_ })) {
        if (Test-Installed (Get-Conf1 $a 'package')) {
            if (Set-AppConfig $a) { Ok "$(Get-Conf1 $a 'name') settings re-applied" }
        }
    }
    Banner 'RE-APPLY COMPLETE'
    Say "  Disabled this run: $($script:TotalDisabled) (protected: $($script:TotalProtected))"
}

function Invoke-TestBoot {
    $lk = Get-State1 'launcher'
    if (-not $lk) { Die "No saved state for $FireIp; run an install first." }
    Banner "BOOT TEST on $Target"
    if (-not (Restart-Device)) { Die 'Could not reconnect after reboot.' }
    Invoke-ReapplyDisabled
    if ($script:Reapplied -gt 0) { Ok "Re-disabled $($script:Reapplied) packages that came back after the reboot" }
    else { Ok 'All packages stayed disabled after the reboot' }
    $addons = @((Get-State1 'addons') -split ',' | Where-Object { $_ })
    Test-App $lk
    foreach ($a in $addons) { Test-App $a }
    Test-BootState $lk $addons
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
Set-Location $PlatformDir
Set-Content -Path $LogFile -Value "Firestick Cleanup $Version log - $(Get-Date)`nmode=$Mode platform_dir=$PlatformDir" -Encoding UTF8

Banner "Firestick Cleanup $Version"
Say '    Launcher replacement + debloat for Fire TV'
Say ''

if (-not (Test-Path $PackagesConf))  { Die "Missing $PackagesConf" }
if (-not (Test-Path $LaunchersConf)) { Die "Missing $LaunchersConf" }
if (-not (Find-Adb)) { Die "ADB is not available. Install Android platform-tools or put adb.exe in $PlatformDir\adb\." }
Ok "ADB: $ADB"

Read-Ip
if (-not (Connect-Device)) { Die 'Connection failed.' }
Read-DeviceInfo

switch ($Mode) {
    'status'  { Show-Status }
    'revert'  { Invoke-Revert }
    'reapply' { Invoke-Reapply }
    'test-boot' { Invoke-TestBoot }
    default   { Invoke-Install }
}

Say ''
Say "  Log saved to: $LogFile"
Wait-Enter 'Press Enter to exit...'
exit 0
