using System;
using System.Collections.Generic;
using System.Diagnostics;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Http;
using System.Security.Cryptography;
using System.Text;
using System.Text.RegularExpressions;
using System.Threading.Tasks;
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

        private readonly string baseDir;
        private readonly string adbPath;
        private readonly string logFile;
        private readonly string lastIpFile;
        private readonly string downloadDir;

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
            string role = (await DshAsync("cmd", "role", "get-role-holders", "android.app.role.HOME")).Trim();
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
            Log("  [..] Rebooting Fire TV...");
            await DshAsync("reboot");
            await Task.Delay(20000);
            var sw = Stopwatch.StartNew();
            while (sw.Elapsed.TotalSeconds < 180)
            {
                await RunAdb("connect", target);
                if (await DeviceStateAsync() == "device" && (await DshAsync("echo", "fsc_ok")).Contains("fsc_ok"))
                {
                    await Task.Delay(5000);
                    Log("  [OK] Device is back online");
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
                    var urls = Regex.Matches(json, @"""browser_download_url"":\s*""([^""]+\.apk)""").Cast<Match>().Select(m => m.Groups[1].Value).ToList();
                    if (urls.Count > 0)
                    {
                        url = urls[0];
                        if (urls.Count == 1)
                        {
                            var d = Regex.Match(json, @"""digest"":\s*""sha256:([0-9a-f]+)""");
                            if (d.Success) sha = d.Groups[1].Value;
                        }
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
            if (app.IsLauncher)
            {
                await DshAsync("appops", "set", app.Package, "SYSTEM_ALERT_WINDOW", "allow");
                Log("  [OK] Overlay permission granted");
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
            if (app.Accessibility.Length > 0)
            {
                bool on = (await DshAsync("settings", "get", "secure", "enabled_accessibility_services")).Contains(app.Package);
                Log(on ? $"  [OK] {app.Name} accessibility service is active" : $"  [!!] {app.Name} accessibility service is NOT active");
            }
            if (app.IsLauncher)
            {
                bool role = (await DshAsync("cmd", "role", "get-role-holders", "android.app.role.HOME")).Contains(app.Package);
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
            btnStart.Enabled = btnReapply.Enabled = btnStatus.Enabled = btnRevert.Enabled = enabled;
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
