#!/usr/bin/env bash
# Firestick Cleanup - shared implementation for macOS and Linux.
#
# Entry points (thin wrappers that run this file):
#   mac/Firestick-Cleaner-And-Launcher-Replacer.command
#   linux/Firestick-Cleaner-And-Launcher-Replacer.sh
#
# Package and launcher definitions live in packages.conf and launchers.conf
# next to this script. Works on bash 3.2 (macOS default) and newer.

set -uo pipefail

VERSION="2.0.0"
COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PLATFORM_DIR="${FSC_PLATFORM_DIR:-$COMMON_DIR}"
ENTRY="${FSC_ENTRY:-$0}"
PACKAGES_CONF="$COMMON_DIR/packages.conf"
LAUNCHERS_CONF="$COMMON_DIR/launchers.conf"
DOWNLOAD_DIR="$PLATFORM_DIR/downloads"
LAST_IP_FILE="$PLATFORM_DIR/.last_ip"
DEVICE_TMP="/data/local/tmp"
# Folder your browser saves downloads to (override with FSC_DOWNLOADS_DIR).
DOWNLOADS_WATCH="${FSC_DOWNLOADS_DIR:-$HOME/Downloads}"
# APKMirror serves app metadata (versions, variants, signing certs) to the open-source
# APKUpdater app through this endpoint; the key below ships inside that app. APKMirror
# does not allow scripted file downloads, so the download itself happens in your browser.
APKMIRROR_API="https://www.apkmirror.com/wp-json/apkm/v1/app_exists/"
APKMIRROR_AUTH="Basic YXBpLWFwa3VwZGF0ZXI6cm01cmNmcnVVakt5MDRzTXB5TVBKWFc4"

MODE="install"          # install | revert | reapply | status | dry-run
FIRE_IP=""
PORT=5555
LAUNCHER_KEY=""
ADDONS_WITH=""          # comma-separated add-on keys forced on  (--with, --home-on-fire)
ADDONS_WITHOUT=""       # comma-separated add-on keys forced off (--without, --no-home-on-fire)
CHOSEN_ADDONS=""
DISABLE_GROUPS=""       # comma-separated group keys for non-interactive runs
NONINTERACTIVE=0
ADB=""
TARGET=""
STATE_FILE=""
LOGFILE=""
DEV_SDK=0; DEV_ABIS=""; DEV_RELEASE=""; DEV_FIREOS=""; DEV_MODEL=""
EXPECTED_VCODE=""
if [ -t 1 ]; then CURL_PROGRESS="--progress-bar"; else CURL_PROGRESS="-sS"; fi

# ------------------------------------------------------------
# CLI
# ------------------------------------------------------------
usage() {
    cat <<EOF
Firestick Cleanup $VERSION - replace the Fire TV launcher and disable Amazon bloat.

Usage: $(basename "$ENTRY") [options]

Modes (default: full install)
  --revert            Undo everything recorded for this device and restore stock
  --reapply           Re-disable packages using the saved choices (after a Fire OS update)
  --status            Show launcher, Home on Fire and disabled-package state; change nothing
  --dry-run           Show what would be done; change nothing
  --test-boot         Reboot the Fire TV and check the launcher and add-ons come up (after you
                      finished the on-TV steps, or any time you want a cold-boot check)

Options
  --ip <ip[:port]>    Fire TV address (skips the prompt)
  --launcher <key>    projectivy | at4k | couchy   (default: projectivy)
  --with <a,b,..>     Add-ons: homeonfire, youtubetv, googleapp, smarttube (see launchers.conf)
  --without <a,b,..>  Add-ons to skip
  --home-on-fire      Same as --with homeonfire      --no-home-on-fire: --without homeonfire
  --disable <a,b,..>  Optional groups to disable, comma-separated (see packages.conf)
  -y, --non-interactive
                      Never prompt; requires --ip. Uses --launcher/--with/--disable,
                      or the saved choices for --reapply.
  -h, --help          This help

Examples
  $(basename "$ENTRY")
  $(basename "$ENTRY") --ip 10.0.0.20 --launcher couchy --with homeonfire,youtubetv --disable video,appstore -y
  $(basename "$ENTRY") --ip 10.0.0.20 --reapply -y
  $(basename "$ENTRY") --revert
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --revert)   MODE=revert ;;
        --reapply)  MODE=reapply ;;
        --status)   MODE=status ;;
        --dry-run)  MODE=dry-run ;;
        --test-boot) MODE=test-boot ;;
        --ip)       FIRE_IP="${2:-}"; shift ;;
        --ip=*)     FIRE_IP="${1#--ip=}" ;;
        --launcher) LAUNCHER_KEY="${2:-}"; shift ;;
        --launcher=*) LAUNCHER_KEY="${1#--launcher=}" ;;
        --with)     ADDONS_WITH="${ADDONS_WITH:+$ADDONS_WITH,}${2:-}"; shift ;;
        --with=*)   ADDONS_WITH="${ADDONS_WITH:+$ADDONS_WITH,}${1#--with=}" ;;
        --without)  ADDONS_WITHOUT="${ADDONS_WITHOUT:+$ADDONS_WITHOUT,}${2:-}"; shift ;;
        --without=*) ADDONS_WITHOUT="${ADDONS_WITHOUT:+$ADDONS_WITHOUT,}${1#--without=}" ;;
        --home-on-fire)    ADDONS_WITH="${ADDONS_WITH:+$ADDONS_WITH,}homeonfire" ;;
        --no-home-on-fire) ADDONS_WITHOUT="${ADDONS_WITHOUT:+$ADDONS_WITHOUT,}homeonfire" ;;
        --disable)  DISABLE_GROUPS="${2:-}"; shift ;;
        --disable=*) DISABLE_GROUPS="${1#--disable=}" ;;
        -y|--non-interactive) NONINTERACTIVE=1 ;;
        -h|--help)  usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

# ------------------------------------------------------------
# Output helpers
# ------------------------------------------------------------
LOGFILE="$PLATFORM_DIR/firestick_cleanup_$(date +%Y%m%d_%H%M%S).log"
log()    { printf '%s\n' "$*" >> "$LOGFILE"; }
say()    { printf '%s\n' "$*"; log "$*"; }
ok()     { say "  [OK] $*"; }
info()   { say "  [..] $*"; }
warn()   { say "  [--] $*"; }
err()    { say "  [!!] $*"; }
banner() {
    say ""
    say "  ========================================"
    say "    $*"
    say "  ========================================"
}

pause() {
    [ "$NONINTERACTIVE" -eq 1 ] && return 0
    read -r -p "  ${1:-Press Enter to continue...}" _ || true
}

die() {
    err "$*"
    say ""
    say "  Log: $LOGFILE"
    pause "Press Enter to exit..."
    exit 1
}

# yesno "Question?" default(y|n)  -> returns 0 for yes
yesno() {
    local prompt="$1" def="${2:-n}" hint reply
    if [ "$def" = y ]; then hint="[Y/n]"; else hint="[y/N]"; fi
    if [ "$NONINTERACTIVE" -eq 1 ]; then
        [ "$def" = y ]
        return
    fi
    while true; do
        read -r -p "  $prompt $hint " reply || reply=""
        case "$reply" in
            "")    [ "$def" = y ]; return ;;
            [Yy]*) return 0 ;;
            [Nn]*) return 1 ;;
        esac
    done
}

# ------------------------------------------------------------
# Config parsing (packages.conf / launchers.conf)
# ------------------------------------------------------------
# Prints "key<TAB>prompt" for every group, in file order.
conf_groups() {
    awk '
        /^\[/ {
            key = $0; sub(/^\[/, "", key); sub(/\].*$/, "", key)
            prompt = $0; sub(/^[^\]]*\][ \t]*/, "", prompt)
            print key "\t" prompt
        }' "$PACKAGES_CONF"
}

# Prints the packages of one group, one per line.
conf_packages() {
    awk -v key="$1" '
        /^[ \t]*#/ || /^[ \t]*$/ { next }
        /^\[/ { cur = $0; sub(/^\[/, "", cur); sub(/\].*$/, "", cur); next }
        cur == key { if ($1 != "" && $1 !~ /^#/) print $1 }' "$PACKAGES_CONF"
}

# lconf <section> <key> -> value(s), one per line (empty if unset)
lconf() {
    awk -v sec="$1" -v key="$2" '
        /^[ \t]*#/ || /^[ \t]*$/ { next }
        /^\[/ { cur = $0; sub(/^\[/, "", cur); sub(/\].*$/, "", cur); next }
        cur == sec && index($0, key "=") == 1 { print substr($0, length(key) + 2) }' "$LAUNCHERS_CONF"
}

lconf_sections() {
    awk '/^\[/ { s = $0; sub(/^\[/, "", s); sub(/\].*$/, "", s); print s }' "$LAUNCHERS_CONF"
}

launcher_keys() {
    local s
    for s in $(lconf_sections); do
        [ "$(lconf "$s" type)" = launcher ] && echo "$s"
    done
}

addon_keys() {
    local s
    for s in $(lconf_sections); do
        [ "$(lconf "$s" type)" = addon ] && echo "$s"
    done
}

group_exists() {
    conf_groups | awk -F'\t' -v k="$1" '$1 == k { found = 1 } END { exit !found }'
}

# Comma-separated list helpers
csv_items() { printf '%s' "$1" | tr ',' ' '; }
csv_has()   { case ",$1," in *",$2,"*) return 0 ;; esac; return 1; }
csv_add()   { if csv_has "$1" "$2"; then printf '%s' "$1"; else printf '%s' "${1:+$1,}$2"; fi; }

# ------------------------------------------------------------
# State file (what this tool changed on a given device)
# ------------------------------------------------------------
state_put() { printf '%s=%s\n' "$1" "$2" >> "$STATE_FILE"; }
state_get() { [ -f "$STATE_FILE" ] && sed -n "s/^$1=//p" "$STATE_FILE"; return 0; }
state_has() { [ -f "$STATE_FILE" ] && grep -q "^$1=" "$STATE_FILE"; }
state_set() {
    if [ -f "$STATE_FILE" ]; then
        grep -v "^$1=" "$STATE_FILE" > "$STATE_FILE.tmp" || true
        mv "$STATE_FILE.tmp" "$STATE_FILE"
    fi
    state_put "$1" "$2"
}
state_add_unique() {
    grep -qx "$1=$2" "$STATE_FILE" 2>/dev/null || state_put "$1" "$2"
}

# ------------------------------------------------------------
# ADB discovery
# ------------------------------------------------------------
find_adb() {
    local bundled="$PLATFORM_DIR/adb/adb" os url zip
    if [ -f "$bundled" ]; then
        [ "$(uname)" = Darwin ] && xattr -dr com.apple.quarantine "$PLATFORM_DIR/adb" >/dev/null 2>&1
        chmod +x "$bundled" 2>/dev/null
        if "$bundled" version >/dev/null 2>&1; then
            ADB="$bundled"
            return 0
        fi
        warn "Bundled adb does not run on this machine ($(uname -m))."
    fi
    if command -v adb >/dev/null 2>&1 && adb version >/dev/null 2>&1; then
        ADB="$(command -v adb)"
        return 0
    fi
    case "$(uname)" in
        Darwin) os=darwin ;;
        Linux)  os=linux ;;
        *) return 1 ;;
    esac
    url="https://dl.google.com/android/repository/platform-tools-latest-$os.zip"
    say "  ADB was not found. It can be downloaded from Google ($url)."
    yesno "Download platform-tools now?" y || return 1
    zip="$PLATFORM_DIR/platform-tools.zip"
    curl -fL "$CURL_PROGRESS" -o "$zip" "$url" || return 1
    rm -rf "$PLATFORM_DIR/platform-tools"
    unzip -q -o "$zip" -d "$PLATFORM_DIR" || return 1
    mkdir -p "$PLATFORM_DIR/adb"
    cp -R "$PLATFORM_DIR/platform-tools/." "$PLATFORM_DIR/adb/"
    rm -rf "$PLATFORM_DIR/platform-tools" "$zip"
    chmod +x "$bundled"
    ADB="$bundled"
    "$ADB" version >/dev/null 2>&1
}

# ------------------------------------------------------------
# Device helpers
# ------------------------------------------------------------
adbt() { "$ADB" -s "$TARGET" "$@"; }

# Run a device shell command; prints combined output with CRs stripped and logs it.
dsh() {
    local out
    out="$(adbt shell "$@" 2>&1 | tr -d '\r')"
    log "[adb shell] $* => $out"
    printf '%s\n' "$out"
}

# Push a script to the device and run it there (avoids command-length limits).
dsh_script() {
    local tmp
    tmp="$(mktemp "${TMPDIR:-/tmp}/fsc.XXXXXX")"
    printf '%s\n' "$1" > "$tmp"
    adbt push "$tmp" "$DEVICE_TMP/fsc_script.sh" >/dev/null 2>&1
    rm -f "$tmp"
    log "[adb script] $1"
    dsh sh "$DEVICE_TMP/fsc_script.sh"
    adbt shell rm -f "$DEVICE_TMP/fsc_script.sh" >/dev/null 2>&1
}

device_state() {
    "$ADB" devices 2>/dev/null | awk -v t="$TARGET" '$1 == t { print $2 }'
}

# Polls until the device is connected and authorized. $1 = timeout seconds.
wait_for_device() {
    local timeout="${1:-120}" waited=0 state hinted=0
    while [ "$waited" -lt "$timeout" ]; do
        "$ADB" connect "$TARGET" >/dev/null 2>&1
        state="$(device_state)"
        case "$state" in
            device)
                if adbt shell echo fsc_ok 2>/dev/null | grep -q fsc_ok; then
                    return 0
                fi ;;
            unauthorized)
                if [ "$hinted" -eq 0 ]; then
                    say ""
                    say "  Look at your TV: select 'Always allow from this computer' and press OK."
                    hinted=1
                fi ;;
        esac
        sleep 2
        waited=$((waited + 2))
    done
    return 1
}

connect_device() {
    banner "STEP 1: Connecting to Fire TV at $TARGET"
    "$ADB" disconnect >/dev/null 2>&1
    info "Sending connection request (accept the prompt on your TV if it appears)..."
    if wait_for_device 120; then
        ok "Connected to $TARGET"
        printf '%s\n' "$FIRE_IP" > "$LAST_IP_FILE" 2>/dev/null
        return 0
    fi
    err "Could not connect. Make sure:"
    say "      1. Fire TV and this computer are on the same network"
    say "      2. ADB Debugging is enabled (Settings > My Fire TV > Developer Options)"
    say "      3. You accepted the connection prompt on the TV screen"
    return 1
}

# Best effort: ask Fire OS to keep ADB debugging enabled across the reboot.
keep_adb_on() {
    dsh settings put global adb_enabled 1 >/dev/null
    dsh settings put global adb_wifi_enabled 1 >/dev/null
}

reboot_and_reconnect() {
    # The package manager persists package state asynchronously; rebooting straight after
    # a batch of pm commands loses the last few changes.
    info "Letting the Fire TV save its package state..."
    sleep 15
    keep_adb_on
    info "Rebooting Fire TV..."
    adbt shell reboot >/dev/null 2>&1
    sleep 20
    if wait_for_device 180; then
        sleep 5
        ok "Device is back online"
        return 0
    fi
    # Some Fire OS builds switch ADB debugging off at boot; let the user turn it back on.
    while :; do
        warn "The Fire TV did not come back on ADB. Fire OS can switch ADB Debugging off at boot."
        say "      On the TV: Settings > My Fire TV > Developer Options > ADB Debugging > ON"
        say "      (then accept the 'Allow USB debugging' prompt again if it appears)"
        if [ "$NONINTERACTIVE" -eq 1 ]; then
            info "Waiting up to 5 more minutes for ADB to come back..."
            if wait_for_device 300; then sleep 5; ok "Device is back online"; return 0; fi
            return 1
        fi
        yesno "ADB Debugging is on again; try to reconnect?" y || return 1
        if wait_for_device 120; then sleep 5; ok "Device is back online"; return 0; fi
    done
}

# Reads Android/Fire OS version and CPU ABIs; used to pick matching APK variants.
read_device_info() {
    DEV_SDK="$(dsh getprop ro.build.version.sdk | tr -dc '0-9')"
    DEV_SDK="${DEV_SDK:-0}"
    DEV_RELEASE="$(dsh getprop ro.build.version.release | tr -d ' ')"
    DEV_FIREOS="$(dsh getprop ro.build.version.fireos | tr -d ' ')"
    DEV_ABIS="$(dsh getprop ro.product.cpu.abilist | tr -d ' ')"
    [ -n "$DEV_ABIS" ] || DEV_ABIS="$(dsh getprop ro.product.cpu.abi | tr -d ' ')"
    DEV_MODEL="$(dsh getprop ro.product.model)"
    ok "Device: ${DEV_MODEL:-unknown model}, Fire OS ${DEV_FIREOS:-?} (Android ${DEV_RELEASE:-?}, API $DEV_SDK), CPU: ${DEV_ABIS:-?}"
    log "[DEVICE] sdk=$DEV_SDK release=$DEV_RELEASE fireos=$DEV_FIREOS abis=$DEV_ABIS model=$DEV_MODEL"
}

# Sets MEM_TOTAL, MEM_AVAIL (MB) and PROCS (Amazon process count).
capture_mem() {
    local total avail
    total="$(dsh "grep MemTotal /proc/meminfo" | awk '{print $2}')"
    avail="$(dsh "grep MemAvailable /proc/meminfo" | awk '{print $2}')"
    MEM_TOTAL=$(( ${total:-0} / 1024 ))
    MEM_AVAIL=$(( ${avail:-0} / 1024 ))
    PROCS="$(dsh "(ps -A 2>/dev/null || ps) | grep -c com.amazon" | tr -dc '0-9')"
    PROCS="${PROCS:-0}"
}

# Appends a component to a colon-separated secure setting, recording the
# original value in the state file the first time. $1 setting, $2 component, $3 package
enable_secure_list() {
    local setting="$1" comp="$2" pkg="$3" cur new
    cur="$(dsh settings get secure "$setting")"
    [ "$cur" = "null" ] && cur=""
    state_has "prev_$setting" || state_put "prev_$setting" "$cur"
    case ":$cur:" in
        *"/$pkg"*|*":$pkg/"*) new="$cur" ;;
        "::")                 new="$comp" ;;
        *)                    new="$cur:$comp" ;;
    esac
    [ "$new" = "$cur" ] || dsh settings put secure "$setting" "$new" >/dev/null
}

restore_secure_setting() {
    local setting="$1" prev
    if state_has "prev_$setting"; then
        prev="$(state_get "prev_$setting")"
        if [ -z "$prev" ]; then
            dsh settings delete secure "$setting" >/dev/null
        else
            dsh settings put secure "$setting" "$prev" >/dev/null
        fi
    else
        dsh settings delete secure "$setting" >/dev/null
    fi
}

# ------------------------------------------------------------
# APK download / install / configure (driven by launchers.conf)
# ------------------------------------------------------------
human_size() {
    if [ "$1" -ge 1048576 ]; then echo "$(( $1 / 1048576 )) MB"; else echo "$(( $1 / 1024 )) KB"; fi
}

sha256_of() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 "$1" | awk '{print $1}'
    else echo ""; fi
}

sha256_stdin() {
    if command -v sha256sum >/dev/null 2>&1; then sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then shasum -a 256 | awk '{print $1}'
    else cat >/dev/null; echo ""; fi
}

filesize() { stat -f%z "$1" 2>/dev/null || stat -c%s "$1" 2>/dev/null || echo 0; }

# verify_apk <file> [expected signing-cert sha256]
# Checks the file is a zip and, when the APK carries a v1 signature, that the signing
# certificate matches. Android itself verifies the signature again on install.
verify_apk() {
    local f="$1" want="${2:-}" entry got
    if [ "$(head -c 2 "$f" 2>/dev/null)" != "PK" ]; then
        err "$(basename "$f") is not an APK (not a zip file)."
        return 1
    fi
    [ -n "$want" ] || return 0
    entry="$(unzip -Z1 "$f" 2>/dev/null | grep -iE '^META-INF/[^/]*\.(RSA|DSA|EC)$' | head -1)"
    if [ -z "$entry" ]; then
        info "APK has no v1 signature block; the signing certificate cannot be checked here."
        return 0
    fi
    got="$(unzip -p "$f" "$entry" 2>/dev/null | openssl pkcs7 -inform DER -print_certs 2>/dev/null \
        | openssl x509 -outform DER 2>/dev/null | sha256_stdin)"
    if [ -z "$got" ]; then
        info "Could not read the signing certificate; skipping the check."
        return 0
    fi
    if [ "$got" != "$want" ]; then
        err "Signing certificate mismatch (expected $want, got $got). Refusing to install."
        return 1
    fi
    ok "Signing certificate matches APKMirror's record for this app"
}

open_url() {
    if [ -n "${FSC_BROWSER:-}" ]; then
        "$FSC_BROWSER" "$1" >/dev/null 2>&1 &
        return 0
    fi
    case "$(uname)" in
        Darwin) open "$1" ;;
        *) xdg-open "$1" >/dev/null 2>&1 || say "  Open this URL in a browser: $1" ;;
    esac
}

# wait_for_download <package> <marker-file> <timeout-s>
# Prints the path of a new, complete <package>_*.apk in the watched folders.
wait_for_download() {
    local pkg="$1" marker="$2" timeout="$3" waited=0 f size1 size2
    while [ "$waited" -lt "$timeout" ]; do
        f="$(find "$DOWNLOADS_WATCH" "$PLATFORM_DIR" -maxdepth 1 -name "${pkg}_*.apk" -newer "$marker" 2>/dev/null | head -1)"
        if [ -n "$f" ]; then
            size1="$(filesize "$f")"
            sleep 2
            size2="$(filesize "$f")"
            if [ "$size1" = "$size2" ] && [ "$size1" -gt 100000 ] && [ ! -e "$f.crdownload" ] && [ ! -e "$f.part" ]; then
                printf '%s\n' "$f"
                return 0
            fi
        fi
        sleep 2
        waited=$((waited + 4))
    done
    return 1
}

apkmirror_api_json() {
    if [ -n "${FSC_APKMIRROR_JSON:-}" ]; then cat "$FSC_APKMIRROR_JSON"; return; fi
    curl -fsSL -X POST "$APKMIRROR_API" -H "Authorization: $APKMIRROR_AUTH" -H 'User-Agent: APKUpdater-v3.0.3' \
        -H 'Content-Type: application/json' -d "{\"pnames\":[\"$1\"]}"
}

# apkmirror_lookup <package>
# Picks the newest variant that fits this device (min API <= device API, matching CPU) and
# sets AM_VERSION AM_VCODE AM_MINAPI AM_ARCHES AM_SHA256 AM_PAGE.
apkmirror_lookup() {
    local pkg="$1" json apks best
    json="$(apkmirror_api_json "$pkg" 2>/dev/null | sed 's#\\/#/#g')" || return 1
    printf '%s' "$json" | grep -q '"exists":true' || return 1
    AM_VERSION="$(printf '%s' "$json" | sed -n 's/.*"release":{"version":"\([^"]*\)".*/\1/p')"
    apks="$(printf '%s' "$json" | sed -n 's/.*"apks":\[\(.*\)\]}\]}[[:space:]]*$/\1/p' | awk '{ gsub(/\},\{/, "}\n{"); print }')"
    best="$(printf '%s\n' "$apks" | awk -v sdk="$DEV_SDK" -v abis="$DEV_ABIS" '
        function str(s, k,   m) {
            if (match(s, "\"" k "\":\"[^\"]*\"")) { m = substr(s, RSTART, RLENGTH); sub(/^"[^"]*":"/, "", m); sub(/"$/, "", m); return m }
            return ""
        }
        function arr(s, k,   m) {
            if (match(s, "\"" k "\":\\[[^]]*\\]")) { m = substr(s, RSTART, RLENGTH); sub(/^"[^"]*":\[/, "", m); sub(/\]$/, "", m); gsub(/"/, "", m); return m }
            return ""
        }
        {
            minapi = str($0, "minapi") + 0
            if (sdk > 0 && minapi > sdk) next
            n = split(arr($0, "arches"), a, ",")
            fits = (n == 0); arm64 = 0
            for (i = 1; i <= n; i++) {
                if (a[i] == "universal" || a[i] == "noarch" || index("," abis ",", "," a[i] ",") > 0) {
                    fits = 1
                    if (a[i] == "arm64-v8a") arm64 = 1
                }
            }
            if (!fits) next
            score = minapi * 10 + arm64 * 5 + (index(arr($0, "dpis"), "nodpi") > 0)
            if (score > best) { best = score; line = $0 }
        }
        END { print line }')"
    [ -n "$best" ] || return 1
    AM_VCODE="$(printf '%s' "$best" | sed -n 's/.*"version_code":"\([^"]*\)".*/\1/p')"
    AM_MINAPI="$(printf '%s' "$best" | sed -n 's/.*"minapi":"\([^"]*\)".*/\1/p')"
    AM_ARCHES="$(printf '%s' "$best" | sed -n 's/.*"arches":\[\([^]]*\)\].*/\1/p' | tr -d '"')"
    AM_SHA256="$(printf '%s' "$best" | sed -n 's/.*"signatures-sha256":\["\([0-9a-f]*\)".*/\1/p')"
    AM_PAGE="https://www.apkmirror.com$(printf '%s' "$best" | sed -n 's/.*"link":"\([^"]*\)".*/\1/p')"
    [ -n "$AM_VCODE" ] && [ -n "$AM_PAGE" ]
}

# apkmirror_fetch <section> <package> -> sets APK_FILE (and EXPECTED_VCODE)
apkmirror_fetch() {
    local sec="$1" pkg="$2" name page marker found f
    name="$(lconf "$sec" name)"
    info "Looking up $name on APKMirror for Android API $DEV_SDK (${DEV_ABIS:-unknown CPU})..."
    if apkmirror_lookup "$pkg"; then
        ok "Latest: $name $AM_VERSION (build $AM_VCODE, min API $AM_MINAPI, $AM_ARCHES)"
        page="$AM_PAGE"
        mkdir -p "$DOWNLOAD_DIR"
        for f in "$DOWNLOAD_DIR/${pkg}_"*"-${AM_VCODE}_"*.apk "$DOWNLOAD_DIR/${pkg}_"*"-${AM_VCODE}.apk"; do
            if [ -f "$f" ]; then
                APK_FILE="$f"
                EXPECTED_VCODE="$AM_VCODE"
                ok "Already downloaded: $(basename "$f")"
                return 0
            fi
        done
    else
        warn "Could not query APKMirror; you will have to pick a version yourself (min Android API $DEV_SDK or lower)."
        page="$(lconf "$sec" page)"
        AM_VERSION=""; AM_VCODE=""; AM_SHA256=""
        [ -n "$page" ] || { err "No APKMirror page configured for $name."; return 1; }
    fi
    if [ "$NONINTERACTIVE" -eq 1 ]; then
        err "APKMirror does not allow scripted downloads. Save the ${pkg}_*.apk file in $PLATFORM_DIR and run again."
        return 1
    fi
    say ""
    say "  APKMirror does not let scripts download files, so your browser will open on the"
    say "  download page for $name${AM_VERSION:+ $AM_VERSION} that matches this Fire TV."
    say "  Click 'DOWNLOAD APK' there (and the 'here' link if nothing starts)."
    say "  Watching $DOWNLOADS_WATCH and $PLATFORM_DIR for the file..."
    marker="$(mktemp "${TMPDIR:-/tmp}/fsc.XXXXXX")"
    open_url "$page"
    found="$(wait_for_download "$pkg" "$marker" 900)"
    rm -f "$marker"
    if [ -z "$found" ]; then
        err "No ${pkg}_*.apk appeared within 15 minutes. Save it in $PLATFORM_DIR and run again."
        return 1
    fi
    mkdir -p "$DOWNLOAD_DIR"
    APK_FILE="$DOWNLOAD_DIR/$(basename "$found")"
    [ "$found" = "$APK_FILE" ] || mv -f "$found" "$APK_FILE"
    ok "Got $(basename "$APK_FILE") ($(human_size "$(filesize "$APK_FILE")"))"
    verify_apk "$APK_FILE" "$AM_SHA256" || return 1
    EXPECTED_VCODE="$AM_VCODE"
}

# gh_latest owner/repo [asset-glob] -> sets GH_URL, GH_SHA (may be empty) and GH_ASSET
# The glob may contain {abi}; it is tried with each device ABI, then "universal".
gh_latest() {
    local repo="$1" pattern="${2:-*.apk}" json assets cand abi name sha url
    json="$(curl -fsSL -H 'User-Agent: firestick-cleanup' "https://api.github.com/repos/$repo/releases/latest" 2>/dev/null)" || return 1
    # One "name<TAB>sha256<TAB>url" line per asset, in release order.
    assets="$(printf '%s' "$json" \
        | grep -o '"name": *"[^"]*"\|"digest": *\("sha256:[0-9a-f]*"\|null\)\|"browser_download_url": *"[^"]*"' \
        | awk -F'"' '
            /^"name"/ { name = $4; digest = ""; next }
            /^"digest"/ { digest = ($0 ~ /sha256:/) ? $4 : ""; sub(/^sha256:/, "", digest); next }
            /^"browser_download_url"/ { print name "\t" digest "\t" $4 }')"
    GH_URL=""; GH_SHA=""; GH_ASSET=""
    for abi in $(printf '%s' "$DEV_ABIS" | tr ',' ' ') universal; do
        cand="$(printf '%s' "$pattern" | sed "s/{abi}/$abi/g")"
        while IFS=$'\t' read -r name sha url; do
            [ -n "$name" ] || continue
            # shellcheck disable=SC2254  # $cand is meant to be a glob
            case "$name" in
                $cand)
                    GH_ASSET="$name"; GH_SHA="$sha"; GH_URL="$url"
                    return 0 ;;
            esac
        done <<EOF
$assets
EOF
        printf '%s' "$pattern" | grep -q '{abi}' || break
    done
    return 1
}

# fetch_apk <section> -> sets APK_FILE, returns 1 on failure
fetch_apk() {
    local sec="$1" source name glob f url sha got size
    name="$(lconf "$sec" name)"
    source="$(lconf "$sec" source)"
    EXPECTED_VCODE=""
    for glob in $(lconf "$sec" apk_glob); do
        for f in "$PLATFORM_DIR"/$glob; do
            if [ -f "$f" ]; then
                APK_FILE="$f"
                ok "Using local APK: $(basename "$f")"
                return 0
            fi
        done
    done
    case "$source" in
        github:*)
            info "Fetching latest $name release from GitHub..."
            if gh_latest "${source#github:}" "$(lconf "$sec" asset_match)"; then
                url="$GH_URL"; sha="$GH_SHA"
                info "Release asset: $GH_ASSET"
            else
                url="$(lconf "$sec" fallback_url)"; sha=""
                [ -n "$url" ] || { err "Could not query GitHub releases for $name."; return 1; }
                warn "Could not query GitHub releases; using known-good fallback URL."
            fi
            mkdir -p "$DOWNLOAD_DIR"
            APK_FILE="$DOWNLOAD_DIR/$(basename "$url")"
            if [ -f "$APK_FILE" ] && [ -n "$sha" ] && [ "$(sha256_of "$APK_FILE")" = "$sha" ]; then
                ok "Already downloaded and verified: $(basename "$APK_FILE")"
                return 0
            fi
            info "Downloading $(basename "$url")"
            if ! curl -fL "$CURL_PROGRESS" -o "$APK_FILE" "$url"; then
                err "Download failed: $url"
                rm -f "$APK_FILE"
                return 1
            fi
            size="$(filesize "$APK_FILE")"
            if [ "$size" -lt 100000 ]; then
                err "Downloaded file is too small to be an APK."
                rm -f "$APK_FILE"
                return 1
            fi
            if [ -n "$sha" ]; then
                got="$(sha256_of "$APK_FILE")"
                if [ -n "$got" ] && [ "$got" != "$sha" ]; then
                    err "SHA-256 mismatch for $(basename "$APK_FILE"); discarding download."
                    rm -f "$APK_FILE"
                    return 1
                fi
                ok "Downloaded ($(human_size "$size")), SHA-256 verified"
            else
                ok "Downloaded ($(human_size "$size"))"
            fi
            return 0 ;;
        apkmirror:*)
            apkmirror_fetch "$sec" "${source#apkmirror:}" ;;
        manual:*)
            err "$name has to be downloaded by hand from ${source#manual:}"
            say "       Save the APK in: $PLATFORM_DIR"
            say "       Accepted file names: $(lconf "$sec" apk_glob)"
            return 1 ;;
        *)
            err "Unknown source '$source' for $name in launchers.conf"
            return 1 ;;
    esac
}

install_apk() {
    local sec="$1" apk="$2" pkg name out
    pkg="$(lconf "$sec" package)"
    name="$(lconf "$sec" name)"
    if dsh pm path "$pkg" | grep -q "package:"; then
        info "$name is already installed; updating in place."
    fi
    info "Pushing APK to device..."
    out="$(adbt push "$apk" "$DEVICE_TMP/fsc_install.apk" 2>&1)"
    log "$out"
    if ! printf '%s' "$out" | grep -q "pushed"; then
        err "Failed to push APK: $out"
        return 1
    fi
    info "Installing..."
    out="$(dsh pm install -r "$DEVICE_TMP/fsc_install.apk")"
    adbt shell rm -f "$DEVICE_TMP/fsc_install.apk" >/dev/null 2>&1
    if ! printf '%s' "$out" | grep -q "Success"; then
        err "Install failed: $out"
        return 1
    fi
    if ! dsh pm path "$pkg" | grep -q "package:"; then
        err "Install reported success but $pkg is not on the device."
        return 1
    fi
    ok "$name installed"
    if [ -n "$EXPECTED_VCODE" ]; then
        out="$(dsh dumpsys package "$pkg" | sed -n 's/.*versionCode=\([0-9]*\).*/\1/p' | head -1)"
        if [ -n "$out" ] && [ "$out" != "$EXPECTED_VCODE" ]; then
            warn "Installed build $out differs from the expected build $EXPECTED_VCODE"
        elif [ -n "$out" ]; then
            ok "Installed build $out"
        fi
        EXPECTED_VCODE=""
    fi
    state_add_unique installed "$pkg"
}

launch_app() {
    local sec="$1" act out
    act="$(lconf "$sec" activity)"
    if [ -n "$act" ]; then
        out="$(dsh am start -n "$act")"
        if ! printf '%s' "$out" | grep -q "Error"; then
            ok "$(lconf "$sec" name) launched"
            return 0
        fi
    fi
    # No activity configured, or it failed: resolve the app's leanback launcher entry instead.
    out="$(dsh monkey -p "$(lconf "$sec" package)" -c android.intent.category.LEANBACK_LAUNCHER 1)"
    if printf '%s' "$out" | grep -q "Events injected"; then
        ok "$(lconf "$sec" name) launched"
    else
        warn "Could not launch $(lconf "$sec" name) automatically; open it from the Fire TV app list."
    fi
}

# Disables the packages an add-on replaces (its "disables=" line), recording them for revert.
disable_replaced_packages() {
    local sec="$1" p pkgs="" status disabled_now
    [ -n "$(lconf "$sec" disables)" ] || return 0
    disabled_now="$(dsh pm list packages -d)"
    for p in $(lconf "$sec" disables); do
        if printf '%s\n' "$disabled_now" | grep -qx "package:$p"; then
            info "$p is already disabled"
        elif dsh pm path "$p" | grep -q "package:"; then
            pkgs="$pkgs $p"
        else
            info "$p is not on this device"
        fi
    done
    [ -n "$(printf '%s' "$pkgs" | tr -d ' ')" ] || return 0
    while IFS=$'\t' read -r p status; do
        [ -n "$p" ] || continue
        if [ "$status" = disabled ]; then
            ok "Disabled: $p (replaced by $(lconf "$sec" name))"
            state_add_unique disabled "$p"
        else
            warn "Could not disable $p ($status)"
        fi
    done <<EOF
$(disable_batch "$pkgs")
EOF
}

configure_app() {
    local sec="$1" pkg act acc nl p
    pkg="$(lconf "$sec" package)"
    act="$(lconf "$sec" activity)"
    acc="$(lconf "$sec" accessibility)"
    nl="$(lconf "$sec" notification_listener)"

    for p in $(lconf "$sec" grant); do
        dsh pm grant "$pkg" "$p" >/dev/null
        ok "Granted ${p##*.}"
    done
    if [ -n "$acc" ]; then
        enable_secure_list enabled_accessibility_services "$acc" "$pkg"
        dsh settings put secure accessibility_enabled 1 >/dev/null
        if dsh settings get secure enabled_accessibility_services | grep -q "$pkg"; then
            ok "Accessibility service enabled"
        else
            err "Could not enable the accessibility service for $pkg"
            return 1
        fi
    fi
    if [ -n "$nl" ]; then
        enable_secure_list enabled_notification_listeners "$nl" "$pkg"
        ok "Notification listener enabled"
    fi
    for p in $(lconf "$sec" appops); do
        dsh appops set "$pkg" "$p" allow >/dev/null
        ok "App op $p allowed"
    done
    if [ "$(lconf "$sec" boot)" = yes ]; then
        prepare_boot "$sec"
    fi
    if [ "$(lconf "$sec" type)" = launcher ]; then
        dsh cmd role add-role-holder android.app.role.HOME "$pkg" >/dev/null
        ok "HOME role assigned"
        dsh cmd package set-home-activity --user 0 "$act" >/dev/null
        ok "Default home activity set"
    fi
    disable_replaced_packages "$sec"
    launch_app "$sec"
}

# Keeps an app's boot receiver and accessibility service from being throttled: doze
# whitelist, background execution allowed, "active" standby bucket. Best effort per firmware.
prepare_boot() {
    local pkg
    pkg="$(lconf "$1" package)"
    dsh dumpsys deviceidle whitelist "+$pkg" >/dev/null
    dsh appops set "$pkg" RUN_IN_BACKGROUND allow >/dev/null
    dsh appops set "$pkg" RUN_ANY_IN_BACKGROUND allow >/dev/null
    dsh am set-standby-bucket "$pkg" active >/dev/null
    if dsh dumpsys deviceidle whitelist | grep -q "$pkg"; then
        ok "Allowed to run at boot and in the background"
    else
        info "Could not add $pkg to the doze whitelist (not supported on this firmware)"
    fi
}

# Package holding the HOME role. Android 12+ has get-role-holders; older firmware
# (Fire OS 8 is Android 11) is asked which app resolves the HOME intent instead.
home_role_holder() {
    local out
    out="$(dsh cmd role get-role-holders android.app.role.HOME)"
    case "$out" in
        ""|*"Unknown command"*|*Error*|*Exception*)
            # Android 11: read the role dump ("name=android.app.role.HOME" then "holders=pkg").
            out="$(dsh dumpsys role | awk '/name=android.app.role.HOME$/ { f = 1; next } f && /holders=/ { sub(/.*holders=/, ""); print; exit }')" ;;
    esac
    printf '%s\n' "$out" | sed 's#[/;,].*##' | head -1
}

# Package name of the window that currently has focus, or empty.
foreground_pkg() {
    local line
    line="$(dsh "dumpsys window 2>/dev/null | grep -m1 mCurrentFocus")"
    [ -n "$line" ] || line="$(dsh "dumpsys activity activities 2>/dev/null | grep -m1 mResumedActivity")"
    printf '%s' "$line" | sed -n 's/.* u[0-9]* \([A-Za-z0-9_.]*\)\/.*/\1/p' | head -1
}

# verify_boot <launcher-section> [addon-sections...]
# After the reboot: waits for boot to complete, checks that the launcher and every
# boot add-on is running, and tests the Home-button redirect if Amazon's home is in front.
verify_boot() {
    local launcher="$1" sec pkg name fg waited=0 count
    shift
    banner "STEP 8: Checking what starts at boot"
    while [ "$waited" -lt 90 ] && [ "$(dsh getprop sys.boot_completed | tr -dc '0-9')" != "1" ]; do
        sleep 3
        waited=$((waited + 3))
    done
    sleep 10
    for sec in "$launcher" "$@"; do
        [ "$(lconf "$sec" boot)" = yes ] || continue
        pkg="$(lconf "$sec" package)"
        name="$(lconf "$sec" name)"
        count="$(dsh "(ps -A 2>/dev/null || ps) | grep -c $pkg" | tr -dc '0-9')"
        if [ "${count:-0}" -gt 0 ]; then
            ok "$name is running after boot"
        else
            warn "$name is not running after boot"
        fi
    done
    pkg="$(lconf "$launcher" package)"
    name="$(lconf "$launcher" name)"
    fg="$(foreground_pkg)"
    if [ "$fg" = "$pkg" ]; then
        ok "On screen after boot: $name"
        return 0
    fi
    info "On screen after boot: ${fg:-unknown}. Pressing Home to test the redirect..."
    dsh input keyevent 3 >/dev/null
    sleep 7
    fg="$(foreground_pkg)"
    if [ "$fg" = "$pkg" ]; then
        ok "After pressing Home: $name takes over"
    else
        warn "After pressing Home: ${fg:-unknown} is still in front."
        say "      On the TV, check: Home on Fire > 'Choose target app' is set and 'Launch on boot' is on;"
        say "      Projectivy > Settings > General > 'Override current launcher' (OFF if you use Home on Fire)."
    fi
}

show_notes() {
    local sec="$1" line
    say ""
    say "  +---------------------------------------------------------+"
    say "  |  ACTION REQUIRED on your Fire TV ($(lconf "$sec" name))"
    say "  |"
    while IFS= read -r line; do
        [ -n "$line" ] && say "  |  $line"
    done <<EOF
$(lconf "$sec" note)
EOF
    say "  +---------------------------------------------------------+"
    say ""
    pause "Press Enter when done..."
}

# Downloads, installs, configures and launches one app from launchers.conf.
setup_app() {
    local sec="$1"
    banner "Installing $(lconf "$sec" name)"
    fetch_apk "$sec" || return 1
    install_apk "$sec" "$APK_FILE" || return 1
    configure_app "$sec" || return 1
    show_notes "$sec"
}

# ------------------------------------------------------------
# Package disabling
# ------------------------------------------------------------
# disable_batch "pkg1 pkg2 ..." -> prints "pkg<TAB>status" per package
# status: disabled | protected | failed: <message>
disable_batch() {
    local script="" p
    for p in $1; do
        script="$script
echo \"FSC $p \$(pm disable-user --user 0 $p 2>&1)\""
    done
    dsh_script "$script" | awk '
        /^FSC / {
            pkg = $2; msg = $0; sub(/^FSC [^ ]+ ?/, "", msg)
            if (msg ~ /disabled-user/)                 st = "disabled"
            else if (msg ~ /SecurityException|rotected/) st = "protected"
            else                                        st = "failed: " msg
            print pkg "\t" st
        }'
}

enable_batch() {
    local script="" p
    for p in $1; do
        script="$script
echo \"FSC $p \$(pm enable --user 0 $p 2>&1)\""
    done
    dsh_script "$script" | awk '/^FSC / { print $2 "\t" ($0 ~ /enabled/ ? "enabled" : "failed") }'
}

# Runs up to three disable passes over $1 (space-separated packages).
# Sets TOTAL_DISABLED, TOTAL_PROTECTED, PASSES.
run_disable_passes() {
    local remaining="$1" pass=0 next pkg status pass_disabled pass_protected
    TOTAL_DISABLED=0
    TOTAL_PROTECTED=0
    while :; do
        pass=$((pass + 1))
        pass_disabled=0
        pass_protected=0
        next=""
        banner "STEP 6: Disabling bloatware (pass $pass)"
        while IFS=$'\t' read -r pkg status; do
            [ -n "$pkg" ] || continue
            case "$status" in
                disabled)
                    ok "Disabled: $pkg"
                    state_add_unique disabled "$pkg"
                    pass_disabled=$((pass_disabled + 1)) ;;
                protected)
                    warn "Protected: $pkg"
                    pass_protected=$((pass_protected + 1))
                    next="$next $pkg" ;;
                *)
                    warn "Failed: $pkg ($status)" ;;
            esac
        done <<EOF
$(disable_batch "$remaining")
EOF
        TOTAL_DISABLED=$((TOTAL_DISABLED + pass_disabled))
        TOTAL_PROTECTED=$pass_protected
        say ""
        say "  Pass $pass: disabled $pass_disabled, protected $pass_protected"
        if [ "$pass_disabled" -gt 0 ] && [ "$pass_protected" -gt 0 ] && [ "$pass" -lt 3 ]; then
            info "Some packages are protected; rebooting to retry them..."
            if reboot_and_reconnect; then
                remaining="$next"
                continue
            fi
            warn "Could not reconnect after reboot; continuing with what we have."
        fi
        break
    done
    PASSES=$pass
}

# Re-disables anything from the state file that is enabled again. Sets REAPPLIED.
reapply_disabled() {
    local disabled_now want="" p count=0
    REAPPLIED=0
    disabled_now="$(dsh pm list packages -d | sed 's/^package://')"
    for p in $(state_get disabled); do
        printf '%s\n' "$disabled_now" | grep -qx "$p" || want="$want $p"
    done
    [ -n "$want" ] || return 0
    count="$(disable_batch "$want" | grep -c $'\tdisabled$')"
    REAPPLIED="${count:-0}"
}

# ------------------------------------------------------------
# Interactive choices
# ------------------------------------------------------------
ask_ip() {
    local last=""
    [ -f "$LAST_IP_FILE" ] && last="$(head -1 "$LAST_IP_FILE")"
    while [ -z "$FIRE_IP" ]; do
        if [ "$NONINTERACTIVE" -eq 1 ]; then
            die "--non-interactive needs --ip <address>."
        fi
        if [ -n "$last" ]; then
            read -r -p "  Enter your Fire TV IP address [$last]: " FIRE_IP || FIRE_IP=""
            [ -z "$FIRE_IP" ] && FIRE_IP="$last"
        else
            read -r -p "  Enter your Fire TV IP address (e.g. 10.0.0.20): " FIRE_IP || FIRE_IP=""
        fi
        FIRE_IP="$(printf '%s' "$FIRE_IP" | tr -d '[:space:]')"
        case "$FIRE_IP" in
            *:*) PORT="${FIRE_IP##*:}"; FIRE_IP="${FIRE_IP%%:*}" ;;
        esac
        if ! printf '%s' "$FIRE_IP" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$|^[A-Za-z0-9][A-Za-z0-9.-]*$'; then
            err "'$FIRE_IP' is not a valid IP address or host name."
            FIRE_IP=""
        fi
    done
    TARGET="$FIRE_IP:$PORT"
    STATE_FILE="$PLATFORM_DIR/firestick_cleanup_$FIRE_IP.state"
    log "[CONFIG] target=$TARGET state=$STATE_FILE"
}

choose_launcher() {
    local keys=() names=() i=1 k choice
    if [ -n "$LAUNCHER_KEY" ]; then
        [ "$(lconf "$LAUNCHER_KEY" type)" = launcher ] || die "Unknown launcher '$LAUNCHER_KEY'. Known: $(launcher_keys | tr '\n' ' ')"
        return
    fi
    if [ "$NONINTERACTIVE" -eq 1 ]; then
        LAUNCHER_KEY=projectivy
        return
    fi
    banner "STEP 2: Choose a launcher"
    for k in $(launcher_keys); do
        keys+=("$k")
        names+=("$(lconf "$k" name)")
        printf '  %d) %-20s %s\n' "$i" "$(lconf "$k" name)" "$(lconf "$k" summary)"
        i=$((i + 1))
    done
    say ""
    while :; do
        read -r -p "  Launcher [1]: " choice || choice=""
        [ -z "$choice" ] && choice=1
        if printf '%s' "$choice" | grep -Eq '^[0-9]+$' && [ "$choice" -ge 1 ] && [ "$choice" -le "${#keys[@]}" ]; then
            LAUNCHER_KEY="${keys[$((choice - 1))]}"
            break
        fi
        say "  Enter a number between 1 and ${#keys[@]}."
    done
    ok "Launcher: ${names[$((choice - 1))]}"
}

# Sets CHOSEN_ADDONS (comma-separated add-on keys) from --with/--without, the
# launcher's "needs" list, each add-on's default, and Y/N prompts.
choose_addons() {
    local a def needs
    CHOSEN_ADDONS=""
    for a in $(csv_items "$ADDONS_WITH") $(csv_items "$ADDONS_WITHOUT"); do
        [ "$(lconf "$a" type)" = addon ] || die "Unknown add-on '$a'. Known: $(addon_keys | tr '\n' ' ')"
    done
    needs="$(lconf "$LAUNCHER_KEY" needs)"
    for a in $(addon_keys); do
        csv_has "$ADDONS_WITHOUT" "$a" && continue
        if csv_has "$ADDONS_WITH" "$a"; then
            CHOSEN_ADDONS="$(csv_add "$CHOSEN_ADDONS" "$a")"
            continue
        fi
        def=n
        [ "$(lconf "$a" default)" = yes ] && def=y
        case " $needs " in *" $a "*) def=y ;; esac
        if [ "$NONINTERACTIVE" -eq 1 ]; then
            [ "$def" = y ] && CHOSEN_ADDONS="$(csv_add "$CHOSEN_ADDONS" "$a")"
            continue
        fi
        say ""
        say "  $(lconf "$a" name): $(lconf "$a" summary)"
        if yesno "$(lconf "$a" prompt)" "$def"; then
            CHOSEN_ADDONS="$(csv_add "$CHOSEN_ADDONS" "$a")"
        fi
    done
}

# Sets CHOSEN_GROUPS (comma-separated group keys).
choose_groups() {
    local keys=() prompts=() i k p
    if [ "$NONINTERACTIVE" -eq 1 ]; then
        CHOSEN_GROUPS="$DISABLE_GROUPS"
        return
    fi
    banner "STEP 3: Choose what to disable"
    say ""
    say "  Tracking, telemetry, ads and background bloat are always disabled."
    say "  The following are optional. Answer Y to disable, N to keep."
    say ""
    while IFS=$'\t' read -r k p; do
        [ "$k" = always ] && continue
        keys+=("$k")
        prompts+=("$p")
    done <<EOF
$(conf_groups)
EOF
    CHOSEN_GROUPS=""
    i=0
    while [ "$i" -lt "${#keys[@]}" ]; do
        if yesno "${prompts[$i]}" n; then
            CHOSEN_GROUPS="${CHOSEN_GROUPS:+$CHOSEN_GROUPS,}${keys[$i]}"
        fi
        i=$((i + 1))
    done
}

validate_groups() {
    local g
    for g in $(printf '%s' "$1" | tr ',' ' '); do
        group_exists "$g" || die "Unknown group '$g'. Known: $(conf_groups | awk -F'\t' '$1 != "always" { printf "%s ", $1 }')"
    done
}

# Sets BLOAT (space-separated) from the always group plus CHOSEN_GROUPS.
build_bloat_list() {
    local g
    BLOAT="$(conf_packages always | tr '\n' ' ')"
    for g in $(printf '%s' "$CHOSEN_GROUPS" | tr ',' ' '); do
        BLOAT="$BLOAT $(conf_packages "$g" | tr '\n' ' ')"
    done
}

# Splits BLOAT into PRESENT (installed and enabled), ALREADY_DISABLED and ABSENT.
classify_bloat() {
    local all disabled p
    all="$(dsh pm list packages | sed 's/^package://')"
    disabled="$(dsh pm list packages -d | sed 's/^package://')"
    PRESENT=""; ALREADY_DISABLED=""; ABSENT=""
    for p in $BLOAT; do
        if printf '%s\n' "$disabled" | grep -qx "$p"; then
            ALREADY_DISABLED="$ALREADY_DISABLED $p"
        elif printf '%s\n' "$all" | grep -qx "$p"; then
            PRESENT="$PRESENT $p"
        else
            ABSENT="$ABSENT $p"
        fi
    done
}

count_words() { printf '%s' "$1" | wc -w | tr -d ' '; }

# ------------------------------------------------------------
# Modes
# ------------------------------------------------------------
do_status() {
    local k pkg acc role disabled
    banner "STATUS for $TARGET"
    acc="$(dsh settings get secure enabled_accessibility_services)"
    role="$(home_role_holder)"
    disabled="$(dsh pm list packages -d | sed 's/^package://')"
    for k in $(lconf_sections); do
        pkg="$(lconf "$k" package)"
        if dsh pm path "$pkg" | grep -q "package:"; then
            ok "$(lconf "$k" name): installed$( printf '%s' "$acc" | grep -q "$pkg" && printf ', accessibility service on')$( printf '%s' "$role" | grep -q "$pkg" && printf ', holds HOME role')"
        else
            warn "$(lconf "$k" name): not installed"
        fi
    done
    say ""
    say "  HOME role holder:        ${role:-unknown}"
    say "  Accessibility services:  ${acc:-none}"
    say "  Disabled packages:       $(printf '%s\n' "$disabled" | grep -c .)"
    printf '%s\n' "$disabled" | sed '/^$/d; s/^/      /'
    say ""
    if [ -f "$STATE_FILE" ]; then
        say "  Saved state ($STATE_FILE):"
        say "      launcher=$(state_get launcher) addons=$(state_get addons) groups=$(state_get groups)"
        say "      recorded as disabled by this tool: $(state_get disabled | grep -c .)"
    else
        say "  No saved state for this device (nothing recorded by this tool yet)."
    fi
}

do_revert() {
    local pkgs k pkg line stock="com.amazon.tv.launcher"
    banner "REVERTING CHANGES on $TARGET"
    if [ -f "$STATE_FILE" ]; then
        info "Using saved state: $STATE_FILE"
        pkgs="$(state_get disabled | tr '\n' ' ')"
    else
        warn "No saved state for this device. Falling back to re-enabling EVERY"
        warn "disabled package, including any you disabled yourself."
        yesno "Continue?" n || die "Revert cancelled."
        pkgs="$(dsh pm list packages -d | sed 's/^package://' | tr '\n' ' ')"
    fi

    if [ -n "$(printf '%s' "$pkgs" | tr -d ' ')" ]; then
        info "Re-enabling $(count_words "$pkgs") packages..."
        while IFS=$'\t' read -r pkg line; do
            [ -n "$pkg" ] || continue
            if [ "$line" = enabled ]; then ok "Enabled: $pkg"; else warn "Could not enable: $pkg"; fi
        done <<EOF
$(enable_batch "$pkgs")
EOF
    else
        info "No packages to re-enable."
    fi

    restore_secure_setting enabled_accessibility_services
    restore_secure_setting enabled_notification_listeners
    if ! dsh settings get secure enabled_accessibility_services | grep -qv '^null$'; then
        dsh settings put secure accessibility_enabled 0 >/dev/null
    fi
    ok "Accessibility and notification listener settings restored"

    if [ -f "$STATE_FILE" ]; then
        pkgs="$(state_get installed | tr '\n' ' ')"
    else
        pkgs=""
        for k in $(lconf_sections); do pkgs="$pkgs $(lconf "$k" package)"; done
    fi
    for pkg in $pkgs; do
        dsh pm path "$pkg" | grep -q "package:" || continue
        dsh appops set "$pkg" SYSTEM_ALERT_WINDOW default >/dev/null
        dsh cmd role remove-role-holder android.app.role.HOME "$pkg" >/dev/null
        if dsh pm uninstall "$pkg" | grep -q Success; then
            ok "Uninstalled: $pkg"
        else
            warn "Could not uninstall $pkg"
        fi
    done
    dsh cmd role add-role-holder android.app.role.HOME "$stock" >/dev/null
    ok "HOME role returned to the Amazon launcher"

    rm -f "$STATE_FILE"
    banner "REVERT COMPLETE"
}

do_install() {
    local sec
    capture_mem
    local before_avail="$MEM_AVAIL" before_procs="$PROCS"
    say "  RAM: $MEM_AVAIL MB available of $MEM_TOTAL MB, $PROCS Amazon processes running"

    choose_launcher
    choose_addons
    choose_groups
    validate_groups "$CHOSEN_GROUPS"
    build_bloat_list
    classify_bloat

    if [ "$MODE" = dry-run ]; then
        banner "DRY RUN - nothing will be changed"
        say "  Launcher:        $(lconf "$LAUNCHER_KEY" name)"
        say "  Add-ons:         ${CHOSEN_ADDONS:-none}"
        say "  Optional groups: ${CHOSEN_GROUPS:-none}"
        say ""
        say "  Would disable ($(count_words "$PRESENT")):"
        for sec in $PRESENT; do say "      $sec"; done
        say "  Already disabled ($(count_words "$ALREADY_DISABLED")):"
        for sec in $ALREADY_DISABLED; do say "      $sec"; done
        say "  Not on this device ($(count_words "$ABSENT")):"
        for sec in $ABSENT; do say "      $sec"; done
        return 0
    fi

    state_set version "$VERSION"
    state_set launcher "$LAUNCHER_KEY"
    state_set addons "$CHOSEN_ADDONS"
    state_set groups "$CHOSEN_GROUPS"

    setup_app "$LAUNCHER_KEY" || die "Launcher setup failed."
    for sec in $(csv_items "$CHOSEN_ADDONS"); do
        setup_app "$sec" || die "$(lconf "$sec" name) setup failed."
    done

    if [ -n "$(printf '%s' "$PRESENT" | tr -d ' ')" ]; then
        run_disable_passes "$PRESENT"
    else
        TOTAL_DISABLED=0; TOTAL_PROTECTED=0; PASSES=0
        info "Nothing new to disable."
    fi
    [ -n "$(printf '%s' "$ABSENT" | tr -d ' ')" ] && info "$(count_words "$ABSENT") packages are not on this device and were skipped."

    if [ "$PASSES" -le 1 ]; then
        banner "Rebooting to apply changes"
        reboot_and_reconnect || die "Could not reconnect after reboot."
    fi
    reapply_disabled
    if [ "$REAPPLIED" -gt 0 ]; then
        ok "Re-disabled $REAPPLIED packages that came back after the reboot"
    else
        ok "All packages stayed disabled after the reboot"
    fi

    banner "STEP 7: Verifying"
    verify_app "$LAUNCHER_KEY"
    for sec in $(csv_items "$CHOSEN_ADDONS"); do verify_app "$sec"; done
    say "  [OK] $(dsh pm list packages -d | grep -c 'package:') packages are disabled on the device"
    # shellcheck disable=SC2046  # add-on keys are single words
    verify_boot "$LAUNCHER_KEY" $(csv_items "$CHOSEN_ADDONS")

    capture_mem
    banner "RAM: before vs after"
    printf '  %-20s %10s %10s\n' "" "BEFORE" "AFTER" | tee -a "$LOGFILE"
    printf '  %-20s %7d MB %7d MB   (+%d MB freed)\n' "Available RAM" "$before_avail" "$MEM_AVAIL" "$((MEM_AVAIL - before_avail))" | tee -a "$LOGFILE"
    printf '  %-20s %10d %10d   (-%d)\n' "Amazon processes" "$before_procs" "$PROCS" "$((before_procs - PROCS))" | tee -a "$LOGFILE"

    banner "ALL DONE"
    say "  Launcher:            $(lconf "$LAUNCHER_KEY" name)"
    say "  Add-ons:             ${CHOSEN_ADDONS:-none}"
    say "  Disabled this run:   $TOTAL_DISABLED (protected by Amazon: $TOTAL_PROTECTED)"
    say "  RAM freed:           $((MEM_AVAIL - before_avail)) MB"
    say ""
    say "  After a Fire OS update, re-apply with:  $(basename "$ENTRY") --ip $FIRE_IP --reapply -y"
    say "  To undo everything:                     $(basename "$ENTRY") --ip $FIRE_IP --revert"
    say "  State: $STATE_FILE"
}

verify_app() {
    local sec="$1" pkg name p
    pkg="$(lconf "$sec" package)"
    name="$(lconf "$sec" name)"
    if dsh pm path "$pkg" | grep -q "package:"; then ok "$name is installed"; else err "$name is NOT installed"; fi
    for p in $(lconf "$sec" grant); do
        if dsh dumpsys package "$pkg" | grep -q "$p: granted=true"; then
            ok "$name has ${p##*.}"
            continue
        fi
        # Grants made shortly before a reboot can be lost; grant again and re-check.
        dsh pm grant "$pkg" "$p" >/dev/null
        if dsh dumpsys package "$pkg" | grep -q "$p: granted=true"; then
            ok "$name has ${p##*.} (granted again; the first grant did not persist)"
        elif [ "$p" = android.permission.WRITE_SECURE_SETTINGS ] && [ -n "$(lconf "$sec" accessibility)" ]; then
            warn "${p##*.} cannot be granted on this firmware."
            say "      Not a problem: the accessibility service was enabled directly over adb instead;"
            say "      only the app's own in-app accessibility toggle needs that permission."
        else
            err "$name is missing ${p##*.} (grant it with: adb shell pm grant $pkg $p)"
        fi
    done
    if [ -n "$(lconf "$sec" accessibility)" ]; then
        if dsh settings get secure enabled_accessibility_services | grep -q "$pkg"; then
            ok "$name accessibility service is active"
        else
            err "$name accessibility service is NOT active"
        fi
    fi
    if [ "$(lconf "$sec" type)" = launcher ]; then
        if [ "$(home_role_holder)" = "$pkg" ]; then
            ok "$name holds the HOME role"
        else
            warn "$name does not hold the HOME role (expected on some firmware; the Home-button service still works)"
        fi
    fi
}

do_reapply() {
    banner "RE-APPLYING saved choices on $TARGET"
    if [ -f "$STATE_FILE" ]; then
        CHOSEN_GROUPS="$(state_get groups)"
        [ -n "$DISABLE_GROUPS" ] && CHOSEN_GROUPS="$DISABLE_GROUPS"
        info "Groups: ${CHOSEN_GROUPS:-none} (from $STATE_FILE)"
    else
        [ -n "$DISABLE_GROUPS" ] || [ "$NONINTERACTIVE" -eq 0 ] || die "No saved state for $FIRE_IP and no --disable given."
        if [ -z "$DISABLE_GROUPS" ]; then choose_groups; else CHOSEN_GROUPS="$DISABLE_GROUPS"; fi
    fi
    validate_groups "$CHOSEN_GROUPS"
    state_set groups "$CHOSEN_GROUPS"
    build_bloat_list
    classify_bloat
    if [ -n "$(printf '%s' "$PRESENT" | tr -d ' ')" ]; then
        run_disable_passes "$PRESENT"
        if [ "$PASSES" -le 1 ] && [ "$TOTAL_DISABLED" -gt 0 ]; then
            banner "Rebooting to apply changes"
            reboot_and_reconnect || die "Could not reconnect after reboot."
            reapply_disabled
        fi
    else
        TOTAL_DISABLED=0; TOTAL_PROTECTED=0
        ok "Everything is already disabled; nothing to do."
    fi
    local lk sec
    lk="$(state_get launcher)"
    if [ -n "$lk" ] && dsh pm path "$(lconf "$lk" package)" | grep -q "package:"; then
        configure_app "$lk" >/dev/null 2>&1 && ok "$(lconf "$lk" name) settings re-applied"
    fi
    for sec in $(csv_items "$(state_get addons)"); do
        if dsh pm path "$(lconf "$sec" package)" | grep -q "package:"; then
            configure_app "$sec" >/dev/null 2>&1 && ok "$(lconf "$sec" name) settings re-applied"
        fi
    done
    banner "RE-APPLY COMPLETE"
    say "  Disabled this run: $TOTAL_DISABLED (protected: $TOTAL_PROTECTED)"
}

do_test_boot() {
    local lk sec
    lk="$(state_get launcher)"
    [ -n "$lk" ] || die "No saved state for $FIRE_IP; run an install first."
    banner "BOOT TEST on $TARGET"
    reboot_and_reconnect || die "Could not reconnect after reboot."
    reapply_disabled
    if [ "$REAPPLIED" -gt 0 ]; then
        ok "Re-disabled $REAPPLIED packages that came back after the reboot"
    else
        ok "All packages stayed disabled after the reboot"
    fi
    verify_app "$lk"
    for sec in $(csv_items "$(state_get addons)"); do verify_app "$sec"; done
    # shellcheck disable=SC2046  # add-on keys are single words
    verify_boot "$lk" $(csv_items "$(state_get addons)")
}

# ------------------------------------------------------------
# Main
# ------------------------------------------------------------
main() {
    cd "$PLATFORM_DIR" || exit 1
    {
        echo "Firestick Cleanup $VERSION log - $(date)"
        echo "mode=$MODE platform_dir=$PLATFORM_DIR"
    } > "$LOGFILE"

    banner "Firestick Cleanup $VERSION"
    say "    Launcher replacement + debloat for Fire TV"
    say ""

    [ -f "$PACKAGES_CONF" ]  || die "Missing $PACKAGES_CONF"
    [ -f "$LAUNCHERS_CONF" ] || die "Missing $LAUNCHERS_CONF"
    find_adb || die "ADB is not available. Install Android platform-tools or put adb in $PLATFORM_DIR/adb/."
    ok "ADB: $ADB"

    ask_ip
    connect_device || die "Connection failed."
    read_device_info

    case "$MODE" in
        status)  do_status ;;
        revert)  do_revert ;;
        reapply) do_reapply ;;
        test-boot) do_test_boot ;;
        *)       do_install ;;
    esac

    say ""
    say "  Log saved to: $LOGFILE"
    pause "Press Enter to exit..."
}

main
