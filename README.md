# Firestick Cleanup

![Firestick Cleanup screenshot](screenshot.jpg)

Replace the ad-filled Amazon Fire TV home screen with a launcher of your choice and disable Amazon's tracking, telemetry and bloatware. No root required, fully reversible.

## What it does

1. Connects to your Fire TV over ADB (Wi-Fi), waits for you to accept the prompt on the TV, and reads its Fire OS version, Android API level and CPU type
2. Installs the launcher you pick: **Projectivy**, **AT4K** or **Couchy**, or keeps the **Amazon launcher** if you only want the clean-up
3. Optionally installs add-ons: **Home on Fire** (makes the Home button open your launcher), **YouTube for Android TV** or **SmartTube** (in place of Amazon's YouTube wrapper) and the **Google app for Android TV**, each in the build that matches your device
4. Asks which optional Amazon apps you want to keep (Music, Photos, Appstore, Prime Video services...)
5. Applies two performance tweaks from Android's developer options: a background process limit (default 2) and forced GPU rendering
6. Disables tracking, telemetry, ads and background bloat, plus your optional choices
7. Reboots, verifies, and re-disables anything Amazon re-enabled during the reboot
8. Shows a before/after RAM comparison
9. Records everything it changed, so `--revert` undoes exactly that and nothing else

## Launchers

| Launcher | Home button handling | APK | Notes |
|----------|---------------------|-----|-------|
| [Projectivy Launcher](https://github.com/spocky/miproja1) (default) | Its own accessibility service | Downloaded automatically from GitHub, SHA-256 verified | Feature-rich. After install, enable **Settings > General > Override current launcher** in Projectivy. |
| [AT4K Launcher](https://at4klauncher.com/) | Its own accessibility service | **Not bundled.** It is a paid app sold on Google Play; you must supply the APK and save it next to the script as `AT4K*.apk` or `base.apk` | Lightweight. |
| [Couchy Launcher](https://github.com/conreo/couchy-launcher) | None. Pair it with Home on Fire | Downloaded automatically from GitHub, SHA-256 verified | Minimal, open source, no Google services needed. |
| Amazon launcher (keep stock) | Unchanged | Nothing to install | Pick this (`--launcher stock`) to leave the home screen alone and only debloat, add add-ons and apply the performance tweaks. The optional group that disables the stock launcher is skipped automatically, and the HOME role is handed back to Amazon's launcher if another one holds it. |

## Add-ons

Add-ons are asked about one by one after the launcher, and can be forced with `--with <key>` or skipped with `--without <key>`. Each add-on is a section in `common/launchers.conf`.

### Home on Fire (`homeonfire`)

[Home on Fire](https://github.com/toolicious/home-on-fire) is a tiny open-source app that intercepts the Home button and opens the launcher you choose, and launches it at boot and on wake. It is **required for Couchy** (which has no Home-button service of its own, so the prompt defaults to yes there) and optional for Projectivy and AT4K, which bring their own. The script downloads and verifies it, grants it the `WRITE_SECURE_SETTINGS` permission its README asks for, enables its accessibility service, and verifies the grant afterwards. Its **Launch on boot** and **Accessibility service** switches are on by default; you pick your launcher once under **Choose target app** inside the app. If you combine it with Projectivy, leave Projectivy's **Override current launcher** off: the two hooks conflict.

Known behaviour from the Home on Fire project: on Fire OS 8 the Amazon home screen flashes briefly before your launcher appears; on Fire OS 7 a Home press can take a few seconds. Long-press Home to get back to the Amazon home screen at any time. Fire OS 6 and older are not supported.

### YouTube for Android TV (`youtubetv`)

Replaces Amazon's Fire TV YouTube wrapper (`com.amazon.firetv.youtube`) with Google's official YouTube for Android TV app (`com.google.android.youtube.tv`), the same app that ships on Android TV and Google TV devices. The Amazon wrapper is disabled so only one YouTube shows in your launcher, and that is recorded so `--revert` puts it back.

Google does not publish this APK, and APKMirror, the usual mirror, does not allow programs to download files (its download endpoint is blocked for scripts and excluded in its robots.txt). So the tool does everything except the final click:

1. It reads the Fire TV's Android API level and CPU type over adb (Fire OS 7 is API 28, Fire OS 8 is API 30; sticks are `armeabi-v7a`, newer models also `arm64-v8a`).
2. It asks APKMirror's metadata API, the same one the open-source APKUpdater app uses, for the newest release and picks the variant whose minimum API and CPU fit your device.
3. It opens exactly that download page in your browser. You click **DOWNLOAD APK** (or **DOWNLOAD APK BUNDLE**: newer releases come as an `.apkm` bundle of base APK plus split APKs, which is fine).
4. It watches your Downloads folder (and the script folder), picks the file up, checks it is a real APK, and compares its signing certificate with the one APKMirror recorded for that release when the APK carries a v1 signature. An `.apkm` bundle is unpacked first: base.apk and the split APKs that fit your Fire TV's CPU are kept and installed in one `adb install-multiple` session. Android verifies the signature again on install. A file you saved before starting the run is accepted when it is the build APKMirror reported, even if you renamed it (bundles are recognised by the `info.json` inside). Press **Enter** while it is watching to see which files it can see and why each was skipped.
5. After installing it confirms the installed build number matches.

The file is cached under `downloads/`, so later runs and `--reapply` need no click. In `--non-interactive` mode the click is impossible, so place a `com.google.android.youtube.tv_*.apk` or `.apkm` next to the entry point beforehand. If your browser saves downloads somewhere unusual, set `FSC_DOWNLOADS_DIR`.

Sign-in uses the on-screen code at youtube.com/activate. On some Fire OS versions sign-in needs Google Play Services, which Fire OS does not have, and will not work; playback works signed out. If you want an account without Google services, use SmartTube instead.

### SmartTube (`smarttube`)

[SmartTube](https://github.com/yuliskov/SmartTube) is an open-source YouTube client for TVs: ad-free, signs in with a youtube.com/activate code, and needs no Google services at all, so it is the most reliable way to get your account on a Fire TV. It is downloaded from its GitHub releases, verified against the release's SHA-256 digest, and the build for your CPU (`arm64-v8a`, `armeabi-v7a` or universal) is chosen automatically. It leaves the Amazon YouTube app alone; add `youtubetv` as well if you want that disabled.

### Google app for Android TV (`googleapp`)

Google's Assistant and voice-search app for Android TV (`com.google.android.katniss`), fetched the same assisted way as YouTube. It is marked experimental: it depends on Google Play Services, which cannot be installed on an unrooted Fire TV, so it may refuse to start. `--revert` removes it.

### Why not microG?

microG reimplements Google Play Services, but Google's own apps (YouTube, the Google app) only accept it when the system allows signature spoofing, which needs root or a custom ROM. Fire TV offers neither, so microG cannot provide sign-in for the official YouTube app here. SmartTube does not need any of this.

## Performance tweaks

Fire TV sticks have little RAM, so after the optional groups the tool asks about two settings that live under Android's hidden developer options (Fire OS has no menu for them):

- **Background process limit** (`--process-limit 0-4|standard`, default 2): how many apps Android keeps alive after you leave them. With 2, the app you are using keeps the memory instead of sharing it with everything you opened earlier; apps you return to may start cold. `standard` leaves Fire OS's own limit (8 on current Fire OS 8 builds). Android's developer-options toggle for this forgets its value at every reboot; the tool sets the value underneath it instead (`device_config activity_manager max_cached_processes` on Fire OS 8, the `activity_manager_constants` setting on Fire OS 6/7), which survives reboots and takes effect at once.
- **Force GPU rendering** (`--gpu-rendering on|off`, default on): sets `persist.sys.ui.hw`, so every app window is drawn by the GPU, including older apps that still default to CPU drawing. Firmware that protects the property gets a warning and nothing else changes.

With `-y` the defaults apply unless you pass the flags. Both values are recorded, re-checked by `--test-boot`, re-applied by `--reapply`, and put back to their previous values by `--revert`.

## Platforms

| Folder | OS | Entry point | UI |
|--------|-----|-------------|------|
| `windows/` | Windows 10/11 | `Firestick-Cleaner-And-Launcher-Replacer.bat` (starts the PowerShell script next to it) | Console |
| `windows/WinformVer/` | Windows 10/11 | `FirestickCleanup.exe` (build from source, or download the CI artifact) | GUI |
| `mac/` | macOS | `Firestick-Cleaner-And-Launcher-Replacer.command` | Terminal |
| `linux/` | Linux | `Firestick-Cleaner-And-Launcher-Replacer.sh` | Terminal |

The Mac and Linux entry points are two-line wrappers around one shared script, `common/firestick-cleanup.sh`. All implementations read the same two data files, `common/packages.conf` and `common/launchers.conf`, so they disable the same packages and support the same launchers.

### ADB

ADB is bundled for each platform (`<platform>/adb/`). If the bundled binary cannot run on your machine (for example Linux on ARM), the script falls back to an `adb` on your PATH and, failing that, offers to download Google's platform-tools.

## Prerequisites: enable ADB on the Fire TV

1. Go to **Settings > My Fire TV > About**
2. Select the device name (for example **Fire TV Stick**) seven times to unlock Developer Options
3. Go to **Settings > My Fire TV > Developer Options**
4. Enable **ADB Debugging** and **Apps from Unknown Sources**
5. Note the IP address under **Settings > My Fire TV > About > Network**

## Usage

### Windows (console)

Double-click `windows/Firestick-Cleaner-And-Launcher-Replacer.bat`. The batch file only starts `Firestick-Cleaner-And-Launcher-Replacer.ps1` with the execution policy bypassed for that one run; no system settings are changed. Arguments are passed through:

```
Firestick-Cleaner-And-Launcher-Replacer.bat --revert
```

### Windows (GUI)

Build `windows/WinformVer/WinformVer.csproj` with Visual Studio or `dotnet build`, or download the `FirestickCleanup-WinForms` artifact from the latest CI run. The GUI has the same launcher menu, add-on checkboxes and per-group checkboxes, plus **Install + Clean**, **Re-apply**, **Status** and **Revert** buttons.

### macOS

Double-click `mac/Firestick-Cleaner-And-Launcher-Replacer.command` in Finder. On first run Gatekeeper may block it: right-click, choose **Open**, confirm. The script clears the quarantine flag on the bundled adb itself.

### Linux

```
chmod +x linux/Firestick-Cleaner-And-Launcher-Replacer.sh linux/adb/adb
linux/Firestick-Cleaner-And-Launcher-Replacer.sh
```

### Options (identical on every platform)

```
Modes (default: full install)
  --revert            Undo everything recorded for this device and restore stock
  --reapply           Re-disable packages using the saved choices (after a Fire OS update)
  --status            Show launcher, Home on Fire and disabled-package state; change nothing
  --dry-run           Show what would be done; change nothing
  --test-boot         Reboot the Fire TV and check the launcher and add-ons come up (run it after
                      the on-TV steps, or any time you want a cold-boot check)

Options
  --ip <ip[:port]>    Fire TV address (skips the prompt; the last used address is remembered)
  --launcher <key>    projectivy | at4k | couchy | stock   (default: projectivy; stock keeps Amazon's home screen)
  --with <a,b,..>     Add-ons to install: homeonfire, youtubetv, smarttube, googleapp
  --without <a,b,..>  Add-ons to skip (--home-on-fire / --no-home-on-fire are shorthands for homeonfire)
  --disable <a,b,..>  Optional groups to disable, comma-separated (keys from packages.conf)
  --process-limit <n> Background process limit: 0-4 (default 2) or "standard" to leave Fire OS's own
  --gpu-rendering <on|off>
                      Force GPU rendering for every app (default on)
  -y, --non-interactive
                      Never prompt; requires --ip
```

Examples:

```
# Couchy + Home on Fire + SmartTube, also disable the video stack and update services, no questions asked
./Firestick-Cleaner-And-Launcher-Replacer.sh --ip 10.0.0.20 --launcher couchy --with homeonfire,smarttube --disable video,updates -y

# After a Fire OS update put everything back the way it was
./Firestick-Cleaner-And-Launcher-Replacer.sh --ip 10.0.0.20 --reapply -y

# See what would happen without touching the device
./Firestick-Cleaner-And-Launcher-Replacer.sh --dry-run
```

### After a Fire OS update

Updates re-enable packages and sometimes wipe the accessibility settings. Run with `--reapply`: it reads the choices saved for that device, re-disables what came back, and re-applies the launcher and add-on settings without reinstalling anything or asking questions.

### Reverting

`--revert` reads the state file written for the device (`firestick_cleanup_<ip>.state` next to the entry point) and undoes exactly what was recorded: re-enables those packages (including ones an add-on replaced, such as Amazon's YouTube), restores the previous accessibility and notification-listener values, removes the HOME role and overlay permission from the launcher, uninstalls the launcher and the add-ons, hands the HOME role back to the Amazon launcher, and puts the background process limit and GPU rendering back to their previous values. If no state file exists it warns and offers to re-enable every disabled package instead.

## What gets disabled

Everything below lives in `common/packages.conf`. The `[always]` group is disabled without asking; every other group is a Y/N question and its key is what `--disable` takes. Packages that are not present on your device are skipped; packages Amazon protects on your firmware are reported as "Protected" (the script reboots once and retries them).

### Always disabled

| Package | What it does |
|---------|-------------|
| `com.amazon.tv.acr` | **Automatic Content Recognition**: tracks what is on screen, even non-Amazon content |
| `com.amazon.hybridadidservice` | **Advertising ID**: unique identifier for targeted ads |
| `com.amazon.perfc`, `com.amazon.perfcollection` | **Performance collection**: device performance telemetry |
| `com.amazon.device.telemetry.emitter` | **Telemetry emitter**: sends device telemetry to Amazon |
| `com.amazon.wirelessmetrics.service` | **Wireless metrics**: Wi-Fi and Bluetooth usage data |
| `com.amazon.shoptv.client`, `com.amazon.shoptv.firetv.client` | **Shop from TV**: shopping overlays |
| `com.amazon.ftv.screensaver` | **Screensaver**: ad-filled screensaver |
| `com.amazon.tv.ftvambient` | **Ambient mode**: ambient display with Amazon content |
| `com.amazon.sneakpeek` | **Sneak Peek**: promotional popups |
| `com.amazon.tv.turnstile` | **Content suggestions**: "recommended" rows that are mostly ads |
| `com.amazon.tv.notificationcenter`, `com.amazon.notificationcenter` | **Notification center**: promotional notifications (two names seen on different builds) |
| `com.amazon.tv.releasenotes` | **Release notes**: "what's new" screens after updates |
| `com.amazon.storm.lightning.tutorial`, `com.amazon.tmm.tutorial` | **Tutorials**: first-run walkthroughs |
| `com.amazon.logan` | **Log agent** |
| `com.amazon.fireos.cirruscloud` | **Cirrus Cloud**: cloud sync |
| `com.amazon.ods.kindleconnect` | **Kindle Connect** |
| `com.amazon.tahoe` | **Tahoe**: content delivery |
| `com.amazon.aria` | **Aria**: background service framework |
| `com.amazon.hedwig` | **Hedwig**: push notification delivery |
| `com.amazon.tv.support` | **TV Support**: remote diagnostics |
| `com.amazon.ceviche` | **Ceviche**: A/B testing framework |
| `com.amazon.d3` | **D3**: device data service |
| `com.amazon.device.rdmapplication` | **Remote device management** |
| `com.amazon.wifilocker` | **WiFi Locker**: shares your Wi-Fi password with Amazon |
| `com.amazon.spiderpork` | **SpiderPork**: background analytics |
| `com.amazon.ssm`, `com.amazon.ssmsys` | **Systems manager** agent and service |
| `com.amazon.tv.easyupgrade` | **Easy Upgrade**: "buy a newer Fire TV" prompts |
| `com.amazon.dpcclient` | **Device policy controller** |
| `com.amazon.sharingservice.android.client.proxy` | **Sharing service** |
| `com.amazon.privacypassservice` | **Privacy Pass** token service |
| `com.amazon.tv.legal.notices` | **Legal notices** screens |

### Optional groups (Y/N prompt, or `--disable <key>`)

| Key | Prompt | Packages |
|-----|--------|----------|
| `video` | Amazon Video services. **Answer N if you use Prime Video, Freevee or MiniTV**, or playback breaks | `com.amazon.avls.experience`, `com.amazon.prism.android.service`, `com.amazon.dp.logger`, `com.amazon.livedeviceservice`, `com.amazon.rtcsessioncontroller`, `com.amazon.client.metrics.api` |
| `primevideo` | Prime Video itself. **Answer N if you watch Prime Video.** `com.amazon.firebat` is Amazon's internal name for the Prime Video app, not a telemetry service; once it is disabled the stock launcher drops its tile while third-party launchers may keep showing a cached icon | `com.amazon.firebat` |
| `appstore` | Amazon Appstore | `com.amazon.venezia` |
| `photos` | Amazon Photos | `com.amazon.bueller.photos` |
| `music` | Amazon Music | `com.amazon.bueller.music` |
| `freevee` | Freevee / IMDb TV | `com.amazon.imdb.tv.android.app` |
| `minitv` | Amazon MiniTV | `com.amazon.minitv.android.app` |
| `gamehub` | Amazon Game Hub | `com.amazon.gamehub` |
| `livetv` | Amazon Live TV | `com.amazon.tv.livetv` |
| `alexa` | Alexa alerts and notifications | `com.amazon.tv.alexaalerts`, `com.amazon.tv.alexanotifications`, `com.amazon.audiohome` |
| `silk` | Silk Browser | `com.amazon.cloud9` |
| `smarthome` | Smart Home features | `com.amazon.smarthomemapviewapp` |
| `whisperplay` | WhisperPlay casting | `com.amazon.whisperplay.service.install` |
| `updates` | Fire OS update services. Updates re-enable bloat and may remove your launcher, but you also stop getting security fixes | `com.amazon.device.update.service`, `com.amazon.fvp.update.service`, `com.amazon.device.software.ota`, `com.amazon.device.software.ota.override`, `com.amazon.tv.forcedotaupdater.v2` |
| `stocklauncher` | The Amazon stock launcher itself. Works only on some firmware; do it only once your new launcher is confirmed working | `com.amazon.tv.launcher`, `com.amazon.tv.selectivepause` |

### Not attempted

These are protected on every firmware we have seen, or needed for basic operation, so the script leaves them alone: `com.amazon.device.metrics`, `com.amazon.client.metrics`, `com.amazon.device.logmanager`, `com.amazon.device.sync`, `com.amazon.securitysyncclient`, `com.amazon.ftvads.deeplinking`, `com.amazon.tv.csapp`, `com.amazon.tv.oobe`, `com.amazon.tv.settings`.

## Starting at boot

Fire OS always boots into Amazon's home screen on firmware where the stock launcher is protected. Your launcher appears because a Home-button hook (Projectivy's or AT4K's accessibility service, or Home on Fire) takes over, and Home on Fire additionally launches the target right after boot. The tool prepares every launcher and boot add-on for that (`boot=yes` in `launchers.conf`):

- grants the permissions and app ops each app's docs ask for (Home on Fire: `WRITE_SECURE_SETTINGS`; launchers: `SYSTEM_ALERT_WINDOW`), then verifies the grants
- enables the accessibility service with the fully qualified component name used by the community Fire TV guides
- puts the app on the doze whitelist, allows background execution and keeps it in the "active" standby bucket so its boot receiver and service are not throttled
- assigns the HOME role and default home activity to the launcher

After the final reboot it waits for `sys.boot_completed`, checks that the launcher and every boot add-on process is running, reads which app is on screen, and if Amazon's home is in front it presses Home over adb and checks again that your launcher takes over. Anything that fails is reported with the setting to check on the TV. `--test-boot` repeats the reboot and this check on demand, for example after you have picked the target in Home on Fire. Fire OS updates can clear these settings; run `--reapply`.

Some Fire OS builds switch **ADB Debugging** off at boot. Before every reboot the tool asks Fire OS to keep it on (best effort), and if the device does not come back it stops, tells you which toggle to turn on (Settings > My Fire TV > Developer Options > ADB Debugging) and waits for you instead of aborting; in non-interactive mode it waits five extra minutes.

Two more Fire OS quirks the tool allows for: the package manager saves package state a few seconds after the fact, so the tool waits before rebooting (otherwise the last changes, including the Home on Fire grant, are lost), and on Android 11 (Fire OS 8) the HOME role is read from `dumpsys role` because `cmd role get-role-holders` only exists from Android 12. Amazon's own launcher keeps a hard-coded priority on the HOME intent, so it still appears first at boot even when your launcher holds the role; the Home-button hook is what gets you to your launcher.

## How it works

Amazon protects the stock launcher as a system package on most firmware, so it usually cannot be disabled. Instead, a launcher's **accessibility service** (Projectivy, AT4K) or **Home on Fire** intercepts the Home button and opens your launcher. The script:

1. Reads the device's API level and CPU ABIs with `getprop`, then installs the APK with `pm install -r`. GitHub downloads are checked against the release's SHA-256 digest and the asset matching the CPU is chosen; APKMirror downloads are matched to the device's API level and CPU and their signing certificate is compared with APKMirror's record.
2. Appends the accessibility service (and notification listener, if any) to the existing `enabled_accessibility_services` secure setting, recording the previous value for revert
3. Grants the overlay permission, assigns the `android.app.role.HOME` role and sets the default home activity
4. Disables packages in one device-side batch per pass; if some are protected it reboots once and retries
5. After the final reboot, re-disables anything that came back
6. Writes every change to `firestick_cleanup_<ip>.state` so `--revert` and `--reapply` know exactly what to touch

## Customising

- **Packages:** edit `common/packages.conf`. Add a line to a group, or add a new `[key] Prompt text` group and it becomes a new Y/N question and `--disable` key on every platform.
- **Launchers and add-ons:** edit `common/launchers.conf`. Adding a launcher is a new `type=launcher` section with its package, activity, optional accessibility service and APK source. Adding an add-on is a `type=addon` section with a prompt, an optional `disables=` list of packages it replaces, and the same install fields. Sources are `github:owner/repo` (with an optional `asset_match` glob where `{abi}` stands for the device CPU), `apkmirror:<package>` (browser-assisted, device-matched) or `manual:URL`. No code changes are needed.
- **Environment variables:** `FSC_DOWNLOADS_DIR` (folder your browser saves to), `FSC_BROWSER` (program used to open download pages).

## Project structure

```
.
├── common/
│   ├── firestick-cleanup.sh       # shared Mac/Linux implementation
│   ├── packages.conf              # what to disable (shared by all implementations)
│   └── launchers.conf             # launchers and add-ons (shared by all implementations)
├── windows/
│   ├── Firestick-Cleaner-And-Launcher-Replacer.bat   # double-click entry point
│   ├── Firestick-Cleaner-And-Launcher-Replacer.ps1   # console implementation
│   ├── adb/                                          # bundled Windows ADB
│   └── WinformVer/                                   # GUI (WinForms, .NET Framework 4.8)
├── mac/
│   ├── Firestick-Cleaner-And-Launcher-Replacer.command   # wrapper around common/
│   └── adb/
├── linux/
│   ├── Firestick-Cleaner-And-Launcher-Replacer.sh        # wrapper around common/
│   └── adb/
├── tests/
│   ├── run-e2e.sh                 # end-to-end test against a fake adb (no device needed)
│   ├── fake-adb/                  # the fake adb (adb) and device-side command shims (shims/)
│   └── fixtures/                  # recorded APKMirror metadata used by the test
└── .github/workflows/ci.yml       # shellcheck, e2e test, PowerShell analyzer, WinForms build
```

## Development

```
shellcheck -s bash common/firestick-cleanup.sh
bash tests/run-e2e.sh        # ~3 minutes; simulates a Fire TV and a browser download, needs no network
```

CI runs those plus a PowerShell parse/analyzer pass and a WinForms build whose output is published as a workflow artifact.

## Notes

- Fire OS updates can undo these changes. Run `--reapply` afterwards, or use the `updates` group to block the update services (at the cost of security fixes).
- The stock Amazon launcher keeps running in the background on firmware where it is protected (about 110 MB RAM). The `stocklauncher` group tries to disable it anyway and reports "Protected" when it cannot.
- Each run writes a timestamped `firestick_cleanup_<date>.log` next to the entry point.
- Live-tested on a Fire TV Stick running Fire OS 8.1.8.5 (Android 11, 32-bit) with Couchy + Home on Fire; earlier versions were tested on Fire TV Stick 4K and Fire TV Stick Lite. Please open an issue with your device, Fire OS version and which packages were reported as protected.

## License

MIT. See `LICENSE`.
