using TalkSignal.Core;
using Monitor = TalkSignal.Core.Monitor;
namespace TalkSignal.Windows;

internal sealed class TrayApp : ApplicationContext
{
    private readonly NotifyIcon tray;
    private readonly System.Windows.Forms.Timer timer = new() { Interval = 500 };
    private readonly PreferenceStore? store;
    private readonly bool demoOnly;
    private Preferences preferences;
    private SettingsForm? settings;
    private DemoForm? demo;
    private int? demoCount;
    private bool demonstration;
    private DateTimeOffset previewUntil;
    private Icon? currentIcon;
    private string? lastRender;
    internal bool TrayVisible => tray.Visible;
    internal SignalState State => demonstration
        ? Monitor.Evaluate(preferences.Target.Length == 0 ? "체험 대상" : preferences.Target,
            new Snapshot([new(preferences.Target.Length == 0 ? "체험 대상" : preferences.Target, demoCount)], DateTimeOffset.UtcNow, true), DateTimeOffset.UtcNow)
        : Monitor.Evaluate(preferences.Target, null, DateTimeOffset.UtcNow);
    internal TrayApp(Preferences preferences, PreferenceStore? store, bool demoOnly, bool showSettings)
    {
        this.preferences = preferences; this.store = store; this.demoOnly = demoOnly;
        tray = new NotifyIcon { Text = "TalkSignal · 연동 준비 중", Visible = false };
        var menu = new ContextMenuStrip();
        menu.Items.Add("카카오톡 열기", null, (_, _) => Open());
        menu.Items.Add("설정…", null, (_, _) => ShowSettings());
        menu.Items.Add("표시 미리보기", null, (_, _) => Preview());
        menu.Items.Add("수신·읽음 표시 체험", null, (_, _) => ShowDemo());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("TalkSignal 종료", null, (_, _) => ExitThread());
        tray.ContextMenuStrip = menu;
        tray.MouseClick += (_, e) => { if (e.Button == MouseButtons.Left) Open(); };
        timer.Tick += (_, _) => Render();
        Render(); tray.Visible = true; timer.Start();
        if (showSettings) ShowSettings();
        if (demoOnly) ShowDemo();
    }
    internal void Preview() { previewUntil = DateTimeOffset.UtcNow.AddSeconds(4); Render(); }
    internal void Render()
    {
        var actual = State;
        var visual = DateTimeOffset.UtcNow < previewUntil ? new SignalState(StateKind.Ready, 3, true) : actual;
        var tooltip = DateTimeOffset.UtcNow < previewUntil ? "TalkSignal · 표시 미리보기 (실제 카톡 아님)" : "TalkSignal · " + visual.Description;
        var signature = $"{preferences.Icon}|{preferences.ShowCount}|{visual}|{tooltip}";
        if (signature == lastRender) return;
        var next = TrayIcon.Create(preferences.Icon, visual, preferences.ShowCount);
        tray.Icon = next; currentIcon?.Dispose(); currentIcon = next;
        tray.Text = tooltip.Length > 63 ? tooltip[..62] + "…" : tooltip;
        settings?.UpdateStatus(actual); lastRender = signature;
    }
    private void Open()
    {
        if (demoOnly || demonstration) { MessageBox.Show("표시 체험 중에는 카톡을 조작하지 않습니다.", "TalkSignal"); return; }
        try {
            if (KakaoLauncher.Open(preferences.Target) is string info) MessageBox.Show(info, "TalkSignal");
        } catch (Exception ex) when (ex is InvalidOperationException or System.ComponentModel.Win32Exception or UnauthorizedAccessException) { MessageBox.Show(ex.Message, "TalkSignal"); }
    }
    internal void ShowSettings()
    {
        if (settings is { IsDisposed: false }) { settings.Show(); settings.Activate(); return; }
        var executable = Environment.ProcessPath ?? throw new InvalidOperationException("앱 경로를 확인할 수 없어요.");
        settings = new SettingsForm(preferences, !demoOnly && Startup.Enabled(executable), demoOnly);
        settings.SaveRequested = (value, startup) => {
            if (!demoOnly) {
                var wasEnabled = Startup.Enabled(executable);
                Startup.Set(startup, executable);
                try { store!.Save(value); } catch { Startup.Set(wasEnabled, executable); throw; }
            }
            preferences = value; Render();
        };
        settings.PreviewRequested = Preview; settings.OpenRequested = Open; settings.DemoRequested = ShowDemo;
        settings.UpdateStatus(State); settings.Show(); settings.Activate();
    }
    internal void ShowDemo()
    {
        if (demo is { IsDisposed: false }) { demo.Activate(); return; }
        demonstration = true; demoCount = 0;
        demo = new DemoForm(count => { demoCount = count; Render(); });
        demo.FormClosed += (_, _) => { demonstration = false; Render(); };
        demo.Show(); Render();
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { timer.Stop(); timer.Dispose(); tray.Visible = false; tray.ContextMenuStrip?.Dispose(); tray.Dispose(); currentIcon?.Dispose(); settings?.Dispose(); demo?.Dispose(); }
        base.Dispose(disposing);
    }
}
