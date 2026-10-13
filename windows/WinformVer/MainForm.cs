using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Security.Cryptography.Pkcs;
using System.Security.Cryptography.X509Certificates;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
using System.Web.Script.Serialization;
using System.Windows.Forms;

namespace FirestickCleanup
{
    /// <summary>
    /// WinForms front end. The behaviour mirrors common/firestick-cleanup.sh and
    /// windows/Firestick-Cleaner-And-Launcher-Replacer.ps1 and reads the same
    /// common/packages.conf and common/launchers.conf files.
    /// </summary>
    public partial class MainForm : Form
    {
        private const string Version = "2.0.0";
        private const string DeviceTmp = "/data/local/tmp";
        private const string StockLauncher = "com.amazon.tv.launcher";
        // APKMirror serves app metadata (versions, variants, signing certs) to the open-source APKUpdater
        // app through this endpoint; the key ships inside that app. APKMirror does not allow scripted
        // file downloads, so the download itself happens in the user's browser.
        private const string ApkMirrorApi = "https://www.apkmirror.com/wp-json/apkm/v1/app_exists/";
        private const string ApkMirrorAuth = "Basic YXBpLWFwa3VwZGF0ZXI6cm01cmNmcnVVakt5MDRzTXB5TVBKWFc4";

        private readonly string baseDir;
        private readonly string adbPath;
        private readonly string logFile;
        private readonly string lastIpFile;
        private readonly string downloadDir;
        private readonly string downloadsWatch;

        // Device facts read after connecting; used to pick matching APK variants.
        private int devSdk;
        private string devAbis = "", devRelease = "", devFireOs = "", devModel = "";
        private string expectedVCode = "";

        private sealed class ApkMirrorVariant
        {
            public string Version, VCode, Arches, Sha, Page;
            public int MinApi;
        }

        private List<GroupDef> groups = new List<GroupDef>();
        private List<AppDef> apps = new List<AppDef>();
        private readonly Dictionary<string, CheckBox> groupBoxes = new Dictionary<string, CheckBox>();
        private readonly Dictionary<string, CheckBox> addonBoxes = new Dictionary<string, CheckBox>();

        // Per-run state (set by StartRun on the UI thread before the background work begins).
        private string ip;
        private string target;
        private StateFile state;

        private sealed class Choices
        {
            public AppDef Launcher;
            public List<string> Addons = new List<string>();
            public List<string> Groups = new List<string>();
        }

        public MainForm()
        {
            InitializeComponent();
            baseDir = AppDomain.CurrentDomain.BaseDirectory;
            adbPath = Path.Combine(baseDir, "adb", "adb.exe");
            logFile = Path.Combine(baseDir, "firestick_cleanup_" + DateTime.Now.ToString("yyyyMMdd_HHmmss") + ".log");
            lastIpFile = Path.Combine(baseDir, ".last_ip");
            downloadDir = Path.Combine(baseDir, "downloads");
            downloadsWatch = FindDownloadsFolder();
            Load += MainForm_Load;
        }

        // ------------------------------------------------------------
        // UI setup
        // ------------------------------------------------------------
        private void MainForm_Load(object sender, EventArgs e)
        {
            Text = "Firestick Cleanup " + Version;
            string commonDir = Path.Combine(baseDir, "common");
            try
            {
                groups = Conf.LoadGroups(Path.Combine(commonDir, "packages.conf"));
                apps = Conf.LoadApps(Path.Combine(commonDir, "launchers.conf"));
            }
            catch (Exception ex)
            {
                MessageBox.Show("Could not read the config files in " + commonDir + ":\n" + ex.Message,
                    "Config missing", MessageBoxButtons.OK, MessageBoxIcon.Error);
                Close();
                return;
            }

            pnlAddons.Controls.Clear();
            addonBoxes.Clear();
            foreach (var addon in apps.Where(a => a.IsAddon))
            {
                var cb = new CheckBox { Text = addon.Name + ": " + addon.Summary, AutoSize = true, Tag = addon, Margin = new Padding(4, 2, 4, 2) };
                toolTip.SetToolTip(cb, addon.Prompt);
                pnlAddons.Controls.Add(cb);
                addonBoxes[addon.Key] = cb;
            }

            cmbLauncher.Items.Clear();
            foreach (var app in apps.Where(a => a.IsLauncher)) cmbLauncher.Items.Add(app);
            if (cmbLauncher.Items.Count > 0) cmbLauncher.SelectedIndex = 0;

            pnlOptions.Controls.Clear();
            groupBoxes.Clear();
            foreach (var g in groups)
            {
                if (g.Key == "always") continue;
                var cb = new CheckBox { Text = g.ShortPrompt, AutoSize = true, Tag = g, Margin = new Padding(4, 2, 4, 2) };
                toolTip.SetToolTip(cb, g.Prompt + "\n\n" + string.Join("\n", g.Packages));
                pnlOptions.Controls.Add(cb);
                groupBoxes[g.Key] = cb;
            }

            try { if (File.Exists(lastIpFile)) txtDeviceIP.Text = File.ReadAllLines(lastIpFile).FirstOrDefault() ?? ""; } catch { }
        }

        private void CmbLauncher_SelectedIndexChanged(object sender, EventArgs e)
        {
            var app = cmbLauncher.SelectedItem as AppDef;
            if (app == null) return;
            lblLauncherSummary.Text = app.Summary;
            var needs = app.Needs.ToList();
            foreach (var kv in addonBoxes)
            {
                var addon = (AppDef)kv.Value.Tag;
                kv.Value.Checked = addon.DefaultOn || needs.Contains(kv.Key);
            }
        }

        private Choices ReadChoices()
        {
            var c = new Choices { Launcher = cmbLauncher.SelectedItem as AppDef };
            foreach (var kv in addonBoxes) if (kv.Value.Checked) c.Addons.Add(kv.Key);
            foreach (var kv in groupBoxes) if (kv.Value.Checked) c.Groups.Add(kv.Key);
            return c;
        }

        private bool StartRun()
        {
            string raw = txtDeviceIP.Text.Trim();
            int port = 5555;
            var m = Regex.Match(raw, @"^(.+):(\d+)$");
            if (m.Success) { raw = m.Groups[1].Value; port = int.Parse(m.Groups[2].Value); }
            if (!Regex.IsMatch(raw, @"^(\d{1,3}\.){3}\d{1,3}$") && !Regex.IsMatch(raw, @"^[A-Za-z0-9][A-Za-z0-9.-]*$"))
            {
                MessageBox.Show("Enter a valid IPv4 address or host name (e.g. 10.0.0.20).", "Invalid address", MessageBoxButtons.OK, MessageBoxIcon.Warning);
                return false;
            }
            if (!File.Exists(adbPath))
            {
                MessageBox.Show("ADB not found at:\n" + adbPath, "ADB missing", MessageBoxButtons.OK, MessageBoxIcon.Error);
                return false;
            }
            ip = raw;
            target = raw + ":" + port;
            state = new StateFile(Path.Combine(baseDir, "firestick_cleanup_" + raw + ".state"));
            ResetLog();
            SetButtons(false);
            return true;
        }

        private async Task RunGuarded(Func<Task> work)
        {
            try { await Task.Run(work); }
            catch (Exception ex)
            {
                Log("[!!] " + ex.Message);
                SetStatus("Error: " + ex.Message);
                MessageBox.Show(ex.Message, "Error", MessageBoxButtons.OK, MessageBoxIcon.Error);
            }
            finally { SetButtons(true); }
        }

        private async void BtnStart_Click(object sender, EventArgs e)
        {
            if (!StartRun()) return;
            var choices = ReadChoices();
            await RunGuarded(() => RunInstallAsync(choices));
        }

        private async void BtnReapply_Click(object sender, EventArgs e)
        {
            if (!StartRun()) return;
            var choices = ReadChoices();
            await RunGuarded(() => RunReapplyAsync(choices));
        }

        private async void BtnStatus_Click(object sender, EventArgs e)
        {
            if (!StartRun()) return;
            await RunGuarded(RunStatusAsync);
        }

        private async void BtnTestBoot_Click(object sender, EventArgs e)
        {
            if (!StartRun()) return;
            await RunGuarded(RunTestBootAsync);
        }

        private async Task RunTestBootAsync()
        {
            var launcher = apps.FirstOrDefault(a => a.Key == state.Get("launcher"));
            if (launcher == null) { Log("[!!] No saved state for this device; run Install + Clean first."); return; }
            SetProgress(0, "Connecting...");
            if (!await ConnectAsync()) return;
            SetProgress(20, "Rebooting...");
            if (!await RebootAndReconnectAsync()) { Log("  [!!] Could not reconnect after reboot."); return; }
            int reapplied = await ReapplyDisabledAsync();
            Log(reapplied > 0 ? $"  [OK] Re-disabled {reapplied} packages that came back after the reboot" : "  [OK] All packages stayed disabled after the reboot");
            var addons = state.Get("addons").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries)
                .Select(k => apps.FirstOrDefault(a => a.Key == k)).Where(a => a != null).ToList();
            SetProgress(60, "Verifying...");
            await VerifyAppAsync(launcher);
            foreach (var addon in addons) await VerifyAppAsync(addon);
            await VerifyBootAsync(launcher, addons);
            SetProgress(100, "Boot test complete.");
        }

        private async void BtnRevert_Click(object sender, EventArgs e)
        {
            if (!StartRun()) return;
            await RunGuarded(RunRevertAsync);
        }

        // ------------------------------------------------------------
        // Modes
        // ------------------------------------------------------------
        private async Task RunInstallAsync(Choices c)
        {
            if (c.Launcher == null) { Log("[!!] No launcher selected."); return; }
            SetProgress(0, "Connecting...");
            if (!await ConnectAsync()) return;

            SetProgress(8, "Capturing baseline RAM...");
            var before = await CaptureMemAsync();
            Log($"  RAM: {before.avail} MB available of {before.total} MB, {before.procs} Amazon processes running");

            state.Set("version", Version);
            state.Set("launcher", c.Launcher.Key);
            state.Set("addons", string.Join(",", c.Addons));
            state.Set("groups", string.Join(",", c.Groups));

            SetProgress(15, "Installing " + c.Launcher.Name + "...");
            if (!await SetupAppAsync(c.Launcher)) { SetStatus("Launcher setup failed."); return; }

            var addons = c.Addons.Select(k => apps.FirstOrDefault(a => a.Key == k)).Where(a => a != null).ToList();
            int step = 0;
            foreach (var addon in addons)
            {
                SetProgress(30 + 20 * step++ / Math.Max(1, addons.Count), "Installing " + addon.Name + "...");
                if (!await SetupAppAsync(addon)) { SetStatus(addon.Name + " setup failed."); return; }
            }

            SetProgress(55, "Disabling bloatware...");
            var bloat = BuildBloatList(c.Groups);
            var split = await ClassifyAsync(bloat);
            int totalDisabled = 0, totalProtected = 0, passes = 0;
            if (split.present.Count > 0)
            {
                var r = await DisablePassesAsync(split.present);
                totalDisabled = r.disabled; totalProtected = r.protectedCount; passes = r.passes;
            }
            else Log("  [..] Nothing new to disable.");
            if (split.absent.Count > 0) Log($"  [..] {split.absent.Count} packages are not on this device and were skipped.");

            if (passes <= 1)
            {
                SetProgress(80, "Rebooting to apply changes...");
                if (!await RebootAndReconnectAsync()) { Log("  [!!] Could not reconnect after reboot."); return; }
            }
            int reapplied = await ReapplyDisabledAsync();
            Log(reapplied > 0 ? $"  [OK] Re-disabled {reapplied} packages that came back after the reboot"
                              : "  [OK] All packages stayed disabled after the reboot");

            SetProgress(92, "Verifying...");
            await VerifyAppAsync(c.Launcher);
            foreach (var addon in addons) await VerifyAppAsync(addon);
            Log($"  [OK] {(await DisabledNowAsync()).Count} packages are disabled on the device");
            await VerifyBootAsync(c.Launcher, addons);

            var after = await CaptureMemAsync();
            int freed = after.avail - before.avail;
            Log("");
            Log("                    BEFORE      AFTER");
            Log($"  Available RAM:    {before.avail,4} MB    {after.avail,4} MB   (+{freed} MB freed)");
            Log($"  Amazon processes: {before.procs,4}        {after.procs,4}       (-{before.procs - after.procs})");
            Log("");
            Log($"  ALL DONE: {c.Launcher.Name}, add-ons: {(c.Addons.Count > 0 ? string.Join(",", c.Addons) : "none")}, {totalDisabled} packages disabled ({totalProtected} protected), {freed} MB freed.");
            Log($"  State saved to {state.Path}. Use Re-apply after a Fire OS update, Revert to undo.");
            SetProgress(100, $"Done: {totalDisabled} packages disabled, {freed} MB freed.");
        }

        private async Task RunReapplyAsync(Choices c)
        {
            SetProgress(0, "Connecting...");
            if (!await ConnectAsync()) return;
            var groupsToUse = state.Exists && c.Groups.Count == 0
                ? state.Get("groups").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries).ToList()
                : c.Groups;
            Log("  [..] Groups: " + (groupsToUse.Count > 0 ? string.Join(",", groupsToUse) : "none"));
            state.Set("groups", string.Join(",", groupsToUse));

            SetProgress(20, "Disabling bloatware...");
            var split = await ClassifyAsync(BuildBloatList(groupsToUse));
            int disabled = 0, prot = 0;
            if (split.present.Count > 0)
            {
                var r = await DisablePassesAsync(split.present);
                disabled = r.disabled; prot = r.protectedCount;
                if (r.passes <= 1 && r.disabled > 0)
                {
                    SetProgress(70, "Rebooting to apply changes...");
                    if (!await RebootAndReconnectAsync()) { Log("  [!!] Could not reconnect after reboot."); return; }
                    await ReapplyDisabledAsync();
                }
            }
            else Log("  [OK] Everything is already disabled; nothing to do.");

            SetProgress(85, "Re-applying launcher settings...");
            var launcher = apps.FirstOrDefault(a => a.Key == state.Get("launcher"));
            if (launcher != null && await IsInstalledAsync(launcher.Package))
            {
                if (await ConfigureAppAsync(launcher)) Log($"  [OK] {launcher.Name} settings re-applied");
            }
            foreach (var key in state.Get("addons").Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries))
            {
                var addon = apps.FirstOrDefault(a => a.Key == key);
                if (addon != null && await IsInstalledAsync(addon.Package))
                {
                    if (await ConfigureAppAsync(addon)) Log($"  [OK] {addon.Name} settings re-applied");
                }
            }
            SetProgress(100, $"Re-apply complete: {disabled} disabled, {prot} protected.");
        }

        private async Task RunStatusAsync()
        {
            SetProgress(0, "Connecting...");
            if (!await ConnectAsync()) return;
            SetProgress(50, "Reading device state...");
            string acc = (await DshAsync("settings", "get", "secure", "enabled_accessibility_services")).Trim();
            string role = await HomeRoleHolderAsync();
            var disabled = await DisabledNowAsync();
            foreach (var app in apps)
            {
                if (await IsInstalledAsync(app.Package))
                {
                    string extra = "";
                    if (acc.Contains(app.Package)) extra += ", accessibility service on";
                    if (role.Contains(app.Package)) extra += ", holds HOME role";
                    Log($"  [OK] {app.Name}: installed{extra}");
                }
                else Log($"  [--] {app.Name}: not installed");
            }
            Log("");
            Log("  HOME role holder:        " + (role.Length > 0 ? role : "unknown"));
            Log("  Accessibility services:  " + (acc.Length > 0 && acc != "null" ? acc : "none"));
            Log("  Disabled packages:       " + disabled.Count);
            foreach (var d in disabled) Log("      " + d);
            Log("");
            if (state.Exists)
            {
                Log($"  Saved state ({state.Path}):");
                Log($"      launcher={state.Get("launcher")} addons={state.Get("addons")} groups={state.Get("groups")}");
                Log($"      recorded as disabled by this tool: {state.GetAll("disabled").Count}");
            }
            else Log("  No saved state for this device (nothing recorded by this tool yet).");
            SetProgress(100, "Status read.");
        }

        private async Task RunRevertAsync()
        {
            List<string> pkgs;
            if (state.Exists)
            {
                if (!Confirm("Re-enable the packages this tool disabled, remove the launcher and Home on Fire, and restore stock settings?", "Revert")) { SetButtons(true); return; }
            }
            else
            {
                if (!Confirm("No saved state was found for this device.\n\nRevert will re-enable EVERY disabled package, including any you disabled yourself, and remove all known launchers. Continue?", "Revert")) { SetButtons(true); return; }
            }
            SetProgress(0, "Connecting...");
            if (!await ConnectAsync()) return;

            pkgs = state.Exists ? state.GetAll("disabled") : await DisabledNowAsync();
            SetProgress(20, "Re-enabling packages...");
            if (pkgs.Count > 0)
            {
                Log($"  [..] Re-enabling {pkgs.Count} packages...");
                foreach (var kv in await EnableBatchAsync(pkgs))
                    Log(kv.Value ? $"  [OK] Enabled: {kv.Key}" : $"  [--] Could not enable: {kv.Key}");
            }
            else Log("  [..] No packages to re-enable.");

            SetProgress(60, "Restoring settings...");
            await RestoreSecureSettingAsync("enabled_accessibility_services");
            await RestoreSecureSettingAsync("enabled_notification_listeners");
            string accNow = (await DshAsync("settings", "get", "secure", "enabled_accessibility_services")).Trim();
            if (accNow.Length == 0 || accNow == "null") await DshAsync("settings", "put", "secure", "accessibility_enabled", "0");
            Log("  [OK] Accessibility and notification listener settings restored");

            SetProgress(75, "Removing apps...");
            var toRemove = state.Exists ? state.GetAll("installed") : apps.Select(a => a.Package).ToList();
            foreach (var pkg in toRemove)
            {
                if (!await IsInstalledAsync(pkg)) continue;
                await DshAsync("appops", "set", pkg, "SYSTEM_ALERT_WINDOW", "default");
                await DshAsync("cmd", "role", "remove-role-holder", "android.app.role.HOME", pkg);
                var un = await DshAsync("pm", "uninstall", pkg);
                Log(un.Contains("Success") ? $"  [OK] Uninstalled: {pkg}" : $"  [--] Could not uninstall {pkg}");
            }
            await DshAsync("cmd", "role", "add-role-holder", "android.app.role.HOME", StockLauncher);
            Log("  [OK] HOME role returned to the Amazon launcher");
            state.Delete();
            SetProgress(100, "Revert complete.");
        }

        // ------------------------------------------------------------
        // Connection and device helpers
        // ------------------------------------------------------------
        private async Task<bool> ConnectAsync()
        {
            await RunAdb("disconnect");
            Log("  [..] Sending connection request (accept the prompt on your TV if it appears)...");
            var sw = Stopwatch.StartNew();
            bool hinted = false;
            while (sw.Elapsed.TotalSeconds < 120)
            {
                await RunAdb("connect", target);
                string st = await DeviceStateAsync();
                if (st == "device")
                {
                    if ((await DshAsync("echo", "fsc_ok")).Contains("fsc_ok"))
                    {
                        Log($"  [OK] Connected to {target}");
                        try { File.WriteAllText(lastIpFile, ip); } catch { }
                        await ReadDeviceInfoAsync();
                        return true;
                    }
                }
                else if (st == "unauthorized" && !hinted)
                {
                    hinted = true;
                    SetStatus("Waiting for you to accept the prompt on the TV...");
                    Log("  Look at your TV: select 'Always allow from this computer' and press OK.");
                }
                await Task.Delay(2000);
            }
            Log("  [!!] Could not connect. Check the network, that ADB Debugging is enabled, and that you accepted the prompt on the TV.");
            SetStatus("Connection failed.");
            return false;
        }

        private async Task ReadDeviceInfoAsync()
        {
            var sdk = Regex.Replace(await DshAsync("getprop", "ro.build.version.sdk"), @"\D", "");
            int.TryParse(sdk, out devSdk);
            devRelease = (await DshAsync("getprop", "ro.build.version.release")).Trim();
            devFireOs = (await DshAsync("getprop", "ro.build.version.fireos")).Trim();
            devAbis = (await DshAsync("getprop", "ro.product.cpu.abilist")).Trim();
            if (devAbis.Length == 0) devAbis = (await DshAsync("getprop", "ro.product.cpu.abi")).Trim();
            devModel = (await DshAsync("getprop", "ro.product.model")).Trim();
            Log($"  [OK] Device: {(devModel.Length > 0 ? devModel : "unknown model")}, Fire OS {(devFireOs.Length > 0 ? devFireOs : "?")} (Android {(devRelease.Length > 0 ? devRelease : "?")}, API {devSdk}), CPU: {(devAbis.Length > 0 ? devAbis : "?")}");
        }

        private static string FindDownloadsFolder()
        {
            var env = Environment.GetEnvironmentVariable("FSC_DOWNLOADS_DIR");
            if (!string.IsNullOrEmpty(env)) return env;
            try
            {
                using (var key = Microsoft.Win32.Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Explorer\Shell Folders"))
                {
                    var v = key?.GetValue("{374DE290-123F-4565-9164-39C4925E467B}") as string;
                    if (!string.IsNullOrEmpty(v)) return v;
                }
            }
            catch { }
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        }

        private async Task<string> DeviceStateAsync()
        {
            var (_, output) = await RunAdb("devices");
            foreach (var line in output.Split('\n'))
            {
                var m = Regex.Match(line, "^" + Regex.Escape(target) + @"\s+(\S+)");
                if (m.Success) return m.Groups[1].Value;
            }
            return "";
        }

        private async Task<bool> RebootAndReconnectAsync()
        {
            // The package manager persists package state asynchronously; rebooting straight after
            // a batch of pm commands loses the last few changes.
            Log("  [..] Letting the Fire TV save its package state...");
            await Task.Delay(15000);
            // Best effort: ask Fire OS to keep ADB debugging enabled across the reboot.
            await DshAsync("settings", "put", "global", "adb_enabled", "1");
            await DshAsync("settings", "put", "global", "adb_wifi_enabled", "1");
            Log("  [..] Rebooting Fire TV...");
            await DshAsync("reboot");
            await Task.Delay(20000);
            if (await WaitForDeviceAsync(180)) { Log("  [OK] Device is back online"); return true; }
            // Some Fire OS builds switch ADB debugging off at boot; let the user turn it back on.
            while (true)
            {
                Log("  [--] The Fire TV did not come back on ADB. Fire OS can switch ADB Debugging off at boot.");
                if (!Confirm("The Fire TV did not come back on ADB. Fire OS can switch ADB Debugging off at boot.\n\n" +
                             "On the TV: Settings > My Fire TV > Developer Options > ADB Debugging > ON\n" +
                             "(then accept the 'Allow USB debugging' prompt again if it appears)\n\n" +
                             "Click OK once ADB Debugging is on again to reconnect.", "ADB is off")) return false;
                if (await WaitForDeviceAsync(120)) { Log("  [OK] Device is back online"); return true; }
            }
        }

        private async Task<bool> WaitForDeviceAsync(int timeoutSeconds)
        {
            var sw = Stopwatch.StartNew();
            while (sw.Elapsed.TotalSeconds < timeoutSeconds)
            {
                await RunAdb("connect", target);
                if (await DeviceStateAsync() == "device" && (await DshAsync("echo", "fsc_ok")).Contains("fsc_ok"))
                {
                    await Task.Delay(5000);
                    return true;
                }
                await Task.Delay(2000);
            }
            return false;
        }

        private async Task<(int total, int avail, int procs)> CaptureMemAsync()
        {
            string t = await DshAsync("grep MemTotal /proc/meminfo");
            string a = await DshAsync("grep MemAvailable /proc/meminfo");
            string p = await DshAsync("(ps -A 2>/dev/null || ps) | grep -c com.amazon");
            int procs = 0;
            var m = Regex.Match(p, @"\d+");
            if (m.Success) int.TryParse(m.Value, out procs);
            return (ParseKbToMb(t), ParseKbToMb(a), procs);
        }

        private async Task<bool> IsInstalledAsync(string pkg) => (await DshAsync("pm", "path", pkg)).Contains("package:");

        private async Task<List<string>> DisabledNowAsync()
        {
            var output = await DshAsync("pm", "list", "packages", "-d");
            return output.Split('\n').Select(l => l.Trim()).Where(l => l.StartsWith("package:")).Select(l => l.Substring(8)).ToList();
        }

        private async Task EnableSecureListAsync(string setting, string component, string pkg)
        {
            string cur = (await DshAsync("settings", "get", "secure", setting)).Trim();
            if (cur == "null") cur = "";
            if (!state.Has("prev_" + setting)) state.Set("prev_" + setting, cur);
            string next;
            if (cur.Contains(pkg + "/")) next = cur;
            else if (cur.Length == 0) next = component;
            else next = cur + ":" + component;
            if (next != cur) await DshAsync("settings", "put", "secure", setting, next);
        }

        private async Task RestoreSecureSettingAsync(string setting)
        {
            if (state.Has("prev_" + setting))
            {
                string prev = state.Get("prev_" + setting);
                if (prev.Length == 0) await DshAsync("settings", "delete", "secure", setting);
                else await DshAsync("settings", "put", "secure", setting, prev);
            }
            else await DshAsync("settings", "delete", "secure", setting);
        }

        // ------------------------------------------------------------
        // APK download / install / configure
        // ------------------------------------------------------------
        private async Task<string> FetchApkAsync(AppDef app)
        {
            expectedVCode = "";
            foreach (var glob in app.ApkGlobs)
            {
                var local = Directory.GetFiles(baseDir, glob).FirstOrDefault();
                if (local != null) { Log("  [OK] Using local APK: " + Path.GetFileName(local)); return local; }
            }
            if (app.Source.StartsWith("manual:"))
            {
                Log($"  [!!] {app.Name} has to be downloaded by hand from {app.Source.Substring(7)}");
                Log($"       Save the APK in: {baseDir}");
                Log($"       Accepted file names: {string.Join(" ", app.ApkGlobs)}");
                ShowMessage($"{app.Name} is not bundled and cannot be downloaded automatically.\n\nDownload it from {app.Source.Substring(7)} and save it in:\n{baseDir}\n\nAccepted file names: {string.Join(" ", app.ApkGlobs)}", "APK needed");
                return null;
            }
            if (app.Source.StartsWith("apkmirror:")) return await FetchApkMirrorAsync(app, app.Source.Substring(10));
            if (!app.Source.StartsWith("github:")) { Log("  [!!] Unknown source for " + app.Name); return null; }

            Log($"  [..] Fetching latest {app.Name} release from GitHub...");
            string url = null, sha = "";
            try
            {
                ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                using (var http = new HttpClient())
                {
                    http.DefaultRequestHeaders.UserAgent.ParseAdd("firestick-cleanup/" + Version);
                    string json = await http.GetStringAsync("https://api.github.com/repos/" + app.Source.Substring(7) + "/releases/latest");
                    var rel = new JavaScriptSerializer().Deserialize<Dictionary<string, object>>(json);
                    var assets = (rel["assets"] as System.Collections.ArrayList ?? new System.Collections.ArrayList())
                        .Cast<Dictionary<string, object>>().ToList();
                    string pattern = app.AssetMatch.Length > 0 ? app.AssetMatch : "*.apk";
                    var cands = pattern.Contains("{abi}")
                        ? AbiCandidates().Select(a => pattern.Replace("{abi}", a)).ToList()
                        : new List<string> { pattern };
                    foreach (var c in cands)
                    {
                        var re = GlobToRegex(c);
                        var a = assets.FirstOrDefault(x => x.ContainsKey("name") && re.IsMatch(x["name"].ToString()));
                        if (a == null) continue;
                        url = a["browser_download_url"].ToString();
                        object dg;
                        if (a.TryGetValue("digest", out dg) && dg != null)
                        {
                            var d = Regex.Match(dg.ToString(), @"^sha256:([0-9a-f]+)$");
                            if (d.Success) sha = d.Groups[1].Value;
                        }
                        Log("  [..] Release asset: " + a["name"]);
                        break;
                    }
                }
            }
            catch (Exception ex) { Log("  [--] Could not query GitHub (" + ex.Message + ")."); }
            if (url == null)
            {
                if (app.FallbackUrl.Length == 0) { Log("  [!!] Could not query GitHub releases for " + app.Name); return null; }
                Log("  [--] Using known-good fallback URL.");
                url = app.FallbackUrl;
            }

            Directory.CreateDirectory(downloadDir);
            string apk = Path.Combine(downloadDir, Path.GetFileName(new Uri(url).AbsolutePath));
            if (File.Exists(apk) && sha.Length > 0 && Sha256(apk) == sha)
            {
                Log("  [OK] Already downloaded and verified: " + Path.GetFileName(apk));
                return apk;
            }
            Log("  [..] Downloading " + Path.GetFileName(apk));
            try
            {
                using (var http = new HttpClient())
                using (var resp = await http.GetAsync(url, HttpCompletionOption.ResponseHeadersRead))
                {
                    resp.EnsureSuccessStatusCode();
                    using (var src = await resp.Content.ReadAsStreamAsync())
                    using (var dst = File.Create(apk))
                        await src.CopyToAsync(dst);
                }
            }
            catch (Exception ex)
            {
                Log("  [!!] Download failed: " + ex.Message);
                try { File.Delete(apk); } catch { }
                return null;
            }
            long size = new FileInfo(apk).Length;
            if (size < 100000) { Log("  [!!] Downloaded file is too small to be an APK."); File.Delete(apk); return null; }
            if (sha.Length > 0)
            {
                if (Sha256(apk) != sha) { Log("  [!!] SHA-256 mismatch; discarding download."); File.Delete(apk); return null; }
                Log($"  [OK] Downloaded ({HumanSize(size)}), SHA-256 verified");
            }
            else Log($"  [OK] Downloaded ({HumanSize(size)})");
            return apk;
        }

        private IEnumerable<string> AbiCandidates()
        {
            foreach (var a in devAbis.Split(new[] { ',' }, StringSplitOptions.RemoveEmptyEntries)) yield return a.Trim();
            yield return "universal";
        }

        private static Regex GlobToRegex(string glob) =>
            new Regex("^" + Regex.Escape(glob).Replace(@"\*", ".*").Replace(@"\?", ".") + "$", RegexOptions.IgnoreCase);

        /// <summary>Asks APKMirror's metadata API for the newest variant that fits this device.</summary>
        private async Task<ApkMirrorVariant> ApkMirrorLookupAsync(string pkg)
        {
            string json;
            try
            {
                var fixture = Environment.GetEnvironmentVariable("FSC_APKMIRROR_JSON");
                if (!string.IsNullOrEmpty(fixture)) json = File.ReadAllText(fixture);
                else
                {
                    ServicePointManager.SecurityProtocol |= SecurityProtocolType.Tls12;
                    using (var http = new HttpClient())
                    {
                        http.DefaultRequestHeaders.TryAddWithoutValidation("Authorization", ApkMirrorAuth);
                        http.DefaultRequestHeaders.UserAgent.ParseAdd("APKUpdater-v3.0.3");
                        var body = new StringContent("{\"pnames\":[\"" + pkg + "\"]}", Encoding.UTF8, "application/json");
                        using (var resp = await http.PostAsync(ApkMirrorApi, body))
                        {
                            resp.EnsureSuccessStatusCode();
                            json = await resp.Content.ReadAsStringAsync();
                        }
                    }
                }
                var root = new JavaScriptSerializer { MaxJsonLength = int.MaxValue }.Deserialize<Dictionary<string, object>>(json);
                var data = (root["data"] as System.Collections.ArrayList ?? new System.Collections.ArrayList()).Cast<Dictionary<string, object>>();
                var item = data.FirstOrDefault(d => d.ContainsKey("pname") && d["pname"].ToString() == pkg);
                if (item == null || !(item["exists"] is bool) || !(bool)item["exists"]) return null;
                var abis = AbiCandidates().ToList();
                Dictionary<string, object> best = null;
                int bestScore = -1;
                foreach (var a in (item["apks"] as System.Collections.ArrayList ?? new System.Collections.ArrayList()).Cast<Dictionary<string, object>>())
                {
                    int minapi; int.TryParse(a["minapi"].ToString(), out minapi);
                    if (devSdk > 0 && minapi > devSdk) continue;
                    var arches = (a["arches"] as System.Collections.ArrayList ?? new System.Collections.ArrayList()).Cast<object>().Select(x => x.ToString()).ToList();
                    bool fits = arches.Count == 0; int arm64 = 0;
                    foreach (var ar in arches)
                    {
                        if (ar == "universal" || ar == "noarch" || abis.Contains(ar)) { fits = true; if (ar == "arm64-v8a") arm64 = 1; }
                    }
                    if (!fits) continue;
                    var dpis = (a["dpis"] as System.Collections.ArrayList ?? new System.Collections.ArrayList()).Cast<object>().Select(x => x.ToString());
                    int score = minapi * 10 + arm64 * 5 + (dpis.Contains("nodpi") ? 1 : 0);
                    if (score > bestScore) { bestScore = score; best = a; }
                }
                if (best == null) return null;
                var release = item["release"] as Dictionary<string, object>;
                var shas = best.ContainsKey("signatures-sha256") ? best["signatures-sha256"] as System.Collections.ArrayList : null;
                int bestMin; int.TryParse(best["minapi"].ToString(), out bestMin);
                return new ApkMirrorVariant
                {
                    Version = release != null && release.ContainsKey("version") ? release["version"].ToString() : "",
                    VCode = best["version_code"].ToString(),
                    MinApi = bestMin,
                    Arches = string.Join(",", (best["arches"] as System.Collections.ArrayList ?? new System.Collections.ArrayList()).Cast<object>()),
                    Sha = shas != null && shas.Count > 0 ? shas[0].ToString() : "",
                    Page = "https://www.apkmirror.com" + best["link"]
                };
            }
            catch (Exception ex) { Log("  [--] APKMirror lookup failed: " + ex.Message); return null; }
        }

        /// <summary>Browser-assisted APKMirror download: opens the matching variant page and waits for the file.</summary>
        private async Task<string> FetchApkMirrorAsync(AppDef app, string pkg)
        {
            expectedVCode = "";
            Log($"  [..] Looking up {app.Name} on APKMirror for Android API {devSdk} ({(devAbis.Length > 0 ? devAbis : "unknown CPU")})...");
            var v = await ApkMirrorLookupAsync(pkg);
            string page;
            if (v != null)
            {
                Log($"  [OK] Latest: {app.Name} {v.Version} (build {v.VCode}, min API {v.MinApi}, {v.Arches})");
                page = v.Page;
                Directory.CreateDirectory(downloadDir);
                var cached = Directory.GetFiles(downloadDir, pkg + "_*.apk")
                    .FirstOrDefault(f => Path.GetFileName(f).Contains("-" + v.VCode + "_") || Path.GetFileName(f).EndsWith("-" + v.VCode + ".apk"));
                if (cached != null) { expectedVCode = v.VCode; Log("  [OK] Already downloaded: " + Path.GetFileName(cached)); return cached; }
            }
            else
            {
                Log($"  [--] Could not query APKMirror; pick a version yourself (min Android API {devSdk} or lower).");
                page = app.Page;
                if (page.Length == 0) { Log("  [!!] No APKMirror page configured for " + app.Name); return null; }
            }
            ShowMessage(
                "APKMirror does not let programs download files, so your browser will open on the download page for " +
                app.Name + (v != null ? " " + v.Version : "") + " that matches this Fire TV.\n\n" +
                "Click DOWNLOAD APK there (and the 'here' link if nothing starts).\n\n" +
                "This window keeps watching " + downloadsWatch + " and continues automatically once the file arrives.",
                "One click needed in your browser");
            var since = DateTime.Now;
            try { Process.Start(page); } catch (Exception ex) { Log("  [--] Could not open the browser (" + ex.Message + "). Open this URL yourself: " + page); }
            SetStatus("Waiting for the APK to appear in " + downloadsWatch + "...");
            string found = await WaitForDownloadAsync(pkg, since, TimeSpan.FromMinutes(15));
            if (found == null) { Log($"  [!!] No {pkg}_*.apk appeared within 15 minutes. Save it in {baseDir} and run again."); return null; }
            Directory.CreateDirectory(downloadDir);
            string apk = Path.Combine(downloadDir, Path.GetFileName(found));
            if (!string.Equals(found, apk, StringComparison.OrdinalIgnoreCase))
            {
                if (File.Exists(apk)) File.Delete(apk);
                File.Move(found, apk);
            }
            Log($"  [OK] Got {Path.GetFileName(apk)} ({HumanSize(new FileInfo(apk).Length)})");
            if (!VerifyApk(apk, v != null ? v.Sha : "")) return null;
            if (v != null) expectedVCode = v.VCode;
            return apk;
        }

        private async Task<string> WaitForDownloadAsync(string pkg, DateTime since, TimeSpan timeout)
        {
            var sw = Stopwatch.StartNew();
            while (sw.Elapsed < timeout)
            {
                foreach (var dir in new[] { downloadsWatch, baseDir })
                {
                    string f = null;
                    try { f = Directory.Exists(dir) ? Directory.GetFiles(dir, pkg + "_*.apk").FirstOrDefault(x => File.GetLastWriteTime(x) > since) : null; } catch { }
                    if (f == null) continue;
                    long size1 = new FileInfo(f).Length;
                    await Task.Delay(2000);
                    long size2 = new FileInfo(f).Length;
                    if (size1 == size2 && size1 > 100000 && !File.Exists(f + ".crdownload") && !File.Exists(f + ".part")) return f;
                }
                await Task.Delay(2000);
            }
            return null;
        }

        /// <summary>Checks the zip magic and, when a v1 signature is present, the signing certificate's SHA-256.</summary>
        private bool VerifyApk(string file, string wantSha)
        {
            try
            {
                using (var fs = File.OpenRead(file))
                {
                    if (fs.Length < 2 || fs.ReadByte() != 0x50 || fs.ReadByte() != 0x4B) { Log($"  [!!] {Path.GetFileName(file)} is not an APK (not a zip file)."); return false; }
                }
            }
            catch (Exception ex) { Log("  [!!] Cannot read " + file + ": " + ex.Message); return false; }
            if (string.IsNullOrEmpty(wantSha)) return true;
            string got = ApkV1CertSha256(file);
            if (got == null) { Log("  [..] APK has no readable v1 signature block; the signing certificate cannot be checked here."); return true; }
            if (got != wantSha) { Log($"  [!!] Signing certificate mismatch (expected {wantSha}, got {got}). Refusing to install."); return false; }
            Log("  [OK] Signing certificate matches APKMirror's record for this app");
            return true;
        }

        private static string ApkV1CertSha256(string file)
        {
            try
            {
                using (var zip = System.IO.Compression.ZipFile.OpenRead(file))
                {
                    var entry = zip.Entries.FirstOrDefault(e => Regex.IsMatch(e.FullName, @"^META-INF/[^/]+\.(RSA|DSA|EC)$", RegexOptions.IgnoreCase));
                    if (entry == null) return null;
                    using (var st = entry.Open())
                    using (var ms = new MemoryStream())
                    {
                        st.CopyTo(ms);
                        var cms = new SignedCms();
                        cms.Decode(ms.ToArray());
                        X509Certificate2 cert = cms.SignerInfos.Count > 0 ? cms.SignerInfos[0].Certificate : null;
                        if (cert == null && cms.Certificates.Count > 0) cert = cms.Certificates[0];
                        if (cert == null) return null;
                        using (var sha = SHA256.Create())
                            return BitConverter.ToString(sha.ComputeHash(cert.RawData)).Replace("-", "").ToLowerInvariant();
                    }
                }
            }
            catch { return null; }
        }

        private async Task<bool> InstallApkAsync(AppDef app, string apk)
        {
            if (await IsInstalledAsync(app.Package)) Log($"  [..] {app.Name} is already installed; updating in place.");
            Log("  [..] Pushing APK to device...");
            var (_, push) = await RunAdb("-s", target, "push", apk, DeviceTmp + "/fsc_install.apk");
            if (!push.Contains("pushed")) { Log("  [!!] Failed to push APK: " + push); return false; }
            Log("  [..] Installing...");
            var inst = await DshAsync("pm", "install", "-r", DeviceTmp + "/fsc_install.apk");
            await DshAsync("rm", "-f", DeviceTmp + "/fsc_install.apk");
            if (!inst.Contains("Success")) { Log("  [!!] Install failed: " + inst); return false; }
            if (!await IsInstalledAsync(app.Package)) { Log($"  [!!] Install reported success but {app.Package} is not on the device."); return false; }
            Log($"  [OK] {app.Name} installed");
            if (expectedVCode.Length > 0)
            {
                var m = Regex.Match(await DshAsync("dumpsys", "package", app.Package), @"versionCode=(\d+)");
                if (m.Success)
                    Log(m.Groups[1].Value == expectedVCode ? $"  [OK] Installed build {m.Groups[1].Value}"
                                                           : $"  [--] Installed build {m.Groups[1].Value} differs from the expected build {expectedVCode}");
                expectedVCode = "";
            }
            state.AddUnique("installed", app.Package);
            return true;
        }

        private async Task<bool> ConfigureAppAsync(AppDef app)
        {
            foreach (var perm in app.Grants)
            {
                await DshAsync("pm", "grant", app.Package, perm);
                Log("  [OK] Granted " + perm.Substring(perm.LastIndexOf('.') + 1));
            }
            if (app.Accessibility.Length > 0)
            {
                await EnableSecureListAsync("enabled_accessibility_services", app.Accessibility, app.Package);
                await DshAsync("settings", "put", "secure", "accessibility_enabled", "1");
                if ((await DshAsync("settings", "get", "secure", "enabled_accessibility_services")).Contains(app.Package))
                    Log("  [OK] Accessibility service enabled");
                else { Log("  [!!] Could not enable the accessibility service for " + app.Package); return false; }
            }
            if (app.NotificationListener.Length > 0)
            {
                await EnableSecureListAsync("enabled_notification_listeners", app.NotificationListener, app.Package);
                Log("  [OK] Notification listener enabled");
            }
            foreach (var op in app.AppOps)
            {
                await DshAsync("appops", "set", app.Package, op, "allow");
                Log("  [OK] App op " + op + " allowed");
            }
            if (app.StartsAtBoot) await PrepareBootAsync(app);
            if (app.IsLauncher)
            {
                await DshAsync("cmd", "role", "add-role-holder", "android.app.role.HOME", app.Package);
                Log("  [OK] HOME role assigned");
                await DshAsync("cmd", "package", "set-home-activity", "--user", "0", app.Activity);
                Log("  [OK] Default home activity set");
            }
            await DisableReplacedPackagesAsync(app);
            await LaunchAppAsync(app);
            return true;
        }

        private async Task LaunchAppAsync(AppDef app)
        {
            if (app.Activity.Length > 0)
            {
                var launch = await DshAsync("am", "start", "-n", app.Activity);
                if (!launch.Contains("Error")) { Log($"  [OK] {app.Name} launched"); return; }
            }
            // No activity configured, or it failed: resolve the app's leanback launcher entry instead.
            var monkey = await DshAsync("monkey", "-p", app.Package, "-c", "android.intent.category.LEANBACK_LAUNCHER", "1");
            Log(monkey.Contains("Events injected") ? $"  [OK] {app.Name} launched" : $"  [--] Could not launch {app.Name} automatically; open it from the Fire TV app list.");
        }

        /// <summary>Disables the packages an add-on replaces (its "disables=" line), recording them for revert.</summary>
        private async Task DisableReplacedPackagesAsync(AppDef app)
        {
            var wanted = app.Disables.ToList();
            if (wanted.Count == 0) return;
            var now = (await DisabledNowAsync()).ToHashSet();
            var pkgs = new List<string>();
            foreach (var p in wanted)
            {
                if (now.Contains(p)) Log($"  [..] {p} is already disabled");
                else if (await IsInstalledAsync(p)) pkgs.Add(p);
                else Log($"  [..] {p} is not on this device");
            }
            if (pkgs.Count == 0) return;
            foreach (var kv in await DisableBatchAsync(pkgs))
            {
                if (kv.Value == "disabled") { Log($"  [OK] Disabled: {kv.Key} (replaced by {app.Name})"); state.AddUnique("disabled", kv.Key); }
                else Log($"  [--] Could not disable {kv.Key} ({kv.Value})");
            }
        }

        /// <summary>Keeps an app's boot receiver and accessibility service from being throttled. Best effort per firmware.</summary>
        private async Task PrepareBootAsync(AppDef app)
        {
            await DshAsync("dumpsys", "deviceidle", "whitelist", "+" + app.Package);
            await DshAsync("appops", "set", app.Package, "RUN_IN_BACKGROUND", "allow");
            await DshAsync("appops", "set", app.Package, "RUN_ANY_IN_BACKGROUND", "allow");
            await DshAsync("am", "set-standby-bucket", app.Package, "active");
            if ((await DshAsync("dumpsys", "deviceidle", "whitelist")).Contains(app.Package)) Log("  [OK] Allowed to run at boot and in the background");
            else Log($"  [..] Could not add {app.Package} to the doze whitelist (not supported on this firmware)");
        }

        /// <summary>Package holding the HOME role. Android 12+ has get-role-holders; older firmware is asked who resolves HOME.</summary>
        private async Task<string> HomeRoleHolderAsync()
        {
            string out = (await DshAsync("cmd", "role", "get-role-holders", "android.app.role.HOME")).Trim();
            if (out.Length == 0 || Regex.IsMatch(out, "Unknown command|Error|Exception"))
            {
                // Android 11: read the role dump ("name=android.app.role.HOME" then "holders=pkg").
                out = "";
                bool found = false;
                foreach (var l in (await DshAsync("dumpsys", "role")).Split('\n'))
                {
                    if (Regex.IsMatch(l, @"name=android\.app\.role\.HOME\s*$")) { found = true; continue; }
                    if (!found) continue;
                    var m = Regex.Match(l, "holders=(.*)$");
                    if (m.Success) { out = m.Groups[1].Value.Trim(); break; }
                }
            }
            return Regex.Replace(out.Split('\n')[0], "[/;,].*$", "");
        }

        private async Task<string> ForegroundPackageAsync()
        {
            string line = await DshAsync("dumpsys window 2>/dev/null | grep -m1 mCurrentFocus");
            if (line.Trim().Length == 0) line = await DshAsync("dumpsys activity activities 2>/dev/null | grep -m1 mResumedActivity");
            var m = Regex.Match(line, @" u\d+ ([A-Za-z0-9_.]+)/");
            return m.Success ? m.Groups[1].Value : "";
        }

        /// <summary>After the reboot: waits for boot, checks the launcher and boot add-ons are running, tests the Home redirect.</summary>
        private async Task VerifyBootAsync(AppDef launcher, IEnumerable<AppDef> addons)
        {
            Log("");
            Log("=== Checking what starts at boot ===");
            var sw = Stopwatch.StartNew();
            while (sw.Elapsed.TotalSeconds < 90 && Regex.Replace(await DshAsync("getprop", "sys.boot_completed"), @"\D", "") != "1") await Task.Delay(3000);
            await Task.Delay(10000);
            foreach (var app in new[] { launcher }.Concat(addons))
            {
                if (!app.StartsAtBoot) continue;
                var c = Regex.Match(await DshAsync("(ps -A 2>/dev/null || ps) | grep -c " + app.Package), @"\d+");
                int n; int.TryParse(c.Success ? c.Value : "0", out n);
                Log(n > 0 ? $"  [OK] {app.Name} is running after boot" : $"  [--] {app.Name} is not running after boot");
            }
            string fg = await ForegroundPackageAsync();
            if (fg == launcher.Package) { Log($"  [OK] On screen after boot: {launcher.Name}"); return; }
            Log($"  [..] On screen after boot: {(fg.Length > 0 ? fg : "unknown")}. Pressing Home to test the redirect...");
            await DshAsync("input", "keyevent", "3");
            await Task.Delay(7000);
            fg = await ForegroundPackageAsync();
            if (fg == launcher.Package) Log($"  [OK] After pressing Home: {launcher.Name} takes over");
            else
            {
                Log($"  [--] After pressing Home: {(fg.Length > 0 ? fg : "unknown")} is still in front.");
                Log("      On the TV, check: Home on Fire > 'Choose target app' is set and 'Launch on boot' is on;");
                Log("      Projectivy > Settings > General > 'Override current launcher' (OFF if you use Home on Fire).");
            }
        }

        private async Task<bool> SetupAppAsync(AppDef app)
        {
            Log("");
            Log("=== Installing " + app.Name + " ===");
            string apk = await FetchApkAsync(app);
            if (apk == null) return false;
            if (!await InstallApkAsync(app, apk)) return false;
            if (!await ConfigureAppAsync(app)) return false;
            if (app.Notes.Count > 0)
                ShowMessage("On your Fire TV (" + app.Name + "):\n\n" + string.Join("\n", app.Notes) + "\n\nClick OK here once done.", "Action required");
            return true;
        }

        private async Task VerifyAppAsync(AppDef app)
        {
            Log(await IsInstalledAsync(app.Package) ? $"  [OK] {app.Name} is installed" : $"  [!!] {app.Name} is NOT installed");
            foreach (var perm in app.Grants)
            {
                string shortName = perm.Substring(perm.LastIndexOf('.') + 1);
                if ((await DshAsync("dumpsys", "package", app.Package)).Contains(perm + ": granted=true")) { Log($"  [OK] {app.Name} has {shortName}"); continue; }
                // Grants made shortly before a reboot can be lost; grant again and re-check.
                await DshAsync("pm", "grant", app.Package, perm);
                if ((await DshAsync("dumpsys", "package", app.Package)).Contains(perm + ": granted=true"))
                    Log($"  [OK] {app.Name} has {shortName} (granted again; the first grant did not persist)");
                else if (perm == "android.permission.WRITE_SECURE_SETTINGS" && app.Accessibility.Length > 0)
                {
                    Log($"  [--] {shortName} cannot be granted on this firmware.");
                    Log("      Not a problem: the accessibility service was enabled directly over adb instead;");
                    Log("      only the app's own in-app accessibility toggle needs that permission.");
                }
                else Log($"  [!!] {app.Name} is missing {shortName} (grant it with: adb shell pm grant {app.Package} {perm})");
            }
            if (app.Accessibility.Length > 0)
            {
                bool on = (await DshAsync("settings", "get", "secure", "enabled_accessibility_services")).Contains(app.Package);
                Log(on ? $"  [OK] {app.Name} accessibility service is active" : $"  [!!] {app.Name} accessibility service is NOT active");
            }
            if (app.IsLauncher)
            {
                bool role = (await HomeRoleHolderAsync()) == app.Package;
                Log(role ? $"  [OK] {app.Name} holds the HOME role" : $"  [--] {app.Name} does not hold the HOME role (expected on some firmware; the Home-button service still works)");
            }
        }

        // ------------------------------------------------------------
        // Package disabling
        // ------------------------------------------------------------
        private List<string> BuildBloatList(IEnumerable<string> groupKeys)
        {
            var list = new List<string>();
            var always = groups.FirstOrDefault(g => g.Key == "always");
            if (always != null) list.AddRange(always.Packages);
            foreach (var key in groupKeys)
            {
                var g = groups.FirstOrDefault(x => x.Key == key);
                if (g != null) list.AddRange(g.Packages);
            }
            return list;
        }

        private async Task<(List<string> present, List<string> already, List<string> absent)> ClassifyAsync(List<string> bloat)
        {
            var all = (await DshAsync("pm", "list", "packages")).Split('\n').Select(l => l.Trim().Replace("package:", "")).ToHashSet();
            var dis = (await DisabledNowAsync()).ToHashSet();
            var present = new List<string>(); var already = new List<string>(); var absent = new List<string>();
            foreach (var p in bloat)
            {
                if (dis.Contains(p)) already.Add(p);
                else if (all.Contains(p)) present.Add(p);
                else absent.Add(p);
            }
            return (present, already, absent);
        }

        /// <summary>Runs "pm disable-user" for every package in one device-side script. Status: disabled | protected | failed: msg</summary>
        private async Task<List<KeyValuePair<string, string>>> DisableBatchAsync(List<string> pkgs)
        {
            var sb = new StringBuilder();
            foreach (var p in pkgs) sb.Append("echo \"FSC ").Append(p).Append(" $(pm disable-user --user 0 ").Append(p).Append(" 2>&1)\"\n");
            var output = await DeviceScriptAsync(sb.ToString());
            var result = new List<KeyValuePair<string, string>>();
            foreach (var line in output.Split('\n'))
            {
                var m = Regex.Match(line, @"^FSC (\S+) ?(.*)$");
                if (!m.Success) continue;
                string msg = m.Groups[2].Value, st;
                if (msg.Contains("disabled-user")) st = "disabled";
                else if (msg.Contains("SecurityException") || msg.Contains("rotected")) st = "protected";
                else st = "failed: " + msg;
                result.Add(new KeyValuePair<string, string>(m.Groups[1].Value, st));
            }
            return result;
        }

        private async Task<List<KeyValuePair<string, bool>>> EnableBatchAsync(List<string> pkgs)
        {
            var sb = new StringBuilder();
            foreach (var p in pkgs) sb.Append("echo \"FSC ").Append(p).Append(" $(pm enable --user 0 ").Append(p).Append(" 2>&1)\"\n");
            var output = await DeviceScriptAsync(sb.ToString());
            var result = new List<KeyValuePair<string, bool>>();
            foreach (var line in output.Split('\n'))
            {
                var m = Regex.Match(line, @"^FSC (\S+) ?(.*)$");
                if (m.Success) result.Add(new KeyValuePair<string, bool>(m.Groups[1].Value, m.Groups[2].Value.Contains("enabled")));
            }
            return result;
        }

        private async Task<(int disabled, int protectedCount, int passes)> DisablePassesAsync(List<string> remaining)
        {
            int total = 0, lastProtected = 0, pass = 0;
            while (true)
            {
                pass++;
                int pd = 0, pp = 0;
                var next = new List<string>();
                Log("");
                Log($"=== Disabling bloatware (pass {pass}) ===");
                foreach (var kv in await DisableBatchAsync(remaining))
                {
                    if (kv.Value == "disabled") { Log("  [OK] Disabled: " + kv.Key); state.AddUnique("disabled", kv.Key); pd++; }
                    else if (kv.Value == "protected") { Log("  [--] Protected: " + kv.Key); pp++; next.Add(kv.Key); }
                    else Log($"  [--] Failed: {kv.Key} ({kv.Value})");
                }
                total += pd; lastProtected = pp;
                Log($"  Pass {pass}: disabled {pd}, protected {pp}");
                if (pd > 0 && pp > 0 && pass < 3)
                {
                    Log("  [..] Some packages are protected; rebooting to retry them...");
                    if (await RebootAndReconnectAsync()) { remaining = next; continue; }
                    Log("  [--] Could not reconnect after reboot; continuing with what we have.");
                }
                break;
            }
            return (total, lastProtected, pass);
        }

        private async Task<int> ReapplyDisabledAsync()
        {
            var now = (await DisabledNowAsync()).ToHashSet();
            var want = state.GetAll("disabled").Where(p => !now.Contains(p)).ToList();
            if (want.Count == 0) return 0;
            return (await DisableBatchAsync(want)).Count(kv => kv.Value == "disabled");
        }

        // ------------------------------------------------------------
        // ADB plumbing
        // ------------------------------------------------------------
        private Task<string> DshAsync(params string[] args)
        {
            var full = new List<string> { "-s", target, "shell" };
            full.AddRange(args);
            return RunAdb(full.ToArray()).ContinueWith(t => t.Result.output);
        }

        /// <summary>Pushes a script to the device and runs it there, avoiding command-length limits.</summary>
        private async Task<string> DeviceScriptAsync(string script)
        {
            string tmp = Path.GetTempFileName();
            File.WriteAllText(tmp, script.Replace("\r\n", "\n"), new UTF8Encoding(false));
            await RunAdb("-s", target, "push", tmp, DeviceTmp + "/fsc_script.sh");
            try { File.Delete(tmp); } catch { }
            var output = await DshAsync("sh", DeviceTmp + "/fsc_script.sh");
            await DshAsync("rm", "-f", DeviceTmp + "/fsc_script.sh");
            return output;
        }

        private async Task<(int code, string output)> RunAdb(params string[] args)
        {
            string argLine = string.Join(" ", args.Select(QuoteArg));
            try { File.AppendAllText(logFile, "[adb] " + argLine + Environment.NewLine); } catch { }
            return await Task.Run(() =>
            {
                try
                {
                    var psi = new ProcessStartInfo
                    {
                        FileName = adbPath,
                        Arguments = argLine,
                        RedirectStandardOutput = true,
                        RedirectStandardError = true,
                        UseShellExecute = false,
                        CreateNoWindow = true,
                        StandardOutputEncoding = Encoding.UTF8,
                        StandardErrorEncoding = Encoding.UTF8
                    };
                    using (var p = Process.Start(psi))
                    {
                        var stdout = p.StandardOutput.ReadToEndAsync();
                        var stderr = p.StandardError.ReadToEndAsync();
                        if (!p.WaitForExit(120000))
                        {
                            try { p.Kill(); } catch { }
                            return (-1, "[timeout]");
                        }
                        Task.WaitAll(stdout, stderr);
                        string combined = ((stdout.Result ?? "") + (stderr.Result ?? "")).Replace("\r", "");
                        try { File.AppendAllText(logFile, combined + Environment.NewLine); } catch { }
                        return (p.ExitCode, combined);
                    }
                }
                catch (Exception ex) { return (-1, ex.Message); }
            });
        }

        private static string QuoteArg(string a)
        {
            if (a.Length > 0 && a.IndexOfAny(new[] { ' ', '"', '\t' }) < 0) return a;
            return "\"" + a.Replace("\\", "\\\\").Replace("\"", "\\\"") + "\"";
        }

        private static string Sha256(string path)
        {
            using (var sha = SHA256.Create())
            using (var fs = File.OpenRead(path))
                return BitConverter.ToString(sha.ComputeHash(fs)).Replace("-", "").ToLowerInvariant();
        }

        private static string HumanSize(long bytes) => bytes >= 1048576 ? (bytes / 1048576) + " MB" : (bytes / 1024) + " KB";

        private static int ParseKbToMb(string memInfoLine)
        {
            var m = Regex.Match(memInfoLine ?? "", @"(\d+)\s*kB");
            return m.Success && long.TryParse(m.Groups[1].Value, out var kb) ? (int)(kb / 1024) : 0;
        }

        // ------------------------------------------------------------
        // UI plumbing (safe to call from the background thread)
        // ------------------------------------------------------------
        private void Log(string text)
        {
            if (txtLog.InvokeRequired) { txtLog.BeginInvoke((Action)(() => Log(text))); return; }
            txtLog.AppendText(text + Environment.NewLine);
            try { File.AppendAllText(logFile, text + Environment.NewLine); } catch { }
        }

        private void SetStatus(string text)
        {
            if (lblStatus.InvokeRequired) { lblStatus.BeginInvoke((Action)(() => SetStatus(text))); return; }
            lblStatus.Text = text;
        }

        private void SetProgress(int value, string status)
        {
            if (progressBar.InvokeRequired) { progressBar.BeginInvoke((Action)(() => SetProgress(value, status))); return; }
            progressBar.Value = Math.Max(0, Math.Min(100, value));
            lblStatus.Text = status;
            Log($"[{value,3}%] {status}");
        }

        private void SetButtons(bool enabled)
        {
            if (btnStart.InvokeRequired) { btnStart.BeginInvoke((Action)(() => SetButtons(enabled))); return; }
            btnStart.Enabled = btnReapply.Enabled = btnStatus.Enabled = btnTestBoot.Enabled = btnRevert.Enabled = enabled;
            txtDeviceIP.Enabled = cmbLauncher.Enabled = pnlAddons.Enabled = grpOptions.Enabled = enabled;
        }

        private void ShowMessage(string text, string title)
        {
            if (InvokeRequired) { Invoke((Action)(() => ShowMessage(text, title))); return; }
            MessageBox.Show(this, text, title, MessageBoxButtons.OK, MessageBoxIcon.Information);
        }

        private bool Confirm(string text, string title)
        {
            if (InvokeRequired) return (bool)Invoke((Func<bool>)(() => Confirm(text, title)));
            return MessageBox.Show(this, text, title, MessageBoxButtons.OKCancel, MessageBoxIcon.Question) == DialogResult.OK;
        }

        private void ResetLog()
        {
            txtLog.Clear();
            progressBar.Value = 0;
            try
            {
                File.WriteAllText(logFile, "Firestick Cleanup " + Version + " log - " + DateTime.Now + Environment.NewLine);
            }
            catch { }
        }
    }
}
