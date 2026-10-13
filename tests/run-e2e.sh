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
    > "$FAKE_DEV/installed"
printf '%s\n' com.amazon.device.software.ota com.amazon.tv.launcher > "$FAKE_DEV/protected"
# Local APKs so nothing is downloaded.
for f in ProjectivyLauncher-test.apk Couchy-Launcher-test.apk home-on-fire-test.apk; do printf 'fake' > "$PLAT/$f"; done

FAILED=0
run() { FSC_PLATFORM_DIR="$PLAT" bash "$ROOT/common/firestick-cleanup.sh" "$@" 2>&1; }
assert_contains() { # $1 label, $2 haystack, $3 needle
    if printf '%s' "$2" | grep -qF -- "$3"; then echo "  PASS: $1"; else echo "  FAIL: $1 (missing: $3)"; FAILED=1; fi
}
assert_eq() { if [ "$2" = "$3" ]; then echo "  PASS: $1"; else echo "  FAIL: $1 (got '$2', want '$3')"; FAILED=1; fi; }

echo "== dry-run =="
out="$(run --ip 10.0.0.9 --launcher couchy --home-on-fire --disable video,updates,stocklauncher --dry-run -y)"
assert_contains "dry-run lists launcher" "$out" "Launcher:        Couchy Launcher"
assert_contains "dry-run counts present packages" "$out" "Would disable (18)"
assert_eq "dry-run changed nothing" "$(wc -l < "$FAKE_DEV/disabled" | tr -d ' ')" "0"

echo "== install (couchy + home on fire) =="
out="$(run --ip 10.0.0.9 --launcher couchy --home-on-fire --disable video,updates,stocklauncher -y)"
assert_contains "launcher installed" "$out" "Couchy Launcher holds the HOME role"
assert_contains "home on fire configured" "$out" "Home on Fire accessibility service is active"
assert_contains "protected packages reported" "$out" "Protected: com.amazon.tv.launcher"
assert_contains "package re-enabled by boot was re-disabled" "$out" "Re-disabled 1 packages"
assert_eq "16 packages disabled on device" "$(wc -l < "$FAKE_DEV/disabled" | tr -d ' ')" "16"
assert_eq "HOME role holder" "$(cat "$FAKE_DEV/role")" "com.conreo.couchytv"
assert_contains "accessibility set" "$(cat "$FAKE_DEV/settings")" "io.github.toolicious.homeonfire/.HijackService"
assert_contains "state records launcher" "$(cat "$PLAT/firestick_cleanup_10.0.0.9.state")" "launcher=couchy"

echo "== status =="
out="$(run --ip 10.0.0.9 --status -y)"
assert_contains "status shows launcher" "$out" "Couchy Launcher: installed, holds HOME role"
assert_contains "status shows disabled count" "$out" "Disabled packages:       16"

echo "== reapply after simulated Fire OS update =="
tail -n +4 "$FAKE_DEV/disabled" > "$FAKE_DEV/disabled.tmp"; mv "$FAKE_DEV/disabled.tmp" "$FAKE_DEV/disabled"; : > "$FAKE_DEV/settings"
out="$(run --ip 10.0.0.9 --reapply -y)"
assert_contains "reapply re-disables" "$out" "Disabled: com.amazon.hybridadidservice"
assert_contains "reapply restores home on fire" "$out" "Home on Fire settings re-applied"
assert_contains "accessibility restored" "$(cat "$FAKE_DEV/settings")" "io.github.toolicious.homeonfire/.HijackService"

echo "== interactive install (projectivy, answers piped) =="
out="$(printf '\n1\nn\n\ny\n\ny\n\n\n\n\n\n\n\n\n\n\n\n\n' | run)"
assert_contains "menu picks projectivy" "$out" "Launcher: Projectivy Launcher"
assert_contains "projectivy accessibility appended" "$(cat "$FAKE_DEV/settings")" "HijackService:com.spocky.projengmenu/.services.ProjectivyAccessibilityService"
assert_contains "optional groups saved" "$(cat "$PLAT/firestick_cleanup_10.0.0.9.state")" "groups=appstore,music"

echo "== revert =="
out="$(run --ip 10.0.0.9 --revert -y)"
assert_contains "revert used state" "$out" "Using saved state"
assert_eq "no third-party apps left" "$(grep -vc '^com.amazon' "$FAKE_DEV/installed" | tr -d ' ')" "0"
assert_eq "no packages disabled" "$(wc -l < "$FAKE_DEV/disabled" | tr -d ' ')" "0"
assert_eq "HOME role back to Amazon" "$(cat "$FAKE_DEV/role")" "com.amazon.tv.launcher"
assert_contains "accessibility cleared" "$(cat "$FAKE_DEV/settings")" "accessibility_enabled=0"
[ -f "$PLAT/firestick_cleanup_10.0.0.9.state" ] && { echo "  FAIL: state file still exists"; FAILED=1; } || echo "  PASS: state file removed"

if [ "$FAILED" -eq 0 ]; then echo "ALL TESTS PASSED"; else echo "SOME TESTS FAILED"; exit 1; fi
