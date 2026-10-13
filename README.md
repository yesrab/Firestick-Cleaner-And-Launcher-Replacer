# Firestick Cleanup

![Firestick Cleanup screenshot](screenshot.jpg)

Replace the ad-filled Amazon Fire TV home screen with a launcher of your choice and disable Amazon's tracking, telemetry and bloatware. No root required, fully reversible.

## What it does

1. Connects to your Fire TV over ADB (Wi-Fi) and waits for you to accept the prompt on the TV
2. Installs the launcher you pick: **Projectivy**, **AT4K** or **Couchy**
3. Optionally installs add-ons: **Home on Fire** (makes the Home button open your launcher) and **YouTube for Android TV** (Google's official app in place of Amazon's YouTube wrapper)
4. Asks which optional Amazon apps you want to keep (Music, Photos, Appstore, Prime Video services...)
5. Disables tracking, telemetry, ads and background bloat, plus your optional choices
6. Reboots, verifies, and re-disables anything Amazon re-enabled during the reboot
7. Shows a before/after RAM comparison
8. Records everything it changed, so `--revert` undoes exactly that and nothing else

## Launchers

| Launcher | Home button handling | APK | Notes |
|----------|---------------------|-----|-------|
| [Projectivy Launcher](https://github.com/spocky/miproja1) (default) | Its own accessibility service | Downloaded automatically from GitHub, SHA-256 verified | Feature-rich. After install, enable **Settings > General > Override current launcher** in Projectivy. |
| [AT4K Launcher](https://at4k.com/) | Its own accessibility service | **Not bundled.** Download it yourself and save it next to the script as `AT4K*.apk` or `base.apk` | Lightweight. |
| [Couchy Launcher](https://github.com/conreo/couchy-launcher) | None. Pair it with Home on Fire | Downloaded automatically from GitHub, SHA-256 verified | Minimal, open source, no Google services needed. |

## Add-ons

Add-ons are asked about one by one after the launcher, and can be forced with `--with <key>` or skipped with `--without <key>`. Each add-on is a section in `common/launchers.conf`.

### Home on Fire (`homeonfire`)

[Home on Fire](https://github.com/toolicious/home-on-fire) is a tiny open-source app that intercepts the Home button and opens the launcher you choose. It is **required for Couchy** (which has no Home-button service of its own, so the prompt defaults to yes there) and optional for Projectivy and AT4K, which bring their own. The script downloads and verifies it, grants it the `WRITE_SECURE_SETTINGS` permission and enables its accessibility service. You then pick your launcher once under **Choose target app** inside the app.

Known behaviour from the Home on Fire project: on Fire OS 8 the Amazon home screen flashes briefly before your launcher appears; on Fire OS 7 a Home press can take a few seconds. Long-press Home to get back to the Amazon home screen at any time. Fire OS 6 and older are not supported.

### YouTube for Android TV (`youtubetv`)

Replaces Amazon's Fire TV YouTube wrapper (`com.amazon.firetv.youtube`) with Google's official YouTube for Android TV app (`com.google.android.youtube.tv`), the same app that ships on Android TV and Google TV devices. The script installs the APK, disables the Amazon wrapper so only one YouTube shows in your launcher, and records that so `--revert` puts the Amazon app back.

Google does not publish this APK for direct download, so **you have to supply it**: download the current release from a mirror you trust (for example the [APKMirror listing](https://www.apkmirror.com/apk/google-inc/youtube-for-android-tv/), which checks that uploads carry Google's signature) and save it next to the entry point as `YouTube*.apk`. Pick the newest version whose minimum Android matches your Fire OS (Fire OS 7 is Android 9, Fire OS 8 is Android 11). Sign-in uses the on-screen code at youtube.com/activate; on some Fire OS versions sign-in needs Google services and does not work, but playback works signed out.

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

Options
  --ip <ip[:port]>    Fire TV address (skips the prompt; the last used address is remembered)
  --launcher <key>    projectivy | at4k | couchy   (default: projectivy)
  --with <a,b,..>     Add-ons to install: homeonfire, youtubetv
  --without <a,b,..>  Add-ons to skip (--home-on-fire / --no-home-on-fire are shorthands for homeonfire)
  --disable <a,b,..>  Optional groups to disable, comma-separated (keys from packages.conf)
  -y, --non-interactive
                      Never prompt; requires --ip
```

Examples:

```
# Couchy + Home on Fire + YouTube for Android TV, also disable the video stack and update services, no questions asked
./Firestick-Cleaner-And-Launcher-Replacer.sh --ip 10.0.0.20 --launcher couchy --with homeonfire,youtubetv --disable video,updates -y

# After a Fire OS update put everything back the way it was
./Firestick-Cleaner-And-Launcher-Replacer.sh --ip 10.0.0.20 --reapply -y

# See what would happen without touching the device
./Firestick-Cleaner-And-Launcher-Replacer.sh --dry-run
```

### After a Fire OS update

Updates re-enable packages and sometimes wipe the accessibility settings. Run with `--reapply`: it reads the choices saved for that device, re-disables what came back, and re-applies the launcher and add-on settings without reinstalling anything or asking questions.

### Reverting

`--revert` reads the state file written for the device (`firestick_cleanup_<ip>.state` next to the entry point) and undoes exactly what was recorded: re-enables those packages (including ones an add-on replaced, such as Amazon's YouTube), restores the previous accessibility and notification-listener values, removes the HOME role and overlay permission from the launcher, uninstalls the launcher and the add-ons, and hands the HOME role back to the Amazon launcher. If no state file exists it warns and offers to re-enable every disabled package instead.

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
| `com.amazon.firebat` | **FireBat**: power analytics |
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

## How it works

Amazon protects the stock launcher as a system package on most firmware, so it usually cannot be disabled. Instead, a launcher's **accessibility service** (Projectivy, AT4K) or **Home on Fire** intercepts the Home button and opens your launcher. The script:

1. Installs the APK with `pm install -r` (GitHub downloads are checked against the release's SHA-256 digest)
2. Appends the accessibility service (and notification listener, if any) to the existing `enabled_accessibility_services` secure setting, recording the previous value for revert
3. Grants the overlay permission, assigns the `android.app.role.HOME` role and sets the default home activity
4. Disables packages in one device-side batch per pass; if some are protected it reboots once and retries
5. After the final reboot, re-disables anything that came back
6. Writes every change to `firestick_cleanup_<ip>.state` so `--revert` and `--reapply` know exactly what to touch

## Customising

- **Packages:** edit `common/packages.conf`. Add a line to a group, or add a new `[key] Prompt text` group and it becomes a new Y/N question and `--disable` key on every platform.
- **Launchers and add-ons:** edit `common/launchers.conf`. Adding a launcher is a new `type=launcher` section with its package, activity, optional accessibility service and APK source. Adding an add-on is a `type=addon` section with a prompt, an optional `disables=` list of packages it replaces, and the same install fields. No code changes are needed.

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
│   └── fake-adb/                  # the fake adb (adb) and device-side command shims (shims/)
└── .github/workflows/ci.yml       # shellcheck, e2e test, PowerShell analyzer, WinForms build
```

## Development

```
shellcheck -s bash common/firestick-cleanup.sh
bash tests/run-e2e.sh        # ~1 minute; simulates a Fire TV, needs no network
```

CI runs those plus a PowerShell parse/analyzer pass and a WinForms build whose output is published as a workflow artifact.

## Notes

- Fire OS updates can undo these changes. Run `--reapply` afterwards, or use the `updates` group to block the update services (at the cost of security fixes).
- The stock Amazon launcher keeps running in the background on firmware where it is protected (about 110 MB RAM). The `stocklauncher` group tries to disable it anyway and reports "Protected" when it cannot.
- Each run writes a timestamped `firestick_cleanup_<date>.log` next to the entry point.
- Tested on Fire TV Stick 4K and Fire TV Stick Lite. Please open an issue with your device, Fire OS version and which packages were reported as protected.

## License

MIT. See `LICENSE`.
