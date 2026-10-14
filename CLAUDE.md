# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

A no-root Fire TV debloater and launcher replacer driven over adb. One shared data layer (`common/packages.conf`, `common/launchers.conf`) feeds three implementations that must behave identically: the bash script (`common/firestick-cleanup.sh`, used by the `mac/` and `linux/` wrappers), the PowerShell console script (`windows/Firestick-Cleaner-And-Launcher-Replacer.ps1`) and the WinForms GUI (`windows/WinformVer/`). Everything is reversible through a per-device state file.

## Commands

```bash
shellcheck -s bash common/firestick-cleanup.sh mac/*.command linux/*.sh tests/run-e2e.sh   # what CI runs
bash tests/run-e2e.sh            # end-to-end against a fake adb + fake Fire TV; no device, no network; ~1-3 min
```

- The e2e test is one script of sequential scenarios (`== dry-run ==`, `== install ... ==`, `== reapply ==`, `== revert ==`, `== stock launcher install ==`, ...) that share the fake device's state in `$FAKE_DEV`, so they cannot be run in isolation; to iterate on one, put `exit` after its block. Reboot waits are real sleeps.
- The two interactive scenarios pipe answers to prompts positionally (IP, launcher number, one answer per add-on, one per optional group in `packages.conf` file order, two for performance, then Enters for the notes pauses and exit). Adding or reordering a group in `packages.conf` means adding or moving an Enter in both `printf` strings, or the later answers land on the wrong prompt.
- The fake adb lives in `tests/fake-adb/adb`; device-side commands (`pm`, `cmd`, `settings`, `am`, `appops`, `getprop`, `input`, `reboot`) are shims in `tests/fake-adb/shims/` that read/write flat files (`installed`, `disabled`, `protected`, `role`, `settings`, `props`) under `$FAKE_DEV`. Add a shim there when the script starts using a new device command, or the test fails with "unhandled".
- Against a real stick: `mac/Firestick-Cleaner-And-Launcher-Replacer.command --ip <ip> --status` / `--dry-run` / `--reapply -y` / `--test-boot`. `-y` requires `--ip`. Logs (`firestick_cleanup_<date>.log`), the state file (`firestick_cleanup_<ip>.state`), `.last_ip` and `downloads/` land next to the entry point (`mac/` here), all gitignored.
- Windows checks (CI only, no pwsh/dotnet on this Mac): PowerShell parse + `Invoke-ScriptAnalyzer` on the .ps1, and `dotnet build windows/WinformVer/WinformVer.csproj -c Release` (net48, C# 7.3). The csproj copies `../adb/**` and `../../common/*.conf` next to the exe, so the GUI reads the same conf files at runtime.
- Local adb: `mac/adb/adb -s <ip>:5555 shell ...`. In zsh, wrap it in a function rather than putting flags in a variable.

## Architecture

### Data layer (the only place behaviour is normally changed)
- `packages.conf`: `[key] Prompt text` groups of package names. `[always]` is disabled without asking; every other group is a Y/N prompt and a `--disable` key. Packages absent on the device are skipped; ones Amazon protects are reported as "Protected".
- `launchers.conf`: one `[section]` per app, `type=launcher|addon`, with `package`, `activity`, `accessibility`, `grant`, `appops`, `boot=yes`, `source=github:|apkmirror:|manual:|none`, `apk_glob`, `needs`, `disables`, `note` lines. `source=none` is the stock launcher: nothing installed, HOME role handed back, and any group containing its package is dropped (`drop_launcher_groups`).
- The README duplicates both files as tables (Launchers, Always disabled, Optional groups). Keep them in sync when editing a conf.

### Shell script flow (`do_install`)
1. `connect_device` / `read_device_info` (API level + ABIs via getprop; drives APK variant choice).
2. Prompts: `choose_launcher`, `choose_addons`, `choose_groups`, `choose_performance`; then `build_bloat_list` + `classify_bloat` (PRESENT / ALREADY_DISABLED / ABSENT).
3. `setup_app` per launcher and add-on: `fetch_apk` (GitHub release with SHA-256 check, or browser-assisted APKMirror download watched in `~/Downloads`, or user-supplied file matching `apk_glob`; `.apkm` bundles are unpacked and installed with `install-multiple`) -> `install_apk` -> `configure_app` (grants, accessibility list, app ops, `prepare_boot` doze/standby, HOME role + `set-home-activity`, `disable_replaced_packages`, launch) -> `show_notes`.
4. `apply_performance`: background process limit (`device_config activity_manager max_cached_processes` on API 29+, `activity_manager_constants` on API 26-28) and `persist.sys.ui.hw`.
5. `run_disable_passes`: one device-side batch script per pass (`dsh_script` pushes a file to `/data/local/tmp` and runs it, avoiding command-length limits); protected packages trigger one reboot and a retry, up to three passes.
6. `reboot_and_reconnect` (sleeps 15 s first: the package manager persists state asynchronously, rebooting sooner loses the last changes), then `reapply_disabled` because Fire OS re-enables some packages during boot.
7. `verify_app`, `verify_performance`, `verify_boot` (waits for `sys.boot_completed`, checks processes, presses Home over adb if Amazon's home is in front).

Other modes: `do_reapply` (groups from the state file, re-configures the saved launcher and add-ons, re-applies performance values), `do_revert` (re-enables `disabled=` entries, restores `prev_*` secure settings, removes role/appops and uninstalls `installed=` entries, restores performance, deletes the state file), `do_status`, `do_test_boot`.

### State file
Flat `key=value` lines, appended as the run progresses (`state_put` appends, `state_set` replaces, `state_add_unique` for repeatable keys). Keys: `version`, `launcher`, `addons`, `groups`, repeated `installed=` and `disabled=`, `prev_enabled_accessibility_services`, `prev_enabled_notification_listeners`, `process_limit`/`prev_process_limit`, `force_gpu`/`prev_force_gpu`. `--reapply` re-enables whatever launcher the file names, so hand-edit `launcher=` before using it to switch launchers. The PowerShell `Get-State`/`Set-State` and C# `StateFile` read the same format.

### Device helpers and conventions
- `dsh` runs one shell command and logs it; use `qgrep` (grep without `-q`) in every `producer | grep` pipeline: with `set -o pipefail`, `grep -q` exits early and the producer dies of SIGPIPE at random (this once reported a successful 26-split install as "not on the device"). The e2e harness's `assert_contains` follows the same rule.
- Must stay bash 3.2 compatible (macOS default): no associative arrays, no `mapfile`.
- HOME role holder is read from `dumpsys role` on Android 11 (Fire OS 8) because `cmd role get-role-holders` only exists from Android 12 (`home_role_holder`).
- Env overrides: `FSC_PLATFORM_DIR`, `FSC_ENTRY` (set by the wrappers), `FSC_DOWNLOADS_DIR`, `FSC_BROWSER`, `FSC_APKMIRROR_JSON` (test fixture for the APKMirror metadata API).
- `.gitattributes` forces LF for `.sh/.command/.conf/.md` and CRLF for `.ps1/.cs/.csproj/.bat`; bundled adb binaries and APKs are binary. APKs/APKMs are never committed.

### Windows ports mirror the shell function-for-function
PS1: `Get-Conf`, `Get-GroupPackages`, `Invoke-DisableBatch`, `Set-AppConfig`, `Install-App`, `Restart-Device`, `Test-BootState`... C#: `MainForm.cs` holds the same steps as `*Async` methods (`RunInstallAsync`, `ConfigureAppAsync`, `DeviceScriptAsync`, `ReapplyDisabledAsync`), `Conf.cs` parses the conf files, `StateFile.cs` the state. When changing the shell script, port the change to both and keep names parallel.

## Parity status (as of 2026-10-14)

Shell-only, not yet ported to the .ps1 or the WinForms app:
- APKMirror `.apkm` bundle handling: watcher accepts `.apk` and `.apkm`, recognises renamed bundles by the `info.json` inside, accepts a file saved before the run if it is the build APKMirror reported, Enter rescans and explains, bundles are unpacked to base + CPU splits and installed with `adb install-multiple -r`. The Windows flows still filter on `<pkg>_*.apk` and use `pm install -r`, so newer YouTube for Android TV releases (APKMirror ships them only as `.apkm`) stall at "watching" for 15 minutes there. Port from `prepare_apk`, `pick_download`, `explain_watch`, `wait_for_download`.
- Performance tweaks step (`--process-limit`, `--gpu-rendering`, STEP 4 prompt / STEP 5 apply, `prev_*` state keys). Port from `choose_performance`, `apply_performance`, `verify_performance`, `restore_performance`.
- The `[stock]` launcher section and the `qgrep` pipefail fix are in all three, but the .ps1 and .cs edits for the stock launcher were made without pwsh/dotnet available and are unverified by a parser or compiler.

## Known issues

- `disable_batch` classifies by the first line of `pm disable-user` output. On Fire OS 8 the `SecurityException: Cannot disable a protected package` arrives on a second line, so protected packages (`com.amazon.device.software.ota`, `.ota.override` on the test stick) print as `Failed: ... (failed: )` instead of `Protected`, and the reboot-and-retry pass is skipped. Fix in the awk in `disable_batch` (and the PS1/C# equivalents).
- `--revert` with a state file whose `installed=` list includes a paid launcher uninstalls it. There is no "disable but keep" mode; that was done by hand (see below).

## Fire OS facts learned from live testing

Test stick: Fire TV Stick (model `AFTNE4E43F`), Fire OS 8.1.8.5 (Android 11, API 30, armeabi-v7a), India region, LAN address 192.168.1.31. Its state file is `mac/firestick_cleanup_192.168.1.31.state` (gitignored).

- `com.amazon.firebat` is the Prime Video app (versionName `PVFTV-...`), not telemetry. It sat in `[always]` as "Power analytics" until 2026-10-14 and was moved to the optional `[primevideo]` group. Never put it back in an always-on list.
- The Amazon home screen's "Your apps and channels" row is built from the Appstore's app library (`com.amazon.venezia` LockerExternalProvider, not readable over adb), not from the package manager. Disabled packages keep their tiles until the library is rebuilt, and an app that was disabled then re-enabled stays missing. Confirmed fix: clear the Appstore's cache and data, reboot, then search the app in the Appstore and press Install (no download happens, the entry is just re-registered). Third-party launchers (AT4K) list every `LEANBACK_LAUNCHER` activity directly, so they show Prime Video regardless.
- Protected on this firmware: `com.amazon.device.software.ota`, `com.amazon.device.software.ota.override`. `com.amazon.tv.forcedotaupdater.v2` can be disabled, so the `updates` group is only partial here. `com.amazon.device.update.service`, `com.amazon.fvp.update.service`, `com.amazon.tv.selectivepause` and `com.amazon.avod` are not present on this build.
- `setprop persist.sys.ui.hw` is allowed from adb here; the live process limit changes at once (Amazon's default is 8).
- Amazon's launcher keeps a hard-coded priority (950) on the HOME intent, so the stock home always resolves first at boot even when another launcher holds the role; the Home-button hook (accessibility service or Home on Fire) is what makes a third-party launcher appear.
- Since 2026-10-14 the stick runs the stock launcher by choice: AT4K (`com.overdevs.at4k`, paid licence) and Home on Fire are `pm disable-user`'d, not uninstalled; HOME role and default home activity are on `com.amazon.tv.launcher`; `enabled_accessibility_services` is empty; the state file says `launcher=stock`, `addons=googleapp`. Re-enable AT4K with `pm enable --user 0 com.overdevs.at4k` (Fire OS settings do not list disabled apps). Do not run `--revert` or an install with `--launcher at4k` on it without asking.
- History on that stick (2026-10-13): first install run disabled Prime Video by mistake; a `--revert` at 20:07 re-enabled everything and uninstalled the launchers; the later install runs reinstalled AT4K + Home on Fire but aborted before the disable step (Google app install reported success but `pm path` found nothing), so nothing was disabled until the 2026-10-14 `--reapply`.
