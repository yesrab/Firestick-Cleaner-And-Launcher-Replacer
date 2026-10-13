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
$LogFile       = Join-Path $PlatformDir ('firestick_cleanup_{0:yyyyMMdd_HHmmss}.log' -f (Get-Date))
$EntryName     = 'Firestick-Cleaner-And-Launcher-Replacer.bat'

$Mode = 'install'; $FireIp = ''; $Port = 5555; $LauncherKey = ''; $HofChoice = ''
$DisableGroups = ''; $NonInteractive = $false; $ADB = ''; $Target = ''; $StateFile = ''
$State = New-Object System.Collections.ArrayList
$TotalDisabled = 0; $TotalProtected = 0; $Passes = 0; $Reapplied = 0

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

Options
  --ip <ip[:port]>    Fire TV address (skips the prompt)
  --launcher <key>    projectivy | at4k | couchy   (default: projectivy)
  --home-on-fire      Also install Home on Fire
  --no-home-on-fire   Skip Home on Fire
  --disable <a,b,..>  Optional groups to disable, comma-separated (see common\packages.conf)
  -y, --non-interactive
                      Never prompt; requires --ip.
  -h, --help          This help

Examples
  $EntryName
  $EntryName --ip 10.0.0.20 --launcher couchy --home-on-fire --disable video,appstore -y
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
        '^(--|-|/)ip$'              { $i++; $FireIp = [string]$argv[$i]; break }
        '^(--|-|/)ip=(.+)$'         { $FireIp = $Matches[2]; break }
        '^(--|-|/)launcher$'        { $i++; $LauncherKey = [string]$argv[$i]; break }
        '^(--|-|/)launcher=(.+)$'   { $LauncherKey = $Matches[2]; break }
        '^(--|-|/)home-?on-?fire$'  { $HofChoice = 'yes'; break }
        '^(--|-|/)no-?home-?on-?fire$' { $HofChoice = 'no'; break }
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
    Info 'Rebooting Fire TV...'
    Invoke-Dsh @('reboot') | Out-Null
    Start-Sleep -Seconds 20
    if (Wait-ForDevice 180) { Start-Sleep -Seconds 5; Ok 'Device is back online'; return $true }
    return $false
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

function Get-GitHubLatest($repo) {
    try {
        $rel = Invoke-RestMethod -Uri "https://api.github.com/repos/$repo/releases/latest" -Headers @{ 'User-Agent' = 'firestick-cleanup' } -UseBasicParsing
    } catch { return $null }
    $apks = @($rel.assets | Where-Object { $_.name -like '*.apk' })
    if ($apks.Count -eq 0) { return $null }
    $sha = ''
    if ($apks.Count -eq 1 -and $apks[0].PSObject.Properties['digest'] -and ([string]$apks[0].digest) -match '^sha256:([0-9a-f]+)$') { $sha = $Matches[1] }
    return @{ Url = [string]$apks[0].browser_download_url; Sha = $sha }
}

# Returns the local APK path for a section, or $null.
function Get-Apk($sec) {
    $name = Get-Conf1 $sec 'name'; $source = Get-Conf1 $sec 'source'
    foreach ($glob in ((Get-Conf1 $sec 'apk_glob') -split '\s+')) {
        if (-not $glob) { continue }
        $f = Get-ChildItem -Path $PlatformDir -Filter $glob -File -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($f) { Ok "Using local APK: $($f.Name)"; return $f.FullName }
    }
    if ($source.StartsWith('github:')) {
        Info "Fetching latest $name release from GitHub..."
        $rel = Get-GitHubLatest $source.Substring(7)
        if ($rel) { $url = $rel.Url; $sha = $rel.Sha }
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
    Add-State 'installed' $pkg
    return $true
}

function Start-App($sec) {
    $name = Get-Conf1 $sec 'name'
    $out = Invoke-Dsh @('am', 'start', '-n', (Get-Conf1 $sec 'activity'))
    if ($out -match 'Error') {
        $out = Invoke-Dsh @('monkey', '-p', (Get-Conf1 $sec 'package'), '-c', 'android.intent.category.LEANBACK_LAUNCHER', '1')
        if ($out -match 'Events injected') { Ok "$name launched" }
        else { Warn "Could not launch $name automatically; open it from the Fire TV app list." }
    } else { Ok "$name launched" }
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
    if ((Get-Conf1 $sec 'type') -eq 'launcher') {
        Invoke-Dsh @('appops', 'set', $pkg, 'SYSTEM_ALERT_WINDOW', 'allow') | Out-Null; Ok 'Overlay permission granted'
        Invoke-Dsh @('cmd', 'role', 'add-role-holder', 'android.app.role.HOME', $pkg) | Out-Null; Ok 'HOME role assigned'
        Invoke-Dsh @('cmd', 'package', 'set-home-activity', '--user', '0', $act) | Out-Null; Ok 'Default home activity set'
    }
    Start-App $sec
    return $true
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

function Select-HomeOnFire {
    if ($script:HofChoice) { return }
    $def = if ((Get-Conf1 $script:LauncherKey 'needs_home_on_fire') -eq 'yes') { 'y' } else { 'n' }
    Say ''
    Say '  Home on Fire is a small app that redirects the Home button to your'
    Say '  launcher. It is required for Couchy and optional for launchers that'
    Say '  bring their own Home-button service (Projectivy, AT4K).'
    $script:HofChoice = if (Ask-YesNo 'Install Home on Fire?' $def) { 'yes' } else { 'no' }
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
    $role = (Invoke-Dsh @('cmd', 'role', 'get-role-holders', 'android.app.role.HOME')).Trim()
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
        Say "      launcher=$(Get-State1 'launcher') home_on_fire=$(Get-State1 'home_on_fire') groups=$(Get-State1 'groups')"
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
    if (Get-Conf1 $sec 'accessibility') {
        if ((Invoke-Dsh @('settings', 'get', 'secure', 'enabled_accessibility_services')) -like "*$pkg*") { Ok "$name accessibility service is active" }
        else { Err "$name accessibility service is NOT active" }
    }
    if ((Get-Conf1 $sec 'type') -eq 'launcher') {
        if ((Invoke-Dsh @('cmd', 'role', 'get-role-holders', 'android.app.role.HOME')) -like "*$pkg*") { Ok "$name holds the HOME role" }
        else { Warn "$name does not hold the HOME role (expected on some firmware; the Home-button service still works)" }
    }
}

function Invoke-Install {
    $before = Get-Mem
    Say "  RAM: $($before.Avail) MB available of $($before.Total) MB, $($before.Procs) Amazon processes running"

    Select-Launcher
    Select-HomeOnFire
    $groups = Select-Groups
    Test-Groups $groups
    $bloat = Get-BloatList $groups
    $split = Split-Bloat $bloat

    if ($Mode -eq 'dry-run') {
        Banner 'DRY RUN - nothing will be changed'
        Say "  Launcher:        $(Get-Conf1 $script:LauncherKey 'name')"
        Say "  Home on Fire:    $($script:HofChoice)"
        Say "  Optional groups: $(if ($groups) { $groups } else { 'none' })"
        Say ''
        Say "  Would disable ($($split.Present.Count)):";        foreach ($p in $split.Present) { Say "      $p" }
        Say "  Already disabled ($($split.AlreadyDisabled.Count)):"; foreach ($p in $split.AlreadyDisabled) { Say "      $p" }
        Say "  Not on this device ($($split.Absent.Count)):";     foreach ($p in $split.Absent) { Say "      $p" }
        return
    }

    Set-State 'version' $Version
    Set-State 'launcher' $script:LauncherKey
    Set-State 'home_on_fire' $script:HofChoice
    Set-State 'groups' $groups

    if (-not (Install-App $script:LauncherKey)) { Die 'Launcher setup failed.' }
    if ($script:HofChoice -eq 'yes') { if (-not (Install-App 'homeonfire')) { Die 'Home on Fire setup failed.' } }

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
    if ($script:HofChoice -eq 'yes') { Test-App 'homeonfire' }
    Say "  [OK] $((Get-DisabledNow).Count) packages are disabled on the device"

    $after = Get-Mem
    Banner 'RAM: before vs after'
    Say ('  {0,-20} {1,10} {2,10}' -f '', 'BEFORE', 'AFTER')
    Say ('  {0,-20} {1,7} MB {2,7} MB   (+{3} MB freed)' -f 'Available RAM', $before.Avail, $after.Avail, ($after.Avail - $before.Avail))
    Say ('  {0,-20} {1,10} {2,10}   (-{3})' -f 'Amazon processes', $before.Procs, $after.Procs, ($before.Procs - $after.Procs))

    Banner 'ALL DONE'
    Say "  Launcher:            $(Get-Conf1 $script:LauncherKey 'name')"
    Say "  Home on Fire:        $($script:HofChoice)"
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
    if ((Get-State1 'home_on_fire') -eq 'yes' -and (Test-Installed (Get-Conf1 'homeonfire' 'package'))) {
        if (Set-AppConfig 'homeonfire') { Ok 'Home on Fire settings re-applied' }
    }
    Banner 'RE-APPLY COMPLETE'
    Say "  Disabled this run: $($script:TotalDisabled) (protected: $($script:TotalProtected))"
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

switch ($Mode) {
    'status'  { Show-Status }
    'revert'  { Invoke-Revert }
    'reapply' { Invoke-Reapply }
    default   { Invoke-Install }
}

Say ''
Say "  Log saved to: $LogFile"
Wait-Enter 'Press Enter to exit...'
exit 0
