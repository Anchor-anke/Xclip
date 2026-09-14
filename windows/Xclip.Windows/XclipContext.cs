using System.Drawing.Imaging;
using Xclip.Core;

namespace Xclip.Windows;

internal sealed class XclipContext : ApplicationContext
{
    private readonly HistoryStore store;
    private readonly HistoryForm history;
    private readonly ClipboardService clipboard;
    private readonly NotifyIcon tray;
    private readonly System.Windows.Forms.Timer foregroundTimer = new() { Interval = 200 };
    private readonly EventWaitHandle showEvent;
    private nint lastExternalWindow;
    private nint pasteTarget;
    private bool capturing;
    private bool pasting;
    private bool exiting;
    private int operation;

    internal XclipContext(HistoryStore store, EventWaitHandle showEvent)
    {
        this.store = store;
        this.showEvent = showEvent;
        lastExternalWindow = NativeMethods.GetForegroundWindow();
        history = new HistoryForm(store);
        _ = history.Handle;
        clipboard = new ClipboardService(store);
        clipboard.Changed += () => { if (history.Visible) history.RefreshEntries(); };
        clipboard.Failed += Report;
        clipboard.Shortcut += key => history.BeginInvoke(new Action(() =>
        {
            if (key == 1) ShowHistory(rememberForeground: true);
            if (key == 2) _ = CaptureAsync();
        }));
        history.CopyRequested += entry => Copy(entry);
        history.PasteRequested += entry => _ = PasteAsync(entry);
        history.CaptureRequested += () => _ = CaptureAsync();
        history.PauseChanged += paused =>
        {
            clipboard.Paused = paused;
            history.SetStatus(paused ? "已暂停记录，新复制的内容不会保存。" : "正在记录剪贴板。Ctrl+Alt+V 打开历史，Ctrl+Alt+A 截图。");
        };

        var menu = new ContextMenuStrip();
        menu.Items.Add("打开历史  Ctrl+Alt+V", null, (_, _) => ShowHistory());
        menu.Items.Add("截屏标注  Ctrl+Alt+A", null, (_, _) => _ = CaptureAsync());
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("退出 Xclip", null, (_, _) => ExitThread());
        tray = new NotifyIcon
        {
            Text = "Xclip · Windows 预览版",
            Icon = System.Drawing.Icon.ExtractAssociatedIcon(Application.ExecutablePath) ?? SystemIcons.Application,
            ContextMenuStrip = menu,
            Visible = true
        };
        tray.DoubleClick += (_, _) => ShowHistory();
        foregroundTimer.Tick += (_, _) =>
        {
            if (showEvent.WaitOne(0)) ShowHistory();
            var foreground = NativeMethods.GetForegroundWindow();
            if (!capturing && !pasting && NativeMethods.IsExternalWindow(foreground))
                lastExternalWindow = foreground;
        };
        foregroundTimer.Start();
        ShowHistory();
        if (clipboard.RegistrationWarnings.Count > 0) Report(string.Join("\n", clipboard.RegistrationWarnings));
    }

    private void ShowHistory(bool rememberForeground = false)
    {
        if (capturing || exiting) return;
        operation++;
        if (!history.Visible || rememberForeground)
        {
            var foreground = NativeMethods.GetForegroundWindow();
            pasteTarget = rememberForeground && NativeMethods.IsExternalWindow(foreground) ? foreground : lastExternalWindow;
            var area = Screen.FromPoint(Cursor.Position).WorkingArea;
            // A laptop at 150–200% scaling may have less space than our preferred logical size.
            // Fit the outer window before centering so the footer and close control stay reachable.
            var available = new Size(Math.Max(1, area.Width - 16), Math.Max(1, area.Height - 16));
            history.MinimumSize = new Size(Math.Min(history.MinimumSize.Width, available.Width),
                Math.Min(history.MinimumSize.Height, available.Height));
            history.Size = new Size(Math.Min(history.Width, available.Width), Math.Min(history.Height, available.Height));
            history.Location = new Point(area.Left + Math.Max(0, (area.Width - history.Width) / 2),
                area.Top + Math.Max(0, (area.Height - history.Height) / 2));
        }
        history.Show();
        if (history.WindowState == FormWindowState.Minimized) history.WindowState = FormWindowState.Normal;
        history.Activate();
        history.PrepareToShow();
    }

    private bool Copy(ClipboardEntry entry)
    {
        try
        {
            // Resolve by stable ID so a stale selection cannot overwrite the clipboard.
            var current = store.Entries.FirstOrDefault(item => item.Id == entry.Id)
                ?? throw new InvalidOperationException("该条历史已不存在，请重新选择。");
            clipboard.Write(current);
            history.SetStatus("已复制，可切换到目标应用按 Ctrl+V。");
            return true;
        }
        catch (Exception ex) when (ex is not OutOfMemoryException) { Report(ex.Message); return false; }
    }

    private async Task PasteAsync(ClipboardEntry entry)
    {
        if (pasting || capturing || exiting) return;
        var target = pasteTarget;
        if (!Copy(entry)) return;
        var copiedSequence = NativeMethods.GetClipboardSequenceNumber();
        if (!NativeMethods.IsExternalWindow(target))
        {
            Report("已复制。请切换到目标应用按 Ctrl+V，或在目标应用中按 Ctrl+Alt+V 打开面板。");
            return;
        }
        pasting = true;
        var token = ++operation;
        try
        {
            // Keep key repeats inside our panel until the invocation keys are released.
            var released = false;
            for (var attempt = 0; attempt < 50; attempt++)
            {
                await Task.Delay(20);
                if (exiting || token != operation || !history.Visible) return;
                if (NativeMethods.GetForegroundWindow() != history.Handle)
                {
                    Report("已复制；窗口焦点已改变，本次自动粘贴已取消。");
                    return;
                }
                if (NativeMethods.InvocationKeysReleased()) { released = true; break; }
            }
            if (!released) { Report("已复制；检测到按键仍未松开，请松开后在目标应用按 Ctrl+V。"); return; }
            history.Hide();
            if (!NativeMethods.SetForegroundWindow(target))
            {
                Report("已复制，但目标窗口未能激活。请自行切换后按 Ctrl+V。");
                return;
            }
            // Let the invocation modifiers go up naturally; never release the user's held keys.
            for (var attempt = 0; attempt < 25; attempt++)
            {
                await Task.Delay(40);
                if (exiting || token != operation) return;
                if (NativeMethods.GetForegroundWindow() != target)
                {
                    Report("已复制；窗口焦点已改变，本次自动粘贴已取消。");
                    return;
                }
                if (NativeMethods.GetClipboardSequenceNumber() != copiedSequence)
                {
                    Report("剪贴板内容已改变，本次自动粘贴已取消。");
                    return;
                }
                if (!NativeMethods.InvocationKeysReleased()) continue;
                if (!NativeMethods.SendPaste())
                    Report("已复制，但系统未接受自动粘贴。请在目标应用中按 Ctrl+V。");
                else history.SetStatus("已复制并发送粘贴快捷键，请在目标应用确认结果。");
                return;
            }
            Report("已复制；检测到按键仍未松开，请松开后在目标应用按 Ctrl+V。");
        }
        finally { pasting = false; }
    }

    private async Task CaptureAsync()
    {
        if (capturing || pasting || exiting) return;
        capturing = true;
        var token = ++operation;
        var restore = history.Visible;
        try
        {
            history.Hide();
            await Task.Delay(220); // Allow the hidden history/menu to disappear before screen capture.
            if (exiting || token != operation) return;
            using var bitmap = CaptureForm.CaptureAndAnnotate();
            if (bitmap == null) return;
            using var stream = new MemoryStream();
            bitmap.Save(stream, ImageFormat.Png);
            var entry = store.AddImage(stream.ToArray(), "Xclip 截图");
            history.RefreshEntries();
            clipboard.Write(entry);
            history.SetStatus("截图已复制并保存到历史。");
        }
        catch (Exception ex) when (ex is not OutOfMemoryException) { Report($"截图未完成：{ex.Message}"); }
        finally
        {
            capturing = false;
            if (restore && !exiting) ShowHistory();
        }
    }

    private void Report(string message)
    {
        if (exiting) return;
        history.SetStatus(message);
        if (!history.Visible)
        {
            tray.ShowBalloonTip(5000, "Xclip", message.Length > 240 ? message[..240] : message, ToolTipIcon.Info);
        }
    }

    protected override void ExitThreadCore()
    {
        if (capturing) { Report("请先完成或取消截图，再退出 Xclip。"); return; }
        exiting = true;
        operation++;
        foregroundTimer.Stop();
        tray.Visible = false;
        history.AllowClose = true;
        history.Close();
        base.ExitThreadCore();
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            exiting = true;
            operation++;
            foregroundTimer.Dispose();
            clipboard.Dispose();
            tray.Visible = false;
            tray.ContextMenuStrip?.Dispose();
            tray.Icon?.Dispose();
            tray.Dispose();
            history.Dispose();
        }
        base.Dispose(disposing);
    }
}
