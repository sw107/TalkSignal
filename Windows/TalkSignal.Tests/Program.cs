using TalkSignal.Core;
using Monitor = TalkSignal.Core.Monitor;
var passed = new List<string>();
void Check(bool value, string name) { if (!value) throw new Exception(name); passed.Add(name); }
var now = DateTimeOffset.UtcNow;
var name = "테스트💕";
Snapshot Data(params RoomStatus[] rooms) => new(rooms, now, true);
Check(Names.Equal(" 가 ", "가"), "Korean canonical equality");
Check(!Names.Equal(name, name + " 회사"), "No prefix match");
Check(!Names.Equal("", " "), "No empty-name match");
Check(Monitor.Evaluate(name, null, now).Kind == StateKind.Pending, "No backend never implies read");
Check(Monitor.Evaluate("", null, now).Kind == StateKind.Unconfigured, "Empty target prompts settings");
var received = Monitor.Evaluate(name, Data(new(name, 3)), now);
var read = Monitor.Evaluate(name, Data(new(name, 0)), now);
Check(received.HasUnread && received.Count == 3 && received.Simulated, "Simulated receive activates indicator");
Check(!read.HasUnread && !read.Warning && read.Count == 0, "Confirmed zero clears indicator");
Check(Monitor.Evaluate(name, Data(new(name, null)), now).Warning, "Unknown count is not zero");
Check(Monitor.Evaluate(name, Data(new(name, -1)), now).Warning, "Negative count rejected");
Check(Monitor.Evaluate(name, Data(new(name, 1), new(name, 2)), now).Kind == StateKind.Ambiguous, "Duplicate names never summed");
Check(Monitor.Evaluate(name, Data(new("다른 방", 9)), now).Kind == StateKind.Missing, "Missing target distinct from read");
Check(Monitor.Evaluate(name, Data(new(name, 0)) with { CapturedAt = now.AddSeconds(-16) }, now).Kind == StateKind.Stale, "Old zero expires");
Check(Monitor.Evaluate(name, Data(new(name, 1)) with { CapturedAt = now.AddSeconds(10) }, now).Kind == StateKind.Stale, "Future capture rejected");
Check(WindowSelection.Exact(name, [(1, name + " 모임"), (2, name)]) == 2, "Open exact window only");
try { WindowSelection.Exact(name, [(1, name), (2, name)]); throw new Exception("accepted ambiguity"); }
catch (InvalidOperationException) { passed.Add("Ambiguous open refused"); }
var root = Path.Combine(Path.GetTempPath(), "TalkSignal-tests-" + Guid.NewGuid());
try {
    var path = Path.Combine(root, "settings.json"); var store = new PreferenceStore(path);
    store.Save(new(name, Glyph.Star, false));
    Check(store.Load() == new Preferences(name, Glyph.Star, false), "Settings survive restart");
    try { store.Save(new("bad\nname")); throw new Exception("invalid name accepted"); }
    catch (ArgumentException) { passed.Add("Invalid save rejected"); }
    Check(store.Load().Target == name, "Invalid save preserves previous settings");
    File.WriteAllText(path, "{broken");
    try { store.Load(); throw new Exception("corrupt settings accepted"); }
    catch (System.Text.Json.JsonException) { passed.Add("Corrupt settings surfaced"); }
} finally { if (Directory.Exists(root)) Directory.Delete(root, true); }
Console.WriteLine(System.Text.Json.JsonSerializer.Serialize(new { passed = passed.Count, tests = passed }, new System.Text.Json.JsonSerializerOptions { WriteIndented = true }));
