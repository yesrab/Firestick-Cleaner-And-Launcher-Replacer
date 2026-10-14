#!/usr/bin/env bash
# End-to-end test of common/firestick-cleanup.sh against a fake adb + fake Fire TV.
# No network and no device needed. Takes about a minute (reboot waits are real sleeps).
#
#   bash tests/run-e2e.sh
set -uo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fsc-e2e.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PLAT="$WORK/platform"
export FAKE_DEV="$WORK/device"
mkdir -p "$PLAT/adb" "$FAKE_DEV/bin"
cp "$ROOT/tests/fake-adb/adb" "$PLAT/adb/adb"
cp "$ROOT/tests/fake-adb/shims/"* "$FAKE_DEV/bin/"
: > "$FAKE_DEV/disabled"; : > "$FAKE_DEV/settings"; echo com.amazon.tv.launcher > "$FAKE_DEV/role"
printf '%s\n' com.amazon.tv.launcher com.amazon.tv.settings com.amazon.tv.acr com.amazon.hybridadidservice \
    com.amazon.perfc com.amazon.device.telemetry.emitter com.amazon.shoptv.client com.amazon.ftv.screensaver \
    com.amazon.tv.notificationcenter com.amazon.logan com.amazon.aria com.amazon.hedwig com.amazon.wifilocker \
    com.amazon.avls.experience com.amazon.prism.android.service com.amazon.rtcsessioncontroller com.amazon.venezia \
    com.amazon.bueller.music com.amazon.device.software.ota com.amazon.device.update.service com.amazon.tv.selectivepause \
    com.amazon.firetv.youtube \
    > "$FAKE_DEV/installed"
printf '%s\n' com.amazon.device.software.ota com.amazon.tv.launcher > "$FAKE_DEV/protected"
printf '%s\n' ro.build.version.sdk=28 ro.build.version.release=9 ro.build.version.fireos=7.6.6.9 \
    ro.product.cpu.abilist=armeabi-v7a,armeabi ro.product.model=AFTMM sys.boot_completed=1 > "$FAKE_DEV/props"
# Local APKs so nothing is downloaded (YouTube TV is exercised through the assisted-download path instead).
for f in ProjectivyLauncher-test.apk Couchy-Launcher-test.apk home-on-fire-test.apk SmartTube-test.apk; do printf 'fake' > "$PLAT/$f"; done
# Assisted APKMirror download: a fixture answers the metadata API and a fake "browser" drops the
# file into the watched downloads folder, exactly as a real browser would after the user's click.
export FSC_APKMIRROR_JSON="$ROOT/tests/fixtures/apkmirror-youtube.json"
export FSC_DOWNLOADS_DIR="$WORK/Downloads"; mkdir -p "$FSC_DOWNLOADS_DIR"
# The browser delivers an .apkm bundle (APKMirror's split-APK format): base.apk, a split for the
# device's CPU, a split for another CPU (must be left out), and APKMirror's info.json.
mkdir -p "$WORK/bundle"
{ printf 'PK'; head -c 200000 /dev/zero; } > "$WORK/bundle/base.apk"
{ printf 'PK'; head -c 150000 /dev/zero; } > "$WORK/bundle/split_config.armeabi_v7a.apk"
{ printf 'PK'; head -c 150000 /dev/zero; } > "$WORK/bundle/split_config.arm64_v8a.apk"
printf '{\n    "apkm_version": 5,\n    "versioncode": "727300320",\n    "pname": "com.google.android.youtube.tv"\n}\n' > "$WORK/bundle/info.json"
if command -v zip >/dev/null 2>&1; then
    (cd "$WORK/bundle" && zip -0 -q "$WORK/fake-youtube.apkm" base.apk split_config.armeabi_v7a.apk split_config.arm64_v8a.apk info.json)
else
    python3 -I -c 'import sys, zipfile, os
with zipfile.ZipFile(sys.argv[1], "w", zipfile.ZIP_STORED) as z:
    for n in sys.argv[3:]: z.write(os.path.join(sys.argv[2], n), n)' \
        "$WORK/fake-youtube.apkm" "$WORK/bundle" base.apk split_config.armeabi_v7a.apk split_config.arm64_v8a.apk info.json
fi
APKM_NAME="com.google.android.youtube.tv_7.27.300-727300320_minAPI24(armeabi-v7a)(nodpi)_apkmirror.com.apkm"
cat > "$WORK/fake-browser.sh" <<EOS
#!/usr/bin/env bash
echo "\$1" > "$WORK/opened-url"; sleep 1
cp "$WORK/fake-youtube.apkm" "$FSC_DOWNLOADS_DIR/$APKM_NAME"
EOS
chmod +x "$WORK/fake-browser.sh"; export FSC_BROWSER="$WORK/fake-browser.sh"

FAILED=0
run() { FSC_PLATFORM_DIR="$PLAT" bash "$ROOT/common/firestick-cleanup.sh" "$@" 2>&1; }
assert_contains() { # $1 label, $2 haystack, $3 needle
    # grep without -q reads all of its input: with -q and pipefail, printf dies of SIGPIPE at random.
    if printf '%s' "$2" | grep -F -- "$3" >/dev/null; then echo "  PASS: $1"; else echo "  FAIL: $1 (missing: $3)"; FAILED=1; fi
}
assert_eq() { if [ "$2" = "$3" ]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; FAILED=1; fi; }

echo "== dry-run =="
out="$(run --ip 10.0.0.9 --launcher couchy --with youtubetv --disable video,updates,stocklauncher --dry-run -y)"
assert_contains "device info read over adb" "$out" "Device: AFTMM, Fire OS 7.6.6.9 (Android 9, API 28), CPU: armeabi-v7a,armeabi"
assert_contains "dry-run lists launcher" "$out" "Launcher:        Couchy Launcher"
assert_contains "dry-run lists add-ons (homeonfire implied by couchy)" "$out" "Add-ons:         homeonfire,youtubetv"
assert_contains "dry-run counts present packages" "$out" "Would disable (18)"
assert_contains "dry-run shows the performance plan" "$out" "Process limit:   at most 2 apps kept in the background (now: Fire OS standard)"
assert_eq "dry-run changed nothing" "$(wc -l < "$FAKE_DEV/disabled" | tr -d ' ')" "0"

echo "== stock launcher: nothing to install, the stock-launcher group is refused =="
out="$(run --ip 10.0.0.9 --launcher stock --disable video,stocklauncher --dry-run -y)"
assert_contains "stock launcher selected" "$out" "Launcher:        Amazon launcher (keep stock)"
assert_contains "stock-launcher group dropped with a warning" "$out" "Group 'stocklauncher' would disable Amazon launcher (keep stock), the launcher you are keeping; skipped."
assert_eq "stock launcher never listed for disabling" "$(printf '%s\n' "$out" | grep -c '^      com.amazon.tv.launcher$')" "0"

echo "== non-interactive run cannot use the assisted download =="
out="$(run --ip 10.0.0.9 --launcher couchy --with youtubetv --disable video -y)"
assert_contains "variant picked for API 28 / armeabi-v7a" "$out" "Latest: YouTube for Android TV 7.27.300 beta (build 727300320, min API 24, armeabi-v7a)"
assert_contains "assisted download refused without a human" "$out" "APKMirror does not allow scripted downloads"

echo "== install (couchy + home on fire + youtube tv via assisted download + smarttube) =="
# Interactive run so the browser-assisted download is allowed; every prompt gets an explicit answer.
# answers: IP, launcher 3 (couchy), add-ons: homeonfire y, youtubetv y, googleapp n, smarttube y,
#          groups: video y, 12x Enter (keep: primevideo .. whisperplay), updates y, stocklauncher y,
#          performance: Enter (limit 2), Enter (GPU on), then Enter for each notes pause and to exit
out="$(printf '10.0.0.9\n3\ny\ny\nn\ny\ny\n\n\n\n\n\n\n\n\n\n\n\n\ny\ny\n\n\n\n\n\n\n\n\n' | run)"
assert_contains "launcher installed" "$out" "Couchy Launcher holds the HOME role"
assert_contains "home on fire configured" "$out" "Home on Fire accessibility service is active"
assert_contains "home on fire grant verified" "$out" "Home on Fire has WRITE_SECURE_SETTINGS"
assert_contains "boot prep applied" "$out" "Allowed to run at boot and in the background"
assert_contains "launcher running after boot" "$out" "Couchy Launcher is running after boot"
assert_contains "home on fire running after boot" "$out" "Home on Fire is running after boot"
assert_contains "amazon home in front after boot" "$out" "On screen after boot: com.amazon.tv.launcher"
assert_contains "home press redirects to launcher" "$out" "After pressing Home: Couchy Launcher takes over"
assert_contains "browser opened on the matching variant page" "$(cat "$WORK/opened-url")" "youtube-for-android-tv-7-27-300-4-android-apk-download"
assert_contains "downloaded bundle picked up" "$out" "Got com.google.android.youtube.tv_7.27.300-727300320_minAPI24(armeabi-v7a)(nodpi)_apkmirror.com.apkm"
assert_contains "bundle unpacked for the device CPU" "$out" "Unpacked: base.apk + 1 split APK(s) for armeabi-v7a,armeabi"
assert_contains "split install used" "$(cat "$FAKE_DEV/calls.log")" "install-multiple -r"
assert_eq "only the matching CPU split installed" "$(tr '\n' ' ' < "$FAKE_DEV/last_install_parts" | sed 's/ $//')" "base.apk split_config.armeabi_v7a.apk"
assert_contains "installed build verified" "$out" "Installed build 727300320"
assert_contains "process limit applied" "$out" "Background process limit: at most 2 apps kept in the background (was Fire OS standard)"
assert_contains "gpu rendering applied" "$out" "Force GPU rendering: on (was off)"
assert_contains "process limit stored in activity_manager_constants (Android 9)" "$(cat "$FAKE_DEV/settings")" "activity_manager_constants=max_cached_processes=2"
assert_contains "gpu rendering property set" "$(cat "$FAKE_DEV/props")" "persist.sys.ui.hw=true"
assert_contains "performance verified after reboot" "$out" "Background process limit is at most 2 apps kept in the background"
assert_contains "youtube tv installed" "$out" "YouTube for Android TV is installed"
assert_contains "smarttube installed from local apk" "$out" "SmartTube is installed"
assert_contains "amazon youtube disabled by add-on" "$out" "Disabled: com.amazon.firetv.youtube (replaced by YouTube for Android TV)"
assert_contains "protected packages reported" "$out" "Protected: com.amazon.tv.launcher"
assert_contains "package re-enabled by boot was re-disabled" "$out" "Re-disabled 1 packages"
assert_eq "17 packages disabled on device" "$(wc -l < "$FAKE_DEV/disabled" | tr -d ' ')" "17"
assert_eq "HOME role holder" "$(cat "$FAKE_DEV/role")" "com.conreo.couchytv"
assert_contains "accessibility set" "$(cat "$FAKE_DEV/settings")" "io.github.toolicious.homeonfire/io.github.toolicious.homeonfire.HijackService"
assert_contains "state records launcher" "$(cat "$PLAT/firestick_cleanup_10.0.0.9.state")" "launcher=couchy"
assert_contains "state records add-ons" "$(cat "$PLAT/firestick_cleanup_10.0.0.9.state")" "addons=homeonfire,youtubetv,smarttube"
assert_contains "optional groups saved from interactive answers" "$(cat "$PLAT/firestick_cleanup_10.0.0.9.state")" "groups=video,updates,stocklauncher"

echo "== status =="
out="$(run --ip 10.0.0.9 --status -y)"
assert_contains "status shows launcher" "$out" "Couchy Launcher: installed, holds HOME role"
assert_contains "status shows youtube tv" "$out" "YouTube for Android TV: installed"
assert_contains "status shows smarttube" "$out" "SmartTube: installed"
assert_contains "status shows disabled count" "$out" "Disabled packages:       17"
assert_contains "status shows process limit" "$out" "Background process limit: at most 2 apps kept in the background"
assert_contains "status shows gpu rendering" "$out" "Force GPU rendering:      on"

echo "== cached download is reused on a second run =="
out="$(run --ip 10.0.0.9 --launcher couchy --with youtubetv --without smarttube --disable video -y)"
assert_contains "cached apk reused without a browser" "$out" "Already downloaded: com.google.android.youtube.tv_7.27.300-727300320"
assert_contains "saved add-ons keep home on fire" "$(cat "$PLAT/firestick_cleanup_10.0.0.9.state")" "addons=homeonfire,youtubetv"

echo "== reapply after simulated Fire OS update =="
tail -n +4 "$FAKE_DEV/disabled" > "$FAKE_DEV/disabled.tmp"; mv "$FAKE_DEV/disabled.tmp" "$FAKE_DEV/disabled"; : > "$FAKE_DEV/settings"
out="$(run --ip 10.0.0.9 --reapply -y)"
assert_contains "reapply re-disables" "$out" "Disabled: com.amazon.hybridadidservice"
assert_contains "reapply restores home on fire" "$out" "Home on Fire settings re-applied"
assert_contains "accessibility restored" "$(cat "$FAKE_DEV/settings")" "io.github.toolicious.homeonfire/io.github.toolicious.homeonfire.HijackService"
assert_contains "process limit re-applied after the update" "$(cat "$FAKE_DEV/settings")" "activity_manager_constants=max_cached_processes=2"

echo "== interactive install (projectivy, answers piped) =="
# answers: IP (Enter = last IP), launcher 1, 4x n (add-ons), groups: video keep, primevideo keep, appstore y,
#          photos keep, music y, then Enter for the remaining groups, performance, notes pause and exit
out="$(printf '\n1\nn\nn\nn\nn\n\n\ny\n\ny\n\n\n\n\n\n\n\n\n\n\n\n\n\n\n' | run)"
assert_contains "menu picks projectivy" "$out" "Launcher: Projectivy Launcher"
assert_contains "projectivy accessibility appended" "$(cat "$FAKE_DEV/settings")" "HijackService:com.spocky.projengmenu/com.spocky.projengmenu.services.ProjectivyAccessibilityService"
assert_contains "optional groups saved" "$(cat "$PLAT/firestick_cleanup_10.0.0.9.state")" "groups=appstore,music"
assert_contains "no add-ons chosen interactively" "$(grep '^addons=' "$PLAT/firestick_cleanup_10.0.0.9.state")" "addons="

echo "== revert =="
out="$(run --ip 10.0.0.9 --revert -y)"
assert_contains "revert used state" "$out" "Using saved state"
assert_eq "no third-party apps left" "$(grep -vc '^com.amazon' "$FAKE_DEV/installed" | tr -d ' ')" "0"
assert_contains "amazon youtube still installed after revert" "$(cat "$FAKE_DEV/installed")" "com.amazon.firetv.youtube"
assert_eq "no packages disabled" "$(wc -l < "$FAKE_DEV/disabled" | tr -d ' ')" "0"
assert_eq "HOME role back to Amazon" "$(cat "$FAKE_DEV/role")" "com.amazon.tv.launcher"
assert_contains "accessibility cleared" "$(cat "$FAKE_DEV/settings")" "accessibility_enabled=0"
assert_eq "process limit removed on revert" "$(grep -c '^activity_manager_constants=' "$FAKE_DEV/settings")" "0"
assert_contains "gpu rendering back off on revert" "$(cat "$FAKE_DEV/props")" "persist.sys.ui.hw=false"
[ -f "$PLAT/firestick_cleanup_10.0.0.9.state" ] && { echo "  FAIL: state file still exists"; FAILED=1; } || echo "  PASS: state file removed"

echo "== a renamed bundle saved before the run is accepted by the watcher =="
# Nothing is cached, the browser delivers nothing, and the only file in Downloads is older than
# the run and no longer carries APKMirror's name: it is recognised by the info.json inside.
rm -rf "$PLAT/downloads"; rm -f "$FSC_DOWNLOADS_DIR"/*
cp "$WORK/fake-youtube.apkm" "$FSC_DOWNLOADS_DIR/youtube-tv.apkm"; touch -t 202001010000 "$FSC_DOWNLOADS_DIR/youtube-tv.apkm"
# shellcheck disable=SC2016  # $1 belongs to the generated stub, not to this shell
printf '#!/usr/bin/env bash\necho "$1" > "%s/opened-url"\n' "$WORK" > "$WORK/no-browser.sh"; chmod +x "$WORK/no-browser.sh"
export FSC_BROWSER="$WORK/no-browser.sh"
out="$(printf '10.0.0.9\n3\ny\ny\nn\nn\ny\n\n\n\n\n\n\n\n\n\n\n\n\ny\ny\n\n\n\n\n\n\n\n\n' | run)"
assert_contains "renamed bundle picked up and cached under a recognisable name" "$out" "Got com.google.android.youtube.tv_apkmirror-727300320.apkm"
assert_contains "renamed bundle unpacked" "$out" "Unpacked: base.apk + 1 split APK(s)"
assert_contains "build read from the bundle's info.json" "$out" "Installed build 727300320"
assert_contains "youtube tv installed from it" "$out" "YouTube for Android TV is installed"
[ -e "$FSC_DOWNLOADS_DIR/youtube-tv.apkm" ] && { echo "  FAIL: renamed bundle left in Downloads"; FAILED=1; } || echo "  PASS: renamed bundle moved into downloads/"

echo "== stock launcher install: keeps the Amazon home screen =="
# Couchy still holds the HOME role from the previous scenario; keeping stock must hand it back.
out="$(run --ip 10.0.0.9 --launcher stock --without homeonfire,youtubetv,smarttube,googleapp --disable video -y)"
assert_contains "nothing installed for the launcher" "$out" "Amazon launcher (keep stock) stays as it is; nothing to install"
assert_contains "home role handed back" "$out" "HOME role handed back to Amazon launcher (keep stock)"
assert_eq "HOME role holder is the stock launcher" "$(cat "$FAKE_DEV/role")" "com.amazon.tv.launcher"
assert_contains "stock launcher verified" "$out" "Amazon launcher (keep stock) holds the HOME role"
assert_contains "stock launcher on screen after boot" "$out" "On screen after boot: Amazon launcher (keep stock)"
assert_contains "state records the stock choice" "$(cat "$PLAT/firestick_cleanup_10.0.0.9.state")" "launcher=stock"

if [ "$FAILED" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; exit 1; fi
