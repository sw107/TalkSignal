using TalkSignal.Core;
namespace TalkSignal.Windows;
internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args.Length == 2 && args[0] == "--self-test") return SelfTest.Run(args[1]);
        var demo = args.Contains("--demo");
        using var mutex = new Mutex(true, demo ? @"Local\TalkSignal.Windows.Demo" : @"Local\TalkSignal.Windows", out var created);
        if (!created) { MessageBox.Show("TalkSignal이 이미 실행 중이에요. 작업표시줄의 숨겨진 아이콘(∧)도 확인해 주세요.", "TalkSignal"); return 0; }
        var store = new PreferenceStore(Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TalkSignal", "settings.json"));
        Preferences preferences;
        try { preferences = demo ? new("체험 대상") : store.Load(); }
        catch (Exception ex) when (ex is IOException or UnauthorizedAccessException or System.Text.Json.JsonException or ArgumentException) {
            MessageBox.Show("저장된 설정을 읽지 못했어요. 설정 파일은 그대로 보존합니다.\n" + ex.Message, "TalkSignal"); return 1;
        }
        using var app = new TrayApp(preferences, demo ? null : store, demo, !args.Contains("--background") || preferences.Target.Length == 0);
        Application.Run(app);
        return 0;
    }
}
