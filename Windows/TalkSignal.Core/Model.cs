using System.Text;
using System.Text.Json;

namespace TalkSignal.Core;

public enum Glyph { Heart, Bubble, Star, Bell }
public sealed record Preferences(string Target = "", Glyph Icon = Glyph.Heart, bool ShowCount = true)
{
    public Preferences Validate()
    {
        var target = Names.Normalize(Target);
        if (target.Length > 200 || target.Any(char.IsControl) || !Enum.IsDefined(Icon))
            throw new ArgumentException("이름은 줄바꿈 없이 200자 이내로 입력해 주세요.");
        return this with { Target = target };
    }
}
public static class Names
{
    public static string Normalize(string? name) => (name ?? "").Trim().Normalize(NormalizationForm.FormC);
    public static bool Equal(string? a, string? b) => Normalize(a).Length > 0 && Normalize(a) == Normalize(b);
}
public enum StateKind { Unconfigured, Pending, Ready, Missing, Ambiguous, Unavailable, Stale }
public sealed record SignalState(StateKind Kind, int? Count = null, bool Simulated = false)
{
    public bool HasUnread => Kind == StateKind.Ready && Count > 0;
    public bool Warning => Kind != StateKind.Ready && Kind != StateKind.Unconfigured;
    public string Description => (Simulated ? "[체험 · 실제 카톡 아님] " : "") + (Kind switch
    {
        StateKind.Unconfigured => "개인 이름 또는 채팅방 이름을 설정해 주세요",
        StateKind.Pending => "카톡 감지 연동 준비 중 · 실제 안 읽음은 아직 확인하지 않아요",
        StateKind.Ready when Count == 0 => "안 읽은 메시지가 없어요",
        StateKind.Ready => $"안 읽은 메시지 {Count}개",
        StateKind.Missing => "일치하는 방을 찾지 못했어요",
        StateKind.Ambiguous => "같은 이름의 방이 여러 개라 구분할 수 없어요",
        StateKind.Stale => "상태가 오래되어 현재 안 읽음을 확인할 수 없어요",
        _ => "현재 안 읽은 상태를 확인할 수 없어요"
    });
}
// Metadata contract only. Never accepts message bodies, receipts or notification counts as unread proof.
public sealed record RoomStatus(string Name, int? Unread);
public sealed record Snapshot(IReadOnlyList<RoomStatus> Rooms, DateTimeOffset CapturedAt, bool Simulated);
public static class Monitor
{
    public static SignalState Evaluate(string target, Snapshot? snapshot, DateTimeOffset now)
    {
        if (Names.Normalize(target).Length == 0) return new(StateKind.Unconfigured);
        if (snapshot is null) return new(StateKind.Pending);
        var demo = snapshot.Simulated;
        if (snapshot.CapturedAt > now.AddSeconds(5) || snapshot.CapturedAt < now.AddSeconds(-15)) return new(StateKind.Stale, Simulated: demo);
        var matches = snapshot.Rooms.Where(r => Names.Equal(r.Name, target)).ToList();
        if (matches.Count == 0) return new(StateKind.Missing, Simulated: demo);
        if (matches.Count != 1) return new(StateKind.Ambiguous, Simulated: demo);
        if (matches[0].Unread is not int count || count < 0) return new(StateKind.Unavailable, Simulated: demo);
        return new(StateKind.Ready, count, demo);
    }
}
public sealed class PreferenceStore(string path)
{
    public Preferences Load()
    {
        if (!File.Exists(path)) return new();
        if (new FileInfo(path).Length > 65536) throw new InvalidDataException("설정 파일 크기가 올바르지 않아요.");
        return (JsonSerializer.Deserialize<Preferences>(File.ReadAllText(path)) ?? throw new InvalidDataException("설정을 읽지 못했어요.")).Validate();
    }
    public void Save(Preferences preferences)
    {
        var safe = preferences.Validate();
        Directory.CreateDirectory(Path.GetDirectoryName(Path.GetFullPath(path))!);
        var temporary = path + "." + Guid.NewGuid().ToString("N") + ".tmp";
        try { File.WriteAllText(temporary, JsonSerializer.Serialize(safe, new JsonSerializerOptions { WriteIndented = true })); File.Move(temporary, path, true); }
        finally { if (File.Exists(temporary)) File.Delete(temporary); }
    }
}
public static class WindowSelection
{
    // Called only with top-level windows belonging to verified KakaoTalk processes.
    public static nint? Exact(string target, IReadOnlyList<(nint Handle, string Title)> windows)
    {
        var matches = windows.Where(w => Names.Equal(w.Title, target)).ToArray();
        if (matches.Length > 1) throw new InvalidOperationException("같은 이름의 대화창이 여러 개예요. 카톡에서 직접 선택해 주세요.");
        return matches.Length == 1 ? matches[0].Handle : null;
    }
}
