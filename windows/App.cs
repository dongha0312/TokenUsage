// Windows 트레이 앱. macOS 판의 UsageModel·WebUsageReader·LimitNotifier·LoginItem 을 옮겼다.
// 메뉴바 글자 대신 트레이 아이콘에 남은 비율 숫자를 그리고, 패널 대신 클릭 메뉴를 띄운다.
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Web.WebView2.Core;
using Microsoft.Web.WebView2.WinForms;
using Microsoft.Win32;

namespace TokenUsage;

static class Program
{
    /// TokenUsage.exe --smoke <파일> : 트레이·웹뷰 경로를 한 바퀴 돌리고 결과를 파일에 남긴 뒤 끝낸다.
    /// CI 에서 실제 exe 가 Windows 에서 뜨는지 확인하는 용도다.
    /// TokenUsage.exe --snapshot <디렉터리> : 샘플 값으로 메뉴와 트레이 아이콘을 PNG 로 떠낸다.
    [STAThread]
    static int Main(string[] args)
    {
        if (args is ["--snapshot", var dir, ..])
        {
            ApplicationConfiguration.Initialize();
            TrayApp.Snapshot(dir);
            return 0;
        }
        var smoke = args.Length >= 2 && args[0] == "--smoke" ? args[1] : null;
        using var mutex = new Mutex(true, @"Local\TokenUsage", out var first);
        if (!first && smoke == null) return 0;   // 이미 떠 있다

        if (smoke != null) Log.Path = smoke;
        else if (Environment.GetEnvironmentVariable("TOKENUSAGE_DEBUG") == "1")
            Log.Path = System.IO.Path.Combine(System.IO.Path.GetTempPath(), "tokenusage-debug.log");

        ApplicationConfiguration.Initialize();
        SynchronizationContext.SetSynchronizationContext(new WindowsFormsSynchronizationContext());
        var app = new TrayApp(smoke != null);
        Application.Run(app);
        return app.ExitCode;
    }
}

static class Log
{
    public static string? Path;
    public static void Write(string msg)
    {
        if (Path == null) return;
        try { File.AppendAllText(Path, $"{DateTime.Now:O} {msg}{Environment.NewLine}"); } catch { }
    }
}

/// 설정은 HKCU\Software\TokenUsage 에 둔다. 시작 프로그램은 HKCU\...\Run.
static class Settings
{
    const string KeyPath = @"Software\TokenUsage";
    const string RunPath = @"Software\Microsoft\Windows\CurrentVersion\Run";

    static int Get(string name, int fallback)
    {
        using var k = Registry.CurrentUser.OpenSubKey(KeyPath);
        return k?.GetValue(name) is int v ? v : fallback;
    }
    static void Set(string name, int value)
    {
        using var k = Registry.CurrentUser.CreateSubKey(KeyPath);
        k.SetValue(name, value, RegistryValueKind.DWord);
    }

    public static readonly int[] Intervals = [2, 5, 15, 30];
    public static int RefreshMinutes
    {
        get { var v = Get("RefreshMinutes", 5); return Intervals.Contains(v) ? v : 5; }
        set => Set("RefreshMinutes", value);
    }
    /// 기본으로 켠다 — 이 앱을 띄우는 이유가 그거다.
    public static bool NotifyNearLimit { get => Get("NotifyNearLimit", 1) == 1; set => Set("NotifyNearLimit", value ? 1 : 0); }

    public static bool LaunchAtLogin
    {
        get { using var k = Registry.CurrentUser.OpenSubKey(RunPath); return k?.GetValue("TokenUsage") != null; }
        set
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunPath);
            if (value) k.SetValue("TokenUsage", $"\"{Environment.ProcessPath}\"");
            else k.DeleteValue("TokenUsage", false);
        }
    }

    /// 첫 실행에만 시작 프로그램에 넣는다. 사용자가 한 번 끄면 다시 손대지 않는다.
    public static void RegisterOnFirstLaunch()
    {
        if (Get("DidAutoRegister", 0) == 1) return;
        LaunchAtLogin = true;
        Set("DidAutoRegister", 1);
    }

    /// Windows 11 은 새 트레이 아이콘을 ^ 안에 숨긴다. 숫자가 보여야 쓸모가 있으니 한 번만 꺼내둔다.
    /// 사용자가 다시 숨기면 그대로 둔다. 탐색기가 아이콘을 본 뒤에야 키를 만들어서 찾을 때까지 매번 시도한다.
    /// ExecutablePath 는 "{알려진 폴더 GUID}\TokenUsage.exe" 꼴이라 파일 이름으로만 맞춘다.
    public static void PromoteTrayIconOnce()
    {
        if (Get("DidPromote", 0) == 1) return;
        using var root = Registry.CurrentUser.OpenSubKey(@"Control Panel\NotifyIconSettings");
        if (root == null) return;   // Windows 10 에는 없다
        var exe = @"\" + Path.GetFileName(Environment.ProcessPath);
        foreach (var name in root.GetSubKeyNames())
        {
            using var k = root.OpenSubKey(name, writable: true);
            if (k?.GetValue("ExecutablePath") is not string p || !p.EndsWith(exe, StringComparison.OrdinalIgnoreCase)) continue;
            k.SetValue("IsPromoted", 1, RegistryValueKind.DWord);
            Set("DidPromote", 1);
            return;
        }
    }
}

/// 숨은 WebView2 로 벤더 사용량 페이지를 띄우고 텍스트만 읽는다. 자격증명은 어디서도 꺼내지 않는다.
/// 쿠키는 %LOCALAPPDATA%\TokenUsage\WebView2 에 남으므로 로그인은 한 번이면 된다.
sealed class WebReader(Provider provider, string url, string title, string host,
                       Func<string, bool> isLoaded,
                       Func<string, DateTimeOffset, (List<UsageWindow> Windows, string? Plan)> parse)
{
    public string Url => url;
    string LoginNote => L10n.LoginNeeded(host);
    /// 스모크 테스트용: 마지막 조회에서 난 예외. 정상 경로(로그인 필요 등)는 여기 안 남는다.
    public string? LastError;

    static Task<CoreWebView2Environment>? env;
    static Task<CoreWebView2Environment> Env() => env ??= CoreWebView2Environment.CreateAsync(null,
        Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "TokenUsage", "WebView2"));

    // 웹뷰는 조회할 때만 만들고 끝나면 버린다. WebView2 는 보조 프로세스 여럿을 끌고 와서 상주시키면 무겁다.
    Form? form;
    WebView2? view;
    bool loginOpen, fetching;

    async Task<WebView2> Make()
    {
        if (form == null)
        {
            var f = new Form
            {
                Text = title, ClientSize = new Size(1000, 800), ShowInTaskbar = false,
                StartPosition = FormStartPosition.CenterScreen, Icon = TrayApp.AppIcon,
            };
            var v = new WebView2 { Dock = DockStyle.Fill };
            f.Controls.Add(v);
            f.FormClosing += (_, e) =>
            {
                if (e.CloseReason != CloseReason.UserClosing) return;
                loginOpen = false;
                // 조회 중이면 웹뷰를 지금 없애지 않는다. 조회가 끝나면 알아서 치운다.
                if (fetching) { e.Cancel = true; f.Hide(); }
            };
            f.FormClosed += (_, _) => { if (form == f) { form = null; view = null; } };
            // 창을 띄우지 않고도 웹뷰가 붙을 수 있게 핸들만 만든다.
            _ = f.Handle;
            _ = v.Handle;
            form = f;
            view = v;
        }
        var w = view!;
        await w.EnsureCoreWebView2Async(await Env());
        return w;
    }

    void Teardown()
    {
        if (loginOpen || form == null) return;   // 로그인 창을 열어둔 동안에는 없애지 않는다
        var f = form;
        form = null;
        view = null;
        f.Dispose();
    }

    public async void ShowLogin()
    {
        try
        {
            var v = await Make();
            loginOpen = true;
            form!.ShowInTaskbar = true;
            form.Show();
            form.Activate();
            v.CoreWebView2.Navigate(url);
        }
        catch (WebView2RuntimeNotFoundException) { TrayApp.OfferWebView2Install(); }
        catch (Exception ex) { Log.Write($"로그인 창 실패 {provider}: {ex}"); }
    }

    static bool IsLoginUrl(string u) =>
        new[] { "accounts.google.com", "ServiceLogin", "auth.openai.com", "auth0.openai.com",
                "/login", "/auth/login", "/sign-in", "/signin" }.Any(u.Contains);

    /// chatgpt.com·gemini 는 같은 URL 에서 로그인 화면을 그린다. 사용량 문구가 없다는 게 확인된 뒤에만 쓴다.
    static bool LooksLikeLogin(string text) =>
        new[] { "로그인", "Log in", "Sign in", "Sign up", "회원가입", "계속하려면", "Continue with Google", "Stay logged out" }
            .Any(m => text.Contains(m, StringComparison.OrdinalIgnoreCase));

    static async Task<string?> PageText(WebView2 v)
    {
        var json = await v.CoreWebView2.ExecuteScriptAsync("document.body ? document.body.innerText : null");
        return JsonSerializer.Deserialize<string?>(json);
    }

    public async Task<ProviderUsage> Fetch(DateTimeOffset now)
    {
        LastError = null;
        fetching = true;
        try
        {
            var v = await Make();
            // 로그인 창이 열려 있으면 페이지를 갈아끼우지 않는다. 비밀번호 입력 중에 날아가면 안 된다.
            var loginWasOpen = loginOpen;
            if (!loginWasOpen) v.CoreWebView2.Navigate(url);

            var started = DateTime.UtcNow;
            var deadline = started.AddSeconds(loginWasOpen ? 3 : 30);
            string? text = null;
            while (DateTime.UtcNow < deadline)
            {
                await Task.Delay(1000);
                if (view != v) return ProviderUsage.Unavailable(provider, L10n.FetchFailed);   // 사용자가 창을 닫았다

                if (IsLoginUrl(v.CoreWebView2.Source)) return ProviderUsage.Unavailable(provider, LoginNote);

                text = await PageText(v);
                if (text == null) continue;
                if (!isLoaded(text))
                {
                    if ((DateTime.UtcNow - started).TotalSeconds > 6 && LooksLikeLogin(text))
                        return ProviderUsage.Unavailable(provider, LoginNote);
                    continue;
                }
                // SPA 는 제목을 먼저 그리고 숫자를 나중에 채운다. 숫자가 읽힐 때까지 기다린다.
                var (windows, plan) = parse(text, now);
                if (windows.Count == 0) continue;

                // 수치가 읽혔다 = 로그인이 끝났다. 열어둔 로그인 창을 치워준다.
                if (loginOpen) { loginOpen = false; form?.Hide(); }
                return new ProviderUsage(provider, windows, now, plan);
            }

            var finalUrl = v.CoreWebView2.Source;
            if (IsLoginUrl(finalUrl)) return ProviderUsage.Unavailable(provider, LoginNote);
            text = await PageText(v) ?? "";
            Log.Write($"    {provider} 실패: url={finalUrl} / 본문={(text.Length == 0 ? "(비어 있음)" : text[..Math.Min(300, text.Length)].ReplaceLineEndings(" / "))}");
            if (isLoaded(text)) return ProviderUsage.Unavailable(provider, L10n.PageChanged);
            return ProviderUsage.Unavailable(provider,
                L10n.PageUnreadable(Uri.TryCreate(finalUrl, UriKind.Absolute, out var u) ? u.Host : "?"));
        }
        catch (Exception ex)
        {
            LastError = ex.ToString();
            Log.Write($"    {provider} 예외: {ex}");
            if (ex is WebView2RuntimeNotFoundException) TrayApp.OfferWebView2Install();
            return ProviderUsage.Unavailable(provider, L10n.PageUnreadable(host));
        }
        finally
        {
            fetching = false;
            Teardown();
        }
    }

    public static Dictionary<Provider, WebReader> All() => new()
    {
        [Provider.Claude] = new(Provider.Claude, "https://claude.ai/settings/usage", "Claude", "claude.ai",
            ClaudeWebParse.IsLoaded, (t, n) => (ClaudeWebParse.Windows(t, n, TimeZoneInfo.Local), ClaudeWebParse.Plan(t))),
        [Provider.Codex] = new(Provider.Codex, "https://chatgpt.com/codex/cloud/settings/analytics#usage", "ChatGPT", "chatgpt.com",
            CodexWebParse.IsLoaded, (t, n) => (CodexWebParse.Windows(t, n, TimeZoneInfo.Local), CodexWebParse.Plan(t))),
        // hl=en 고정: 페이지 언어가 바뀌면 파서가 깨진다.
        [Provider.Gemini] = new(Provider.Gemini, "https://gemini.google.com/usage?hl=en", "Gemini", "gemini.google.com",
            GeminiParse.IsLoaded, (t, n) => (GeminiParse.Windows(t, n, TimeZoneInfo.Local), GeminiParse.Plan(t))),
    };
}

sealed class TrayApp : ApplicationContext
{
    public static readonly Icon AppIcon =
        Icon.ExtractAssociatedIcon(Environment.ProcessPath!) ?? SystemIcons.Application;

    public int ExitCode;
    readonly NotifyIcon tray = new();
    readonly ContextMenuStrip menu = new();
    readonly Dictionary<Provider, WebReader> readers = WebReader.All();

    List<ProviderUsage> usages = [];
    /// 웹에서 받은 실시간 값. 있으면 로컬 폴백보다 우선한다.
    readonly Dictionary<Provider, ProviderUsage> live = [];
    /// 웹 실패 사유. 10초마다 도는 로컬 갱신이 이걸 지우면 로그인 안내가 사라진다.
    readonly Dictionary<Provider, string?> webNote = [];
    readonly Dictionary<string, Severity> lastNotified = [];
    bool refreshingWeb;
    Provider? refreshingProvider;
    Icon? currentIcon;
    /// 스냅샷이 메뉴 명암을 고정할 때만 쓴다.
    bool? darkMenu;

    public TrayApp(bool smoke, bool snapshot = false)
    {
        tray.Icon = AppIcon;
        tray.Text = "TokenUsage";
        tray.ContextMenuStrip = menu;
        menu.Opening += (_, e) => { BuildMenu(); e.Cancel = false; };
        // 왼쪽 클릭에도 메뉴를 연다. 맥의 메뉴바 항목처럼 한 번 누르면 보여야 한다.
        tray.MouseUp += (_, e) =>
        {
            if (e.Button == MouseButtons.Left)
                typeof(NotifyIcon).GetMethod("ShowContextMenu", BindingFlags.Instance | BindingFlags.NonPublic)?.Invoke(tray, null);
        };
        if (snapshot) return;   // 그리기만 한다. 트레이에 올리지 않는다
        tray.Visible = true;

        if (smoke) { RunSmoke(); return; }

        Settings.RegisterOnFirstLaunch();
        Loop(() => TimeSpan.FromSeconds(10), () => { Settings.PromoteTrayIconOnce(); return RefreshLocal(); });
        // 주기는 메뉴에서 바뀔 수 있으므로 매 회차에 다시 읽는다.
        Loop(() => TimeSpan.FromMinutes(Settings.RefreshMinutes), RefreshWeb);
    }

    async void Loop(Func<TimeSpan> every, Func<Task> body)
    {
        while (true)
        {
            try { await body(); } catch (Exception ex) { Log.Write($"갱신 실패: {ex}"); }
            await Task.Delay(every());
        }
    }

    async void RunSmoke()
    {
        try
        {
            // 숨은 웹뷰가 SPA 처럼 늦게 그려지는 페이지를 실제로 읽어내는지. 실제 claude.ai 문구를 2초 뒤에 그린다.
            const string page = "사용량\nMax (5x)\n현재 세션\n재설정: (목) 오전 2:10\n4% 사용됨\n이번 주\n"
                + "재설정: (일요일) 오후 12:00\n7% 사용됨\n이번 주 Fable\n별도 주간 한도 대상: Fable · 재설정: (일요일) 오후 12:00\n1% 사용됨";
            var html = Path.Combine(Path.GetTempPath(), "tokenusage-smoke.html");
            File.WriteAllText(html, "<html><body>loading<script>setTimeout(function(){document.body.innerText = "
                + JsonSerializer.Serialize(page) + "}, 2000)</script></body></html>");
            var fixture = new WebReader(Provider.Claude, new Uri(html).AbsoluteUri, "smoke", "local",
                ClaudeWebParse.IsLoaded, (t, n) => (ClaudeWebParse.Windows(t, n, TimeZoneInfo.Local), ClaudeWebParse.Plan(t)));
            var got = await fixture.Fetch(DateTimeOffset.Now);
            var fixtureOk = got.Windows.Count == 3 && got.Plan == "Max (5x)" && got.Windows[1].UsedPercent == 7;
            Log.Write($"fixture: {got.Windows.Count}개 창, plan={got.Plan}, note={got.Note}, error={fixture.LastError} → {(fixtureOk ? "OK" : "FAIL")}");

            await RefreshLocal();
            await RefreshWeb();
            BuildMenu();
            Log.Write($"트레이 = {tray.Text.ReplaceLineEndings(" / ")}");
            foreach (ToolStripItem item in menu.Items) Log.Write($"메뉴: {item.Text}");
            var errors = readers.Where(r => r.Value.LastError != null).ToList();
            foreach (var (p, r) in errors) Log.Write($"SMOKE FAIL {p}: {r.LastError}");
            ExitCode = errors.Count == 0 && fixtureOk ? 0 : 1;
            Log.Write(ExitCode == 0 ? "SMOKE OK" : "SMOKE FAILED");
        }
        catch (Exception ex) { Log.Write($"SMOKE FAIL: {ex}"); ExitCode = 1; }
        Quit();
    }

    // MARK: - 갱신

    /// 로컬 파일(~/.claude.json, ~/.codex/sessions)에서 읽는 폴백. 웹 로그인 전에도 뭔가는 보여준다.
    static Task<List<ProviderUsage>> LocalFallbacks(DateTimeOffset now, IEnumerable<Provider> needed)
    {
        var list = needed.Where(p => p != Provider.Gemini).ToList();   // Gemini 는 로컬 출처가 없다
        return Task.Run(() => list.Select(p => p == Provider.Claude ? ClaudeReader.Read(now) : CodexReader.Read(now)).ToList());
    }

    async Task RefreshLocal()
    {
        var now = DateTimeOffset.Now;
        foreach (var f in await LocalFallbacks(now, Enum.GetValues<Provider>().Where(p => !live.ContainsKey(p))))
        {
            if (live.ContainsKey(f.Provider)) continue;
            Replace(f with { Note = webNote.GetValueOrDefault(f.Provider) ?? f.Note });
        }
        if (Settings.NotifyNearLimit) CheckLimits();
        Render();
    }

    async Task RefreshWeb()
    {
        if (refreshingWeb) return;   // 두 조회가 겹치면 한쪽 teardown 이 다른 쪽 웹뷰를 없앤다
        refreshingWeb = true;
        try
        {
            var now = DateTimeOffset.Now;
            // 웹이 리셋 시각을 빠뜨렸을 때 채우려고 실시간 여부와 무관하게 읽는다.
            var fallbacks = (await LocalFallbacks(now, Enum.GetValues<Provider>())).ToDictionary(u => u.Provider);

            foreach (var provider in Enum.GetValues<Provider>())
            {
                refreshingProvider = provider;
                Render();
                var started = DateTime.UtcNow;
                var result = await readers[provider].Fetch(now);
                Log.Write($"  {provider}: {(DateTime.UtcNow - started).TotalSeconds:0}초 · " + (result.Windows.Count == 0
                    ? result.Note ?? "실패"
                    : $"[{result.Plan ?? "-"}] " + string.Join(" | ", result.Windows.Select(w => $"{w.Label} {w.Summary(now)}"))));
                fallbacks.TryGetValue(provider, out var fallback);

                if (result.Windows.Count > 0)
                {
                    var merged = new ProviderUsage(provider,
                        Usage.FillingMissingResets(result.Windows, fallback?.Windows ?? []),
                        result.UpdatedAt, result.Plan ?? fallback?.Plan);
                    live[provider] = merged;
                    webNote[provider] = null;
                    Replace(merged);
                    continue;
                }

                // 웹을 못 읽었으면 로컬로 돌아가되, 왜 실시간이 아닌지는 알린다.
                live.Remove(provider);
                if (fallback == null || fallback.Windows.Count == 0)
                {
                    webNote[provider] = result.Note;
                    Replace(result);
                    continue;
                }
                webNote[provider] = $"{result.Note ?? L10n.FetchFailed} · {L10n.ShowingLocal}";
                Replace(fallback with { Note = webNote[provider] });
            }
        }
        finally
        {
            refreshingWeb = false;
            refreshingProvider = null;
        }
        if (Settings.NotifyNearLimit) CheckLimits();
        Render();
    }

    void Replace(ProviderUsage u)
    {
        usages = usages.Where(x => x.Provider != u.Provider).Append(u).OrderBy(x => x.Provider).ToList();
    }

    // MARK: - 알림: 80% 넘으면 한 번, 95% 넘으면 다시 한 번. 초기화되면 다시 알릴 수 있게 푼다.

    void CheckLimits()
    {
        foreach (var u in usages)
            foreach (var w in u.Windows)
            {
                var key = $"{u.Provider}:{w.Kind.Id}";
                var previous = lastNotified.GetValueOrDefault(key, Severity.Normal);
                if (w.Severity == Severity.Normal) { lastNotified[key] = Severity.Normal; continue; }
                if (w.Severity == previous || w.UsedPercent is not double used) continue;
                lastNotified[key] = w.Severity;
                tray.ShowBalloonTip(10000, L10n.NearLimitTitle(u.Provider.ToString()),
                    L10n.NearLimitBody(w.Label, Usage.Round(used), w.TimeToReset(DateTimeOffset.Now)),
                    w.Severity == Severity.Critical ? ToolTipIcon.Warning : ToolTipIcon.Info);
            }
    }

    // MARK: - 표시

    void Render()
    {
        var now = DateTimeOffset.Now;
        var urgent = Usage.MostUrgent(usages);
        var old = currentIcon;
        currentIcon = DrawIcon(Usage.TrayNumber(usages), urgent?.Window.Severity ?? Severity.Normal, TaskbarIsLight());
        tray.Icon = currentIcon;
        old?.Dispose();

        var head = urgent is var (u, _) ? $"{u.Provider} {Usage.TrayText(usages, now)}" : "TokenUsage";
        var all = string.Join(" · ", Usage.Entries(usages).Select(e => $"{e.Provider} {e.Text}"));
        var text = all.Length > 0 ? $"{head}\n{all}" : head;
        tray.Text = text.Length > 127 ? text[..127] : text;   // NotifyIcon 툴팁 상한

        if (menu.Visible) BuildMenu();
    }

    static bool TaskbarIsLight()
    {
        using var k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize");
        return k?.GetValue("SystemUsesLightTheme") is int v && v == 1;
    }

    [DllImport("user32.dll")] static extern bool DestroyIcon(IntPtr handle);

    /// 경고·위험 색. 밝은 바탕에서는 맥 시스템 색 그대로면 흐려서 진한 쪽을 쓴다.
    static Color? Alert(Severity severity, bool onLight) => severity switch
    {
        Severity.Critical => onLight ? Color.FromArgb(215, 0, 21) : Color.FromArgb(255, 69, 58),
        Severity.Warning => onLight ? Color.FromArgb(201, 52, 0) : Color.FromArgb(255, 159, 10),
        _ => null,
    };

    /// 트레이에는 글자를 못 올린다. 남은 비율 숫자를 아이콘에 직접 그린다. 경고면 주황, 위험이면 빨강.
    static Icon DrawIcon(int? remaining, Severity severity, bool lightTaskbar)
    {
        var size = SystemInformation.SmallIconSize;
        using var bmp = new Bitmap(size.Width, size.Height);
        using (var g = Graphics.FromImage(bmp))
        {
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            var color = Alert(severity, lightTaskbar) ?? (lightTaskbar ? Color.Black : Color.White);
            var text = remaining?.ToString() ?? "–";
            using var fmt = new StringFormat(StringFormat.GenericTypographic)
                { Alignment = StringAlignment.Center, LineAlignment = StringAlignment.Center };
            // 세 자리(100)도 들어가게 줄여가며 맞춘다.
            var px = size.Height * 0.95f;
            Font font;
            while (true)
            {
                font = new Font("Segoe UI", px, FontStyle.Bold, GraphicsUnit.Pixel);
                if (px <= 6 || g.MeasureString(text, font, int.MaxValue, fmt).Width <= size.Width) break;
                font.Dispose();
                px -= 0.5f;
            }
            using (font)
            using (var brush = new SolidBrush(color))
                g.DrawString(text, font, brush, new RectangleF(0, 0, size.Width, size.Height + 1), fmt);
        }
        var h = bmp.GetHicon();
        var icon = (Icon)Icon.FromHandle(h).Clone();
        DestroyIcon(h);
        return icon;
    }

    void BuildMenu()
    {
        var now = DateTimeOffset.Now;
        menu.SuspendLayout();
        menu.Items.Clear();
        var bold = new Font(menu.Font, FontStyle.Bold);
        // 메뉴는 작업 표시줄에서 열리니 그 명암을 따른다. 고대비 모드면 시스템 색을 그대로 둔다.
        var dark = darkMenu ?? (!TaskbarIsLight() && !SystemInformation.HighContrast);
        menu.Renderer = dark ? MenuRenderer.Dark : MenuRenderer.Light;

        foreach (var u in usages)
        {
            var header = u.Provider.ToString() + (u.Plan != null ? $"  ·  {u.Plan}" : "");
            menu.Items.Add(new ToolStripMenuItem(header) { Font = bold, Enabled = true });
            // 수치는 단축키 자리에 둬서 오른쪽 한 열로 맞추고, 밑에 맥 패널처럼 막대를 단다.
            foreach (var w in u.Windows)
            {
                var row = new ToolStripMenuItem(w.Label)
                {
                    ShortcutKeyDisplayString = w.Summary(now),
                    ForeColor = Alert(w.Severity, !dark) ?? SystemColors.MenuText,
                };
                menu.Items.Add(row);
                if (w.UsedPercent is not double used) continue;
                var bar = new UsageBar(used,
                    Alert(w.Severity, !dark) ?? (dark ? Color.FromArgb(10, 132, 255) : Color.FromArgb(0, 122, 255)),
                    dark ? Color.FromArgb(60, 255, 255, 255) : Color.FromArgb(30, 0, 0, 0));
                row.Tag = bar;
                menu.Items.Add(bar);
            }
            var extra = new[] { u.Note, Usage.UpdatedAgo(u.UpdatedAt, now) }.Where(s => s != null);
            foreach (var s in extra) menu.Items.Add(new ToolStripMenuItem(s) { Enabled = false });
            menu.Items.Add(new ToolStripSeparator());
        }

        if (refreshingWeb)
            menu.Items.Add(new ToolStripMenuItem(refreshingProvider is Provider rp
                ? $"{L10n.Refreshing}  {L10n.Checking(rp.ToString())}" : L10n.Refreshing) { Enabled = false });
        menu.Items.Add(L10n.Refresh, null, (_, _) => RefreshAll()).Enabled = !refreshingWeb;

        // 실시간 값이 없는 제공자는 로그인 메뉴를 항상 보여준다.
        foreach (var p in Enum.GetValues<Provider>().Where(p => !live.ContainsKey(p)))
            menu.Items.Add(L10n.SignIn(p.ToString()), null, (_, _) => readers[p].ShowLogin());

        var open = new ToolStripMenuItem(L10n.OpenUsagePage);
        foreach (var p in Enum.GetValues<Provider>())
            open.DropDownItems.Add(p.ToString(), null, (_, _) => OpenInBrowser(readers[p].Url));
        menu.Items.Add(open);
        menu.Items.Add(new ToolStripSeparator());

        var every = new ToolStripMenuItem(L10n.RefreshEvery);
        foreach (var m in Settings.Intervals)
            every.DropDownItems.Add(new ToolStripMenuItem(L10n.Minutes(m), null, (_, _) =>
            {
                Settings.RefreshMinutes = m;
                _ = RefreshWeb();   // 바로 반영해준다
            }) { Checked = Settings.RefreshMinutes == m });
        menu.Items.Add(every);

        menu.Items.Add(new ToolStripMenuItem(L10n.NotifyNearLimit, null, (_, _) =>
        {
            var on = !Settings.NotifyNearLimit;
            Settings.NotifyNearLimit = on;
            lastNotified.Clear();   // 껐다 켰을 때 직전 상태 때문에 조용해지지 않게
            if (on) tray.ShowBalloonTip(5000, L10n.NotificationsOnTitle, L10n.NotificationsOnBody, ToolTipIcon.Info);
        }) { Checked = Settings.NotifyNearLimit });

        menu.Items.Add(new ToolStripMenuItem(L10n.LaunchAtLogin, null,
            (_, _) => Settings.LaunchAtLogin = !Settings.LaunchAtLogin) { Checked = Settings.LaunchAtLogin });

        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add(L10n.Quit, null, (_, _) => Quit());
        menu.ResumeLayout();
    }

    /// --snapshot: 문서용 이미지. 맥 판 --snapshot 처럼 목업이 아니라 BuildMenu·DrawIcon 을 그대로 탄다.
    public static void Snapshot(string dir)
    {
        Directory.CreateDirectory(dir);
        var now = DateTimeOffset.Now;
        // 맥 판과 같은 샘플. Codex 세션을 경고 구간에 둬서 색이 어떻게 보이는지도 담는다.
        List<ProviderUsage> sample =
        [
            new(Provider.Claude, [
                new(new WindowKind.Session(5), 34, now.AddMinutes(190)),
                new(new WindowKind.WeeklyAllModels(), 12, now.AddDays(3)),
                new(new WindowKind.WeeklyScoped("Opus"), 3, now.AddDays(3)),
            ], now, "MAX"),
            new(Provider.Codex, [
                new(new WindowKind.Session(5), 86, now.AddMinutes(41)),
                new(new WindowKind.Weekly(), 45, now.AddDays(2)),
            ], now.AddMinutes(-14), "PLUS"),
            new(Provider.Gemini, [
                new(new WindowKind.Session(null), 8, now.AddMinutes(52)),
                new(new WindowKind.Weekly(), 21, now.AddDays(5)),
            ], now, "PRO"),
        ];

        var original = L10n.IsKorean;
        foreach (var (korean, lang) in new[] { (false, "en"), (true, "ko") })
        foreach (var (dark, mode) in new[] { (false, "light"), (true, "dark") })
        {
            L10n.IsKorean = korean;
            var app = new TrayApp(smoke: false, snapshot: true) { usages = sample, darkMenu = dark };
            foreach (var u in sample) app.live[u.Provider] = u;
            app.BuildMenu();
            var size = app.menu.GetPreferredSize(Size.Empty);
            app.menu.Size = size;
            using var bmp = new Bitmap(size.Width, size.Height);
            app.menu.DrawToBitmap(bmp, new Rectangle(Point.Empty, size));
            bmp.Save(Path.Combine(dir, $"windows-menu-{lang}-{mode}.png"));
            app.tray.Dispose();
        }
        L10n.IsKorean = original;

        // 작업 표시줄 한 칸처럼 바탕을 깔고 경우별 아이콘을 나란히 둔 뒤, 픽셀이 보이게 3배로 키운다.
        (int? Left, Severity Severity)[] cases =
            [(66, Severity.Normal), (14, Severity.Warning), (3, Severity.Critical), (null, Severity.Normal)];
        var icon = SystemInformation.SmallIconSize;
        const int gap = 8, scale = 3;
        foreach (var (light, mode) in new[] { (true, "light"), (false, "dark") })
        {
            using var strip = new Bitmap(gap + cases.Length * (icon.Width + gap), icon.Height + 2 * gap);
            using (var g = Graphics.FromImage(strip))
            {
                g.Clear(light ? Color.FromArgb(243, 243, 243) : Color.FromArgb(32, 32, 32));
                for (var i = 0; i < cases.Length; i++)
                {
                    using var ic = DrawIcon(cases[i].Left, cases[i].Severity, light);
                    using var b = ic.ToBitmap();
                    g.DrawImage(b, gap + i * (icon.Width + gap), gap);
                }
            }
            using var big = new Bitmap(strip.Width * scale, strip.Height * scale);
            using (var g = Graphics.FromImage(big))
            {
                g.InterpolationMode = InterpolationMode.NearestNeighbor;
                g.PixelOffsetMode = PixelOffsetMode.Half;
                g.DrawImage(strip, 0, 0, big.Width, big.Height);
            }
            big.Save(Path.Combine(dir, $"windows-tray-{mode}.png"));
        }
    }

    void RefreshAll()
    {
        _ = RefreshLocal();
        _ = RefreshWeb();
    }

    static void OpenInBrowser(string url) =>
        System.Diagnostics.Process.Start(new System.Diagnostics.ProcessStartInfo(url) { UseShellExecute = true });

    static bool offeredWebView2;
    public static void OfferWebView2Install()
    {
        if (offeredWebView2) return;
        offeredWebView2 = true;
        if (MessageBox.Show(L10n.WebView2Missing, "TokenUsage", MessageBoxButtons.YesNo) == DialogResult.Yes)
            OpenInBrowser("https://developer.microsoft.com/microsoft-edge/webview2/");
    }

    void Quit()
    {
        tray.Visible = false;
        tray.Dispose();
        ExitThread();
    }
}

/// 한도 줄 밑의 막대. 메뉴 항목은 높이가 모두 같아서 줄 안에 넣을 자리가 없어 따로 한 줄을 쓴다.
/// 글자 열의 위치는 공개 API로 알 수 없다. 바로 위 줄을 그릴 때 렌더러가 Column 에 넣어준다.
sealed class UsageBar : ToolStripItem
{
    public (int Left, int Right) Column;
    readonly double used;
    readonly Color fill, track;

    public UsageBar(double used, Color fill, Color track)
    {
        (this.used, this.fill, this.track) = (used, fill, track);
        // 폭은 메뉴를 넓히지 않게 1로 두고, 좌우 고정으로 열 너비만큼 늘린다.
        Anchor = AnchorStyles.Left | AnchorStyles.Right;
    }

    public override bool CanSelect => false;
    public override Size GetPreferredSize(Size constrainingSize) => new(1, Owner?.LogicalToDeviceUnits(8) ?? 8);

    protected override void OnPaint(PaintEventArgs e)
    {
        if (Column.Right <= Column.Left) return;   // 위 줄이 아직 안 그려졌다
        var t = Owner?.LogicalToDeviceUnits(4) ?? 4;
        // 둥근 끝이 선 밖으로 t/2 나가므로 그만큼 안쪽에서 긋는다. 2는 글자 여백에 맞춘 것.
        float left = Column.Left + 2 + t / 2f, right = Column.Right - 2 - t / 2f, y = t / 2f + 1;
        var g = e.Graphics;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var pen = new Pen(track, t) { StartCap = LineCap.Round, EndCap = LineCap.Round };
        g.DrawLine(pen, left, y, right, y);
        if (used <= 0) return;
        pen.Color = fill;
        g.DrawLine(pen, left, y, left + (right - left) * (float)(used / 100), y);
    }
}

/// 메뉴 렌더러. 막대에 글자 열을 알려주고, 어두우면 색을 바꾼다. WinForms 메뉴는 Windows 다크 모드를
/// 따르지 않는다. 색표만 바꿔서는 안 되는 게, 글자·화살표·체크를 SystemColors(검정)로 박아 그리기 때문이다.
/// 그 셋은 여기서 직접 칠한다.
sealed class MenuRenderer : ToolStripProfessionalRenderer
{
    public static readonly MenuRenderer Light = new(false), Dark = new(true);
    readonly bool dark;
    MenuRenderer(bool dark) : base(dark ? new Palette() : new ProfessionalColorTable()) => this.dark = dark;

    static readonly Color Back = Color.FromArgb(43, 43, 43), Hover = Color.FromArgb(65, 65, 65),
        Line = Color.FromArgb(75, 75, 75), Text = Color.FromArgb(242, 242, 242), Dim = Color.FromArgb(150, 150, 150);

    sealed class Palette : ProfessionalColorTable
    {
        public override Color ToolStripDropDownBackground => Back;
        public override Color ImageMarginGradientBegin => Back;
        public override Color ImageMarginGradientMiddle => Back;
        public override Color ImageMarginGradientEnd => Back;
        public override Color MenuBorder => Line;
        public override Color MenuItemBorder => Hover;
        public override Color MenuItemSelectedGradientBegin => Hover;
        public override Color MenuItemSelectedGradientEnd => Hover;
        public override Color SeparatorDark => Line;
        public override Color SeparatorLight => Back;
    }

    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    {
        if (e.Item?.Tag is UsageBar bar) bar.Column = (e.TextRectangle.Left, e.TextRectangle.Right);
        if (!dark) { base.OnRenderItemText(e); return; }
        // 경고색처럼 직접 준 색은 살리고, 시스템 기본색(검정)만 밝은 글자로 바꾼다.
        TextRenderer.DrawText(e.Graphics, e.Text, e.TextFont, e.TextRectangle,
            e.Item is not { Enabled: true } ? Dim : e.TextColor.IsSystemColor ? Text : e.TextColor, e.TextFormat);
    }

    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
    {
        if (dark) e.ArrowColor = e.Item is { Enabled: true } ? Text : Dim;
        base.OnRenderArrow(e);
    }

    // 기본 체크는 검은 그림이라 어두운 바탕에 묻힌다. 선으로 긋는다.
    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
    {
        if (!dark) { base.OnRenderItemCheck(e); return; }
        var (g, r) = (e.Graphics, e.ImageRectangle);
        var smoothing = g.SmoothingMode;
        g.SmoothingMode = SmoothingMode.AntiAlias;
        using var pen = new Pen(Text, Math.Max(1.5f, r.Height / 10f));
        g.DrawLines(pen, new PointF[]
        {
            new(r.X + r.Width * .22f, r.Y + r.Height * .52f),
            new(r.X + r.Width * .42f, r.Y + r.Height * .72f),
            new(r.X + r.Width * .78f, r.Y + r.Height * .30f),
        });
        g.SmoothingMode = smoothing;
    }
}
