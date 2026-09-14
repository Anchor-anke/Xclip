using System.Collections.Specialized;
using System.Drawing.Imaging;
using System.Runtime.InteropServices;
using Xclip.Core;

namespace Xclip.Windows;

/// <summary>All clipboard calls run on the Forms STA thread. No remote data is deserialized.</summary>
internal sealed class ClipboardService : NativeWindow, IDisposable
{
    private readonly HistoryStore store;
    private readonly System.Windows.Forms.Timer retry = new() { Interval = 100 };
    private uint observedSequence;
    private uint ownSequence;
    private int attempts;
    private bool paused;
    internal bool Paused
    {
        get => paused;
        set
        {
            if (paused == value) return;
            retry.Stop();
            observedSequence = NativeMethods.GetClipboardSequenceNumber();
            paused = value;
        }
    }
    internal event Action? Changed;
    internal event Action<string>? Failed;
    internal event Action<int>? Shortcut;
    internal List<string> RegistrationWarnings { get; } = [];

    internal ClipboardService(HistoryStore store)
    {
        this.store = store;
        CreateHandle(new CreateParams { Caption = "Xclip events", Parent = new nint(-3) });
        // Start with the current sequence so launching does not import pre-existing private content.
        observedSequence = NativeMethods.GetClipboardSequenceNumber();
        if (!NativeMethods.AddClipboardFormatListener(Handle))
            throw new InvalidOperationException("无法监听剪贴板，请重新打开 Xclip。");
        if (!NativeMethods.RegisterHotKey(Handle, 1, NativeMethods.ControlAltNoRepeat, (uint)Keys.V))
            RegistrationWarnings.Add("Ctrl+Alt+V 已被占用，请使用托盘打开历史。");
        if (!NativeMethods.RegisterHotKey(Handle, 2, NativeMethods.ControlAltNoRepeat, (uint)Keys.A))
            RegistrationWarnings.Add("Ctrl+Alt+A 已被占用，请使用托盘截图。");
        retry.Tick += (_, _) => ReadPending();
    }

    protected override void WndProc(ref Message message)
    {
        if (message.Msg == NativeMethods.ClipboardUpdate)
        {
            attempts = 0;
            retry.Start(); // Read after the owner has finished, away from the notification stack.
        }
        else if (message.Msg == NativeMethods.HotKey) Shortcut?.Invoke(message.WParam.ToInt32());
        base.WndProc(ref message);
    }

    private void ReadPending()
    {
        retry.Stop();
        var sequence = NativeMethods.GetClipboardSequenceNumber();
        if (sequence == observedSequence) return;
        if (Paused || sequence == ownSequence) { observedSequence = sequence; return; }
        try
        {
            // Respect password-manager and Windows history exclusion hints.
            if (NativeMethods.ExcludedFromHistory(Handle))
            {
                observedSequence = sequence;
                return;
            }
            var source = NativeMethods.ProcessName(NativeMethods.GetClipboardOwner());
            Action? commit = null;
            if (Clipboard.ContainsFileDropList())
            {
                var files = Clipboard.GetFileDropList().Cast<string>().ToArray();
                if (files.Length != 0) commit = () => store.AddFiles(files, source);
            }
            else if (Clipboard.ContainsImage())
            {
                using var bitmap = Clipboard.GetImage();
                if (bitmap != null)
                {
                    if ((long)bitmap.Width * bitmap.Height > 40_000_000)
                        throw new InvalidOperationException("图片超过 4000 万像素，本次未记录。");
                    using var stream = new MemoryStream();
                    bitmap.Save(stream, ImageFormat.Png);
                    var png = stream.ToArray();
                    commit = () => store.AddImage(png, source);
                }
            }
            else if (Clipboard.ContainsText(TextDataFormat.UnicodeText))
            {
                var value = Clipboard.GetText(TextDataFormat.UnicodeText);
                if (value.Length != 0) commit = () => store.AddText(value, source);
            }
            // The owner may have changed while formats were queried; never combine two copies.
            if (NativeMethods.GetClipboardSequenceNumber() != sequence) { retry.Start(); return; }
            commit?.Invoke();
            observedSequence = sequence;
            if (commit != null) Changed?.Invoke();
        }
        catch (ExternalException)
        {
            if (++attempts < 8) retry.Start();
            else { observedSequence = sequence; Failed?.Invoke("剪贴板正被其他应用占用，本次未能读取。"); }
        }
        catch (Exception ex) when (ex is not OutOfMemoryException)
        {
            observedSequence = sequence;
            Failed?.Invoke(ex.Message);
        }
    }

    internal void Write(ClipboardEntry entry)
    {
        switch (entry.Kind)
        {
            case ClipboardKind.Text:
                Clipboard.SetDataObject(entry.Content, true, 5, 80);
                break;
            case ClipboardKind.Files:
                if (entry.Files.Any(path => !File.Exists(path) && !Directory.Exists(path)))
                    throw new IOException("原文件已移动或删除，无法粘贴。Windows 首版保存的是文件路径。");
                var paths = new StringCollection();
                paths.AddRange(entry.Files);
                var files = new DataObject();
                files.SetFileDropList(paths);
                Clipboard.SetDataObject(files, true, 5, 80);
                break;
            case ClipboardKind.Image:
                using (var stream = new MemoryStream(store.ReadImage(entry)))
                using (var bitmap = new Bitmap(stream))
                {
                    var imageData = new DataObject();
                    imageData.SetImage(bitmap);
                    Clipboard.SetDataObject(imageData, true, 5, 80);
                }
                break;
            default: throw new InvalidOperationException("暂不支持此内容类型。");
        }
        ownSequence = NativeMethods.GetClipboardSequenceNumber();
        observedSequence = ownSequence;
    }

    public void Dispose()
    {
        retry.Dispose();
        NativeMethods.UnregisterHotKey(Handle, 1);
        NativeMethods.UnregisterHotKey(Handle, 2);
        NativeMethods.RemoveClipboardFormatListener(Handle);
        DestroyHandle();
        GC.SuppressFinalize(this);
    }
}
