using Microsoft.Win32;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using TalkSignal.Core;

namespace TalkSignal.Windows;
internal static class Startup
{
    internal const string Key = @"Software\Microsoft\Windows\CurrentVersion\Run";
    internal const string ValueName = "TalkSignal";
    internal static string Command(string executable) => "\"" + Path.GetFullPath(executable) + "\" --background";
    internal static bool Enabled(string executable)
    {
        using var key = Registry.CurrentUser.OpenSubKey(Key);
        return string.Equals(key?.GetValue(ValueName) as string, Command(executable), StringComparison.OrdinalIgnoreCase);
    }
    internal static void Set(bool enabled, string executable)
    {
        using var key = Registry.CurrentUser.CreateSubKey(Key, true);
        if (enabled) key.SetValue(ValueName, Command(executable), RegistryValueKind.String);
        else key.DeleteValue(ValueName, false);
    }
}
internal static class KakaoLauncher
{
    internal static List<(nint Handle, string Title)> WindowsFor(HashSet<int> pids)
    {
        var windows = new List<(nint, string)>();
        Native.EnumWindows((handle, _) => {
            Native.GetWindowThreadProcessId(handle, out var pid);
            if (pids.Contains((int)pid)) {
                var title = new StringBuilder(512); Native.GetWindowText(handle, title, title.Capacity);
                if (title.Length > 0) windows.Add((handle, title.ToString()));
            }
            return true;
        }, 0);
        return windows;
    }
    internal static string? Open(string target)
    {
        var processes = Process.GetProcessesByName("KakaoTalk");
        try {
            var windows = WindowsFor(processes.Select(p => p.Id).ToHashSet());
            var exact = WindowSelection.Exact(target, windows);
            if (exact is nint handle) { Restore(handle); return null; }
            var main = windows.FirstOrDefault(w => w.Title is "카카오톡" or "KakaoTalk");
            if (main.Handle != 0) Restore(main.Handle);
            else {
                var candidates = new[] {
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFilesX86), "Kakao", "KakaoTalk", "KakaoTalk.exe"),
                    Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Kakao", "KakaoTalk", "KakaoTalk.exe")
                };
                var path = candidates.FirstOrDefault(File.Exists);
                if (path is null) return "카카오톡을 찾지 못했어요. Windows에서 카톡을 직접 실행해 주세요.";
                Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
            }
            return "카카오톡을 열었어요. 이 Windows 준비판은 이미 열린 대상 대화창만 바로 선택할 수 있어요. 새 대화창 검색·열기는 실제 PC에서 연동할 예정이에요.";
        } finally { foreach (var process in processes) process.Dispose(); }
    }
    private static void Restore(nint handle)
    {
        Native.ShowWindow(handle, 9);
        if (!Native.SetForegroundWindow(handle)) throw new InvalidOperationException("카톡 창을 앞으로 가져오지 못했어요. 작업표시줄에서 카톡을 선택해 주세요.");
    }
}
internal static class Native
{
    internal delegate bool EnumCallback(nint handle, nint parameter);
    [DllImport("user32.dll")] internal static extern bool EnumWindows(EnumCallback callback, nint parameter);
    [DllImport("user32.dll")] internal static extern uint GetWindowThreadProcessId(nint handle, out uint pid);
    [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern int GetWindowText(nint handle, StringBuilder title, int maximum);
    [DllImport("user32.dll")] internal static extern bool ShowWindow(nint handle, int command);
    [DllImport("user32.dll")] internal static extern bool SetForegroundWindow(nint handle);
    [DllImport("user32.dll")] internal static extern bool DestroyIcon(nint icon);
}
internal static class TrayIcon
{
    internal static Icon Create(Glyph glyph, SignalState state, bool count)
    {
        using var bitmap = new Bitmap(32, 32);
        using var g = Graphics.FromImage(bitmap);
        g.SmoothingMode = System.Drawing.Drawing2D.SmoothingMode.AntiAlias;
        g.Clear(Color.Transparent);
        var symbol = glyph switch { Glyph.Heart => "♥", Glyph.Star => "★", Glyph.Bell => "♟", _ => "●" };
        using var font = new Font("Segoe UI Symbol", 23, FontStyle.Bold, GraphicsUnit.Pixel);
        using var brush = new SolidBrush(Color.FromArgb(115, 125, 145));
        if (glyph == Glyph.Bubble) {
            g.FillEllipse(brush, 3, 3, 23, 20); g.FillPolygon(brush, [new Point(6, 17), new Point(5, 27), new Point(14, 20)]);
        } else if (glyph == Glyph.Bell) {
            g.FillPie(brush, 6, 4, 20, 24, 180, 180); g.FillRectangle(brush, 6, 15, 20, 7);
            g.FillEllipse(brush, 12, 22, 8, 5);
        } else g.DrawString(symbol, font, brush, -1, -1);
        if (state.Warning || state.HasUnread) {
            using var badge = new SolidBrush(state.Warning ? Color.DarkOrange : Color.DeepPink);
            if (count && state.HasUnread) {
                g.FillEllipse(badge, 12, 14, 20, 18);
                using var label = new Font("Segoe UI", 10, FontStyle.Bold, GraphicsUnit.Pixel);
                var text = state.Count > 99 ? "+" : state.Count!.Value.ToString();
                g.DrawString(text, label, Brushes.White, new RectangleF(12, 14, 20, 18), new StringFormat { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center });
            } else g.FillEllipse(badge, 22, 22, 9, 9);
        }
        var raw = bitmap.GetHicon();
        try { using var icon = Icon.FromHandle(raw); return (Icon)icon.Clone(); }
        finally { Native.DestroyIcon(raw); }
    }
}
