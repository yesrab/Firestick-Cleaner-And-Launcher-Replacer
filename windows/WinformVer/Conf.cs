using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace FirestickCleanup
{
    /// <summary>One [group] from common/packages.conf.</summary>
    public sealed class GroupDef
    {
        public string Key;
        public string Prompt;
        public readonly List<string> Packages = new List<string>();

        /// <summary>Short label for a checkbox: the text up to and including the first '?'.</summary>
        public string ShortPrompt
        {
            get
            {
                int q = Prompt.IndexOf('?');
                return q > 0 ? Prompt.Substring(0, q + 1) : Prompt;
            }
        }
    }

    /// <summary>One [section] from common/launchers.conf (a launcher or an add-on).</summary>
    public sealed class AppDef
    {
        public string Key;
        public readonly Dictionary<string, List<string>> Values = new Dictionary<string, List<string>>();

        public string Get(string key)
        {
            List<string> v;
            return Values.TryGetValue(key, out v) && v.Count > 0 ? v[0] : "";
        }

        public List<string> GetAll(string key)
        {
            List<string> v;
            return Values.TryGetValue(key, out v) ? v : new List<string>();
        }

        public string Type => Get("type");
        public string Name => Get("name");
        public string Summary => Get("summary");
        public string Package => Get("package");
        public string Activity => Get("activity");
        public string Accessibility => Get("accessibility");
        public string NotificationListener => Get("notification_listener");
        public string Source => Get("source");
        public string FallbackUrl => Get("fallback_url");
        public bool IsLauncher => Type == "launcher";
        public bool IsAddon => Type == "addon";
        public string Prompt => Get("prompt");
        public bool DefaultOn => Get("default") == "yes";
        public IEnumerable<string> Needs => Get("needs").Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
        public IEnumerable<string> Disables => Get("disables").Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
        public IEnumerable<string> Grants => Get("grant").Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
        public IEnumerable<string> ApkGlobs => Get("apk_glob").Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
        public List<string> Notes => GetAll("note");

        public override string ToString() => Name;
    }

    /// <summary>Parses the shared config files. Format is documented in the files themselves.</summary>
    public static class Conf
    {
        public static List<GroupDef> LoadGroups(string path)
        {
            var groups = new List<GroupDef>();
            GroupDef cur = null;
            foreach (var raw in File.ReadAllLines(path))
            {
                var line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#")) continue;
                if (line.StartsWith("["))
                {
                    int close = line.IndexOf(']');
                    if (close < 0) continue;
                    cur = new GroupDef { Key = line.Substring(1, close - 1), Prompt = line.Substring(close + 1).Trim() };
                    groups.Add(cur);
                    continue;
                }
                if (cur == null) continue;
                var pkg = line.Split(new[] { ' ', '\t' }, StringSplitOptions.RemoveEmptyEntries)[0];
                if (!pkg.StartsWith("#")) cur.Packages.Add(pkg);
            }
            return groups;
        }

        public static List<AppDef> LoadApps(string path)
        {
            var apps = new List<AppDef>();
            AppDef cur = null;
            foreach (var raw in File.ReadAllLines(path))
            {
                var line = raw.Trim();
                if (line.Length == 0 || line.StartsWith("#")) continue;
                if (line.StartsWith("["))
                {
                    int close = line.IndexOf(']');
                    if (close < 0) continue;
                    cur = new AppDef { Key = line.Substring(1, close - 1) };
                    apps.Add(cur);
                    continue;
                }
                if (cur == null) continue;
                int eq = line.IndexOf('=');
                if (eq <= 0) continue;
                var key = line.Substring(0, eq);
                var value = line.Substring(eq + 1);
                if (!cur.Values.ContainsKey(key)) cur.Values[key] = new List<string>();
                cur.Values[key].Add(value);
            }
            return apps;
        }
    }
}
