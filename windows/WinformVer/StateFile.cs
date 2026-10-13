using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace FirestickCleanup
{
    /// <summary>
    /// Records what the tool changed on one device (key=value lines) so that
    /// --revert only undoes those changes. Same format as the shell and
    /// PowerShell implementations, so the files are interchangeable.
    /// </summary>
    public sealed class StateFile
    {
        private readonly List<string> lines = new List<string>();

        public string Path { get; }
        public bool Exists => File.Exists(Path);

        public StateFile(string path)
        {
            Path = path;
            if (File.Exists(path))
                lines.AddRange(File.ReadAllLines(path).Where(l => l.Length > 0));
        }

        public List<string> GetAll(string key) =>
            lines.Where(l => l.StartsWith(key + "=")).Select(l => l.Substring(key.Length + 1)).ToList();

        public string Get(string key)
        {
            var v = GetAll(key);
            return v.Count > 0 ? v[0] : "";
        }

        public bool Has(string key) => lines.Any(l => l.StartsWith(key + "="));

        public void Set(string key, string value)
        {
            lines.RemoveAll(l => l.StartsWith(key + "="));
            lines.Add(key + "=" + value);
            Save();
        }

        public void AddUnique(string key, string value)
        {
            if (lines.Contains(key + "=" + value)) return;
            lines.Add(key + "=" + value);
            Save();
        }

        public void Save() => File.WriteAllLines(Path, lines);

        public void Delete()
        {
            lines.Clear();
            try { File.Delete(Path); } catch { }
        }
    }
}
