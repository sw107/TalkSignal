using TalkSignal.Core;
namespace TalkSignal.Windows;

internal sealed class SettingsForm : Form
{
    internal readonly TextBox TargetBox = new() { Dock = DockStyle.Fill, MaxLength = 200, AccessibleName = "감지할 이름" };
    internal readonly ComboBox IconsBox = new() { DropDownStyle = ComboBoxStyle.DropDownList, Dock = DockStyle.Fill, AccessibleName = "아이콘" };
    internal readonly CheckBox CountBox = new() { Text = "트레이 아이콘에 안 읽은 숫자 표시", AutoSize = true };
    internal readonly CheckBox StartupBox = new() { Text = "Windows 로그인할 때 자동 실행", AutoSize = true };
    internal readonly Button SaveButton = new() { Text = "저장하고 적용", AutoSize = true, Padding = new Padding(10, 5, 10, 5) };
    private readonly Label status = new() { AutoSize = true, MaximumSize = new Size(440, 0), ForeColor = Color.DarkOrange };
    private readonly Label error = new() { AutoSize = true, MaximumSize = new Size(440, 0), ForeColor = Color.Firebrick };
    internal Action<Preferences, bool>? SaveRequested;
    internal Action? PreviewRequested;
    internal Action? OpenRequested;
    internal Action? DemoRequested;
    internal SettingsForm(Preferences preferences, bool startup, bool demo)
    {
        Text = demo ? "TalkSignal · 표시 체험" : "TalkSignal · Windows 준비판";
        AutoScaleMode = AutoScaleMode.Dpi;
        ClientSize = new Size(520, 660);
        MinimumSize = new Size(520, 660);
        Font = new Font("Malgun Gothic", 10);
        BackColor = Color.FromArgb(248, 249, 252);
        StartPosition = FormStartPosition.CenterScreen;
        var stack = new FlowLayoutPanel { Dock = DockStyle.Fill, FlowDirection = FlowDirection.TopDown, WrapContents = false, AutoScroll = true, Padding = new Padding(28), BackColor = BackColor };
        Controls.Add(stack);
        Label Label(string text, float size = 10, bool bold = false) => new() { Text = text, AutoSize = true, MaximumSize = new Size(440, 0), Font = new Font(Font.FontFamily, size, bold ? FontStyle.Bold : FontStyle.Regular), Margin = new Padding(0, 0, 0, 12) };
        void Full(Control c) { c.Width = 440; c.Margin = new Padding(0, 0, 0, 14); stack.Controls.Add(c); }
        Full(Label("소중한 연락, 작업표시줄에서", 19, true));
        Full(Label("Windows 준비판 · 실제 카톡 감지 연결은 아직 미완성입니다.\n현재 버전은 안 읽음이나 폰의 읽음 상태를 자동으로 확인하지 않습니다."));
        Full(Label("개인 이름 또는 채팅방 이름", 10, true));
        TargetBox.Text = preferences.Target; Full(TargetBox);
        Full(Label("띄어쓰기와 이모지까지 같게 입력해 주세요. 같은 이름의 여러 방을 임의로 고르지 않습니다.", 9));
        IconsBox.Items.AddRange(["하트", "말풍선", "별", "종"]);
        IconsBox.SelectedIndex = (int)preferences.Icon; Full(IconsBox);
        CountBox.Checked = preferences.ShowCount; Full(CountBox);
        StartupBox.Checked = startup; StartupBox.Enabled = !demo; Full(StartupBox);
        Full(status);
        var actions = new FlowLayoutPanel { AutoSize = true, Width = 440, Margin = new Padding(0, 8, 0, 8) };
        var preview = new Button { Text = "표시 미리보기", AutoSize = true, Padding = new Padding(10, 5, 10, 5) };
        actions.Controls.Add(SaveButton); actions.Controls.Add(preview); stack.Controls.Add(actions);
        var second = new FlowLayoutPanel { AutoSize = true, Width = 440, Margin = new Padding(0, 0, 0, 10) };
        var open = new Button { Text = "카카오톡 열기", AutoSize = true };
        var demonstration = new Button { Text = "수신·읽음 표시 체험", AutoSize = true };
        second.Controls.Add(open); second.Controls.Add(demonstration); stack.Controls.Add(second);
        Full(error);
        Full(Label("우클릭으로 설정·미리보기·종료 메뉴를 엽니다.\n자동 감지와 새 대화창 바로 열기는 실제 Windows 카톡에서 추가 개발·검증이 필요합니다.", 9));
        SaveButton.Click += (_, _) => {
            try {
                var value = new Preferences(TargetBox.Text, (Glyph)Math.Max(0, IconsBox.SelectedIndex), CountBox.Checked).Validate();
                if (value.Target.Length == 0) throw new ArgumentException("감지할 이름을 입력해 주세요.");
                SaveRequested?.Invoke(value, StartupBox.Checked); error.Text = "설정을 저장했어요."; error.ForeColor = Color.SeaGreen;
            } catch (Exception ex) when (ex is ArgumentException or IOException or UnauthorizedAccessException or System.Security.SecurityException) {
                error.Text = ex.Message; error.ForeColor = Color.Firebrick;
            }
        };
        preview.Click += (_, _) => PreviewRequested?.Invoke();
        open.Click += (_, _) => OpenRequested?.Invoke();
        demonstration.Click += (_, _) => DemoRequested?.Invoke();
        AcceptButton = SaveButton;
        UpdateStatus(new(preferences.Target.Length == 0 ? StateKind.Unconfigured : StateKind.Pending));
    }
    internal void UpdateStatus(SignalState value)
    {
        status.Text = value.Description;
        status.ForeColor = value.HasUnread ? Color.DeepPink : value.Warning ? Color.DarkOrange : Color.DimGray;
    }
}
internal sealed class DemoForm : Form
{
    internal DemoForm(Action<int?> change)
    {
        Text = "표시 체험 · 실제 카톡 아님";
        ClientSize = new Size(430, 200); Font = new Font("Malgun Gothic", 10);
        var panel = new FlowLayoutPanel { Dock = DockStyle.Fill, Padding = new Padding(20), FlowDirection = FlowDirection.TopDown, WrapContents = false };
        panel.Controls.Add(new Label { Text = "가상 데이터로 트레이 표시만 바꿉니다.\n실제 카톡과 폰의 읽음 상태는 바뀌지 않습니다.", AutoSize = true, Margin = new Padding(0, 0, 0, 15) });
        var buttons = new FlowLayoutPanel { AutoSize = true };
        foreach (var pair in new (string Name, int? Count)[] { ("수신 3개", 3), ("읽음 0개", 0), ("조회 실패", null) }) {
            var button = new Button { Text = pair.Name, AutoSize = true };
            var count = pair.Count; button.Click += (_, _) => change(count); buttons.Controls.Add(button);
        }
        panel.Controls.Add(buttons); Controls.Add(panel);
    }
}
