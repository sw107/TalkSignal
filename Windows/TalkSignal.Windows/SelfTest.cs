using System.Diagnostics;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32;
using TalkSignal.Core;
namespace TalkSignal.Windows;
internal static class SelfTest
{
    internal static int Run(string directory)
    {
        Directory.CreateDirectory(directory);
        var passed = new List<string>();
        void Check(bool value, string test) { if (!value) throw new Exception(test); passed.Add(test); }
        try {
            var preference = new Preferences("테스트💕", Glyph.Heart, true);
            using var form = new SettingsForm(preference, false, false);
            form.Show(); Application.DoEvents();
            Check(form.Visible, "Native settings window starts");
            Preferences? saved = null; form.SaveRequested = (p, _) => saved = p;
            form.TargetBox.Text = " 테스트 방 "; form.IconsBox.SelectedIndex = (int)Glyph.Star; form.CountBox.Checked = false;
            form.SaveButton.PerformClick(); Application.DoEvents();
            Check(saved == new Preferences("테스트 방", Glyph.Star, false), "Settings controls save normalized target and selected icon");
            form.TargetBox.Text = ""; saved = null; form.SaveButton.PerformClick();
            Check(saved is null, "Blank target is refused by real form");
            form.TargetBox.Text = "테스트 방"; form.SaveButton.PerformClick(); form.UpdateStatus(new(StateKind.Pending)); Application.DoEvents();
            using (var image = new Bitmap(form.Width, form.Height)) { form.DrawToBitmap(image, new Rectangle(Point.Empty, form.Size)); image.Save(Path.Combine(directory, "settings.png"), ImageFormat.Png); }
            using var demo = new DemoForm(_ => { }); demo.Show(); Application.DoEvents();
            using (var image = new Bitmap(demo.Width, demo.Height)) { demo.DrawToBitmap(image, new Rectangle(Point.Empty, demo.Size)); image.Save(Path.Combine(directory, "demo.png"), ImageFormat.Png); }
            foreach (var glyph in Enum.GetValues<Glyph>()) {
                using var off = TrayIcon.Create(glyph, new(StateKind.Ready, 0), true);
                using var on = TrayIcon.Create(glyph, new(StateKind.Ready, 3), true);
                using var warning = TrayIcon.Create(glyph, new(StateKind.Pending), true);
                Check(off.Handle != 0 && on.Handle != 0 && warning.Handle != 0, $"Native icon resources: {glyph}");
                using var bitmap = on.ToBitmap(); bitmap.Save(Path.Combine(directory, $"icon-{glyph}.png"), ImageFormat.Png);
            }
            using (var nativeWindow = new Form { Text = "대상 테스트💕" }) {
                nativeWindow.Show(); Application.DoEvents();
                var windows = KakaoLauncher.WindowsFor([Environment.ProcessId]);
                Check(WindowSelection.Exact(nativeWindow.Text, windows) == nativeWindow.Handle, "Real Win32 enumeration selects an exact test-window title");
                Check(WindowSelection.Exact("대상 테스트", windows) is null, "Real window title prefix does not match");
            }
            var path = Path.Combine(directory, "테스트 경로", "TalkSignal.exe");
            Check(Startup.Command(path).StartsWith('"') && Startup.Command(path).EndsWith("\" --background"), "Startup command quotes paths with spaces and Korean");
            using (var key = Registry.CurrentUser.CreateSubKey(Startup.Key, true)) {
                var original = key.GetValue(Startup.ValueName); var originalKind = original is null ? RegistryValueKind.String : key.GetValueKind(Startup.ValueName);
                try {
                    Startup.Set(true, path); Check(Startup.Enabled(path), "Autostart writes exact current-user Run value");
                    Startup.Set(false, path); Check(!Startup.Enabled(path), "Autostart can be disabled");
                } finally { if (original is null) key.DeleteValue(Startup.ValueName, false); else key.SetValue(Startup.ValueName, original, originalKind); }
            }
            using (var tray = new TrayApp(preference, null, false, false)) {
                Application.DoEvents(); Check(tray.TrayVisible, "NotifyIcon component is visible");
                Check(tray.State.Kind == StateKind.Pending, "Normal mode has no fabricated unread status");
                tray.Preview(); Check(tray.State.Kind == StateKind.Pending, "Visual preview cannot replace real monitor state");
            }
            File.WriteAllText(Path.Combine(directory, "windows-tests.json"), JsonSerializer.Serialize(new { success = true, os = RuntimeInformation.OSDescription, architecture = RuntimeInformation.OSArchitecture.ToString(), runtime = RuntimeInformation.FrameworkDescription, passed = passed.Count, tests = passed, realKakaoTested = false, windows11DesktopTested = false }, new JsonSerializerOptions { WriteIndented = true }));
            return 0;
        } catch (Exception error) {
            File.WriteAllText(Path.Combine(directory, "windows-tests.json"), JsonSerializer.Serialize(new { success = false, passed, error = error.ToString() }, new JsonSerializerOptions { WriteIndented = true })); return 1;
        }
    }
}
