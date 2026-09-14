using System.ComponentModel;
using System.Diagnostics;
using Xclip.Core;

namespace Xclip.Windows;

/// <summary>History presentation only. Clipboard and desktop integration belong to the app context.</summary>
public sealed class HistoryForm : Form
{
    private readonly HistoryStore _store;
    private readonly TextBox _search = new();
    private readonly CheckBox _favoritesOnly = new();
    private readonly CheckBox _paused = new();
    private readonly DataGridView _entries = new();
    private readonly Label _empty = new();
    private readonly Label _previewTitle = new();
    private readonly Label _previewDetails = new();
    private readonly TextBox _textPreview = new();
    private readonly PictureBox _imagePreview = new();
    private readonly Button _copy = new();
    private readonly Button _paste = new();
    private readonly Button _favorite = new();
    private readonly Button _pin = new();
    private readonly Button _delete = new();
    private readonly Button _undo = new();
    private readonly Button _clearSearch = new();
    private readonly ToolStripStatusLabel _count = new();
    private readonly ToolStripStatusLabel _status = new();
    private readonly ContextMenuStrip _contextMenu = new();
    private readonly ToolTip _toolTip = new();
    private readonly System.Windows.Forms.Timer _searchTimer = new() { Interval = 140 };
    private readonly Font _titleFont;
    private IReadOnlyList<ClipboardEntry> _visibleEntries = Array.Empty<ClipboardEntry>();
    private Guid? _contextEntryId;
    private string? _previewAttachmentName;
    private Size _previewOriginalSize;
    private bool _refreshing;
    private bool _changingPause;

    public event Action<ClipboardEntry>? CopyRequested;
    public event Action<ClipboardEntry>? PasteRequested;
    public event Action? CaptureRequested;
    public event Action<bool>? PauseChanged;

    [Browsable(false)]
    [DesignerSerializationVisibility(DesignerSerializationVisibility.Hidden)]
    public bool AllowClose { get; set; }

    public HistoryForm(HistoryStore store)
    {
        _store = store ?? throw new ArgumentNullException(nameof(store));
        Text = "Xclip · 剪贴板历史";
        StartPosition = FormStartPosition.CenterScreen;
        AutoScaleMode = AutoScaleMode.Dpi;
        AutoScaleDimensions = new SizeF(96, 96);
        ClientSize = new Size(1120, 720);
        MinimumSize = new Size(940, 580);
        Font = new Font(SystemFonts.MessageBoxFont?.FontFamily ?? FontFamily.GenericSansSerif, 10f);
        _titleFont = new Font(Font.FontFamily, 20f, FontStyle.Bold);
        BackColor = SystemColors.Window;
        ForeColor = SystemColors.WindowText;
        KeyPreview = true;
        BuildLayout();
        BuildContextMenu();
        _searchTimer.Tick += (_, _) => { _searchTimer.Stop(); RefreshEntries(); };
        _search.TextChanged += (_, _) =>
        {
            _clearSearch.Enabled = _search.TextLength > 0;
            _searchTimer.Stop();
            _searchTimer.Start();
        };
        _favoritesOnly.CheckedChanged += (_, _) => RefreshEntries();
        _paused.CheckedChanged += OnPauseChanged;
        RefreshEntries();
        SetStatus("已准备好。关闭窗口后可从托盘重新打开。");
    }

    private void BuildLayout()
    {
        var layout = new TableLayoutPanel
        {
            Dock = DockStyle.Fill, ColumnCount = 1, RowCount = 6,
            Padding = new Padding(20, 14, 20, 0), BackColor = SystemColors.Window
        };
        layout.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        for (var i = 0; i < 3; i++) layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        layout.RowStyles.Add(new RowStyle(SizeType.AutoSize));

        var header = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 2, Margin = new Padding(0, 0, 0, 16) };
        header.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        header.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var brand = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, WrapContents = false, FlowDirection = FlowDirection.TopDown, Margin = Padding.Empty };
        brand.Controls.Add(new Label { Text = "Xclip", Font = _titleFont, AutoSize = true, Margin = Padding.Empty });
        brand.Controls.Add(new Label { Text = "剪贴板历史 · Windows 预览版", AutoSize = true, ForeColor = SystemColors.GrayText, Margin = new Padding(1, 2, 0, 0) });
        header.Controls.Add(brand, 0, 0);
        var capture = MakeButton(new Button(), "截屏", () => CaptureRequested?.Invoke());
        capture.Anchor = AnchorStyles.Right;
        capture.Margin = Padding.Empty;
        header.Controls.Add(capture, 1, 0);
        layout.Controls.Add(header, 0, 0);

        var searchRow = new TableLayoutPanel { Dock = DockStyle.Fill, AutoSize = true, ColumnCount = 4, Margin = new Padding(0, 0, 0, 10) };
        searchRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        searchRow.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        searchRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        searchRow.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        searchRow.Controls.Add(new Label { Text = "搜索", AutoSize = true, Anchor = AnchorStyles.Left, Margin = new Padding(0, 0, 10, 0) }, 0, 0);
        _search.Dock = DockStyle.Fill;
        _search.Anchor = AnchorStyles.Left | AnchorStyles.Right;
        _search.PlaceholderText = "搜索内容或来源应用  ·  Ctrl+F";
        _search.AccessibleName = "搜索剪贴板历史";
        _search.Margin = new Padding(0, 6, 10, 6);
        searchRow.Controls.Add(_search, 1, 0);
        MakeButton(_clearSearch, "清除搜索", () => { _search.Clear(); _search.Focus(); });
        _clearSearch.Enabled = false;
        searchRow.Controls.Add(_clearSearch, 2, 0);
        _favoritesOnly.Text = "仅收藏";
        _favoritesOnly.AutoSize = true;
        _favoritesOnly.Anchor = AnchorStyles.Left;
        _favoritesOnly.Margin = new Padding(10, 0, 0, 0);
        searchRow.Controls.Add(_favoritesOnly, 3, 0);
        layout.Controls.Add(searchRow, 0, 1);

        var actions = new FlowLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, WrapContents = true, Margin = new Padding(0, 0, 0, 10) };
        actions.Controls.Add(MakeButton(_paste, "粘贴  Enter", () => WithSelected(entry => PasteRequested?.Invoke(entry))));
        actions.Controls.Add(MakeButton(_copy, "复制", () => WithSelected(entry => CopyRequested?.Invoke(entry))));
        actions.Controls.Add(MakeButton(_favorite, "收藏", () => WithSelected(ToggleFavorite)));
        actions.Controls.Add(MakeButton(_pin, "置顶", () => WithSelected(TogglePin)));
        actions.Controls.Add(MakeButton(_delete, "删除", () => WithSelected(DeleteEntry)));
        actions.Controls.Add(MakeButton(_undo, "撤销删除", UndoDelete));
        _paused.Text = "暂停记录";
        _paused.AutoSize = true;
        _paused.Margin = new Padding(12, 10, 0, 8);
        actions.Controls.Add(_paused);
        layout.Controls.Add(actions, 0, 2);

        var split = new SplitContainer
        {
            Dock = DockStyle.Fill, Size = new Size(1080, 420), SplitterWidth = 12,
            Panel1MinSize = 480, Panel2MinSize = 300, SplitterDistance = 600,
            Margin = Padding.Empty, BackColor = SystemColors.Window
        };
        BuildEntryList();
        split.Panel1.Controls.Add(_entries);
        _empty.Dock = DockStyle.Fill;
        _empty.TextAlign = ContentAlignment.MiddleCenter;
        _empty.Padding = new Padding(24);
        _empty.ForeColor = SystemColors.GrayText;
        _empty.BackColor = SystemColors.Window;
        split.Panel1.Controls.Add(_empty);

        var preview = new TableLayoutPanel { Dock = DockStyle.Fill, RowCount = 3, ColumnCount = 1, Padding = new Padding(12, 8, 8, 8), BackColor = SystemColors.ControlLightLight };
        preview.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        preview.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        preview.RowStyles.Add(new RowStyle(SizeType.AutoSize));
        preview.RowStyles.Add(new RowStyle(SizeType.Percent, 100));
        _previewTitle.AutoSize = true;
        _previewTitle.Margin = new Padding(0, 0, 0, 8);
        _previewTitle.Text = "内容预览";
        _previewDetails.Dock = DockStyle.Fill;
        _previewDetails.AutoSize = true;
        _previewDetails.ForeColor = SystemColors.GrayText;
        _previewDetails.Margin = new Padding(0, 0, 0, 12);
        preview.Controls.Add(_previewTitle, 0, 0);
        preview.Controls.Add(_previewDetails, 0, 1);
        var previewSurface = new Panel { Dock = DockStyle.Fill, Margin = Padding.Empty };
        _textPreview.Dock = DockStyle.Fill;
        _textPreview.Multiline = true;
        _textPreview.ReadOnly = true;
        _textPreview.WordWrap = true;
        _textPreview.ScrollBars = ScrollBars.Vertical;
        _textPreview.BorderStyle = BorderStyle.None;
        _textPreview.BackColor = SystemColors.ControlLightLight;
        _textPreview.ForeColor = SystemColors.WindowText;
        _textPreview.AccessibleName = "所选历史内容预览";
        _imagePreview.Dock = DockStyle.Fill;
        _imagePreview.SizeMode = PictureBoxSizeMode.Zoom;
        _imagePreview.BackColor = SystemColors.ControlLightLight;
        _imagePreview.AccessibleName = "所选图片预览";
        _imagePreview.Visible = false;
        previewSurface.Controls.Add(_textPreview);
        previewSurface.Controls.Add(_imagePreview);
        preview.Controls.Add(previewSurface, 0, 2);
        split.Panel2.Controls.Add(preview);
        layout.Controls.Add(split, 0, 3);

        var footer = new TableLayoutPanel { AutoSize = true, Dock = DockStyle.Fill, ColumnCount = 2, RowCount = 2, Margin = new Padding(0, 12, 0, 8) };
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.Percent, 100));
        footer.ColumnStyles.Add(new ColumnStyle(SizeType.AutoSize));
        var hint = new Label { Text = "↑ ↓ 选择  ·  Enter 粘贴  ·  Ctrl+C 复制  ·  Delete 删除  ·  Ctrl+Z 撤销  ·  Esc 隐藏", AutoSize = true, ForeColor = SystemColors.GrayText, Margin = new Padding(0, 0, 0, 10) };
        footer.Controls.Add(hint, 0, 0);
        footer.SetColumnSpan(hint, 2);
        var dataLocation = new LinkLabel { Text = "数据位置：" + _store.DirectoryPath, AutoEllipsis = true, Dock = DockStyle.Fill, TextAlign = ContentAlignment.MiddleLeft, LinkBehavior = LinkBehavior.HoverUnderline, Margin = Padding.Empty };
        dataLocation.AccessibleName = "打开 Xclip 数据目录";
        dataLocation.LinkClicked += (_, _) => Safely(() => Process.Start(new ProcessStartInfo(_store.DirectoryPath) { UseShellExecute = true }));
        _toolTip.SetToolTip(dataLocation, _store.DirectoryPath);
        footer.Controls.Add(dataLocation, 0, 1);
        var clear = MakeButton(new Button(), "清理普通历史…", ClearUnprotected);
        clear.Margin = Padding.Empty;
        footer.Controls.Add(clear, 1, 1);
        layout.Controls.Add(footer, 0, 4);

        var statusBar = new StatusStrip { Dock = DockStyle.Fill, SizingGrip = true, BackColor = SystemColors.Control, Margin = Padding.Empty };
        _count.BorderSides = ToolStripStatusLabelBorderSides.Right;
        _count.Padding = new Padding(0, 0, 12, 0);
        _status.Spring = true;
        _status.TextAlign = ContentAlignment.MiddleLeft;
        _status.AutoToolTip = true;
        statusBar.Items.Add(_count);
        statusBar.Items.Add(_status);
        layout.Controls.Add(statusBar, 0, 5);
        Controls.Add(layout);
    }

    private void BuildEntryList()
    {
        _entries.Dock = DockStyle.Fill;
        _entries.VirtualMode = true;
        _entries.ReadOnly = true;
        _entries.MultiSelect = false;
        _entries.SelectionMode = DataGridViewSelectionMode.FullRowSelect;
        _entries.AllowUserToAddRows = false;
        _entries.AllowUserToDeleteRows = false;
        _entries.AllowUserToResizeRows = false;
        _entries.RowHeadersVisible = false;
        _entries.AutoGenerateColumns = false;
        _entries.BorderStyle = BorderStyle.FixedSingle;
        _entries.BackgroundColor = SystemColors.Window;
        _entries.GridColor = SystemColors.ControlLight;
        _entries.CellBorderStyle = DataGridViewCellBorderStyle.SingleHorizontal;
        _entries.RowTemplate.Height = 43;
        _entries.ColumnHeadersHeight = 36;
        _entries.ColumnHeadersHeightSizeMode = DataGridViewColumnHeadersHeightSizeMode.DisableResizing;
        _entries.DefaultCellStyle.Padding = new Padding(6, 4, 6, 4);
        _entries.DefaultCellStyle.SelectionBackColor = SystemColors.Highlight;
        _entries.DefaultCellStyle.SelectionForeColor = SystemColors.HighlightText;
        _entries.AccessibleName = "剪贴板历史列表";
        _entries.Columns.Add(Column("kind", "类型", 62));
        _entries.Columns.Add(new DataGridViewTextBoxColumn { Name = "content", HeaderText = "内容", AutoSizeMode = DataGridViewAutoSizeColumnMode.Fill, MinimumWidth = 120, SortMode = DataGridViewColumnSortMode.NotSortable });
        _entries.Columns.Add(Column("source", "来源", 88));
        _entries.Columns.Add(Column("time", "复制时间", 114));
        _entries.Columns.Add(Column("flags", "状态", 84));
        _entries.CellValueNeeded += (_, args) =>
        {
            if (args.RowIndex < 0 || args.RowIndex >= _visibleEntries.Count) return;
            var entry = _visibleEntries[args.RowIndex];
            args.Value = args.ColumnIndex switch
            {
                0 => KindLabel(entry.Kind),
                1 => Summary(entry),
                2 => string.IsNullOrWhiteSpace(entry.SourceApp) ? "—" : entry.SourceApp,
                3 => FormatTime(entry.CreatedAt),
                4 => string.Join(" · ", new[] { entry.IsPinned ? "置顶" : null, entry.IsFavorite ? "收藏" : null }.Where(value => value is not null)),
                _ => ""
            };
        };
        _entries.CellToolTipTextNeeded += (_, args) =>
        {
            if (args.RowIndex >= 0 && args.RowIndex < _visibleEntries.Count)
            {
                var entry = _visibleEntries[args.RowIndex];
                args.ToolTipText = args.ColumnIndex == 2 ? entry.SourceApp ?? "来源未知" : Limit(entry.Content, 4000);
            }
        };
        _entries.SelectionChanged += (_, _) => { if (!_refreshing) Safely(UpdatePreview); };
        _entries.CellDoubleClick += (_, args) =>
        {
            if (args.RowIndex >= 0) Safely(() => WithSelected(entry => PasteRequested?.Invoke(entry)));
        };
        _entries.MouseDown += (_, args) =>
        {
            if (args.Button != MouseButtons.Right) return;
            var row = _entries.HitTest(args.X, args.Y).RowIndex;
            if (row >= 0 && row < _visibleEntries.Count)
            {
                _entries.CurrentCell = _entries[0, row];
                _entries.Rows[row].Selected = true;
            }
            else _entries.ClearSelection();
        };
        _entries.DataError += (_, args) => { args.ThrowException = false; ReportError(args.Exception?.Message ?? "无法显示这条历史。"); };
        _entries.ContextMenuStrip = _contextMenu;
    }

    private static DataGridViewTextBoxColumn Column(string name, string title, int width) => new()
    {
        Name = name, HeaderText = title, Width = width,
        SortMode = DataGridViewColumnSortMode.NotSortable,
        AutoSizeMode = DataGridViewAutoSizeColumnMode.None
    };

    private Button MakeButton(Button button, string text, Action action)
    {
        button.Text = text;
        button.AutoSize = true;
        button.AutoSizeMode = AutoSizeMode.GrowAndShrink;
        button.MinimumSize = new Size(70, 36);
        button.Padding = new Padding(8, 3, 8, 3);
        button.Margin = new Padding(0, 0, 8, 4);
        button.UseVisualStyleBackColor = true;
        button.Click += (_, _) => Safely(action);
        return button;
    }

    private void BuildContextMenu()
    {
        AddContextAction("粘贴", entry => PasteRequested?.Invoke(entry));
        AddContextAction("复制", entry => CopyRequested?.Invoke(entry));
        _contextMenu.Items.Add(new ToolStripSeparator());
        var favorite = AddContextAction("收藏", ToggleFavorite);
        var pin = AddContextAction("置顶", TogglePin);
        _contextMenu.Items.Add(new ToolStripSeparator());
        AddContextAction("删除", DeleteEntry);
        _contextMenu.Opening += (_, args) =>
        {
            var entry = SelectedEntry();
            _contextEntryId = entry?.Id;
            args.Cancel = entry is null;
            if (entry is null) return;
            favorite.Text = entry.IsFavorite ? "取消收藏" : "收藏";
            pin.Text = entry.IsPinned ? "取消置顶" : "置顶";
        };
    }

    private ToolStripMenuItem AddContextAction(string text, Action<ClipboardEntry> action)
    {
        var item = new ToolStripMenuItem(text);
        item.Click += (_, _) => Safely(() =>
        {
            if (_contextEntryId is not Guid id) return;
            var entry = _store.Entries.FirstOrDefault(candidate => candidate.Id == id);
            if (entry is null) { SetStatus("这条历史已不在列表中。"); RefreshEntries(); return; }
            action(entry);
        });
        _contextMenu.Items.Add(item);
        return item;
    }

    public void RefreshEntries()
    {
        if (IsDisposed) return;
        if (InvokeRequired) { BeginInvoke(new Action(RefreshEntries)); return; }
        Safely(() =>
        {
            var selectedId = SelectedEntry()?.Id;
            var oldIndex = _entries.CurrentCell?.RowIndex ?? 0;
            var matching = _store.Search(_search.Text, _favoritesOnly.Checked).ToArray();
            _refreshing = true;
            try
            {
                _visibleEntries = matching;
                _entries.RowCount = matching.Length;
                _entries.ClearSelection();
                if (matching.Length > 0)
                {
                    var retained = Array.FindIndex(matching, entry => entry.Id == selectedId);
                    var index = retained >= 0 ? retained : Math.Clamp(oldIndex, 0, matching.Length - 1);
                    _entries.CurrentCell = _entries[0, index];
                    _entries.Rows[index].Selected = true;
                }
                _entries.Invalidate();
                _empty.Text = _store.Entries.Count == 0
                    ? "还没有剪贴板历史\n\n复制一段文字、图片或文件后，它会出现在这里。"
                    : "没有匹配的历史\n\n试试其他关键词，或取消“仅收藏”。";
                _empty.Visible = matching.Length == 0;
                _entries.Visible = matching.Length > 0;
                _count.Text = $"共 {_store.Entries.Count} 条 · 显示 {matching.Length} 条";
            }
            finally { _refreshing = false; }
            UpdatePreview();
        });
    }

    public void PrepareToShow()
    {
        _searchTimer.Stop();
        RefreshEntries();
        if (_visibleEntries.Count > 0)
        {
            _entries.CurrentCell = _entries[0, 0];
            _entries.Rows[0].Selected = true;
        }
        ActiveControl = _search;
        _search.SelectAll();
        _search.Focus();
    }

    public void SetStatus(string message)
    {
        if (IsDisposed) return;
        if (InvokeRequired) { BeginInvoke(new Action(() => SetStatus(message))); return; }
        _status.Text = message;
        _status.ToolTipText = message;
        _status.ForeColor = SystemColors.ControlText;
    }

    private ClipboardEntry? SelectedEntry()
    {
        if (_entries.SelectedRows.Count == 0) return null;
        var index = _entries.SelectedRows[0].Index;
        return index >= 0 && index < _visibleEntries.Count ? _visibleEntries[index] : null;
    }

    private void WithSelected(Action<ClipboardEntry> action)
    {
        var selected = SelectedEntry();
        if (selected is null) { SetStatus("请先选择一条历史。"); return; }
        var current = _store.Entries.FirstOrDefault(entry => entry.Id == selected.Id);
        if (current is null) { SetStatus("这条历史已不在列表中。"); RefreshEntries(); return; }
        action(current);
    }

    private void UpdatePreview()
    {
        var entry = SelectedEntry();
        _copy.Enabled = _paste.Enabled = _favorite.Enabled = _pin.Enabled = _delete.Enabled = entry is not null;
        _undo.Enabled = _store.CanUndo;
        _favorite.Text = entry?.IsFavorite == true ? "取消收藏" : "收藏";
        _pin.Text = entry?.IsPinned == true ? "取消置顶" : "置顶";
        if (entry is null)
        {
            ClearImagePreview();
            _textPreview.Visible = true;
            _previewTitle.Text = "内容预览";
            _previewDetails.Text = "选择一条历史，查看完整内容。";
            _textPreview.Clear();
            return;
        }
        _previewTitle.Text = KindLabel(entry.Kind) + "预览";
        _previewDetails.Text = entry.CreatedAt.ToLocalTime().ToString("yyyy-MM-dd HH:mm")
            + "  ·  " + (string.IsNullOrWhiteSpace(entry.SourceApp) ? "来源未知" : entry.SourceApp);
        _textPreview.Text = entry.Kind == ClipboardKind.Files
            ? string.Join(Environment.NewLine, entry.Files)
            : entry.Content;
        _textPreview.SelectionStart = 0;
        _textPreview.SelectionLength = 0;
        if (entry.Kind != ClipboardKind.Image)
        {
            ClearImagePreview();
            _textPreview.Visible = true;
            return;
        }
        // Attachments are content-addressed. A history refresh must not reread and
        // decode the same selected PNG when a new, unrelated copy arrives.
        if (_imagePreview.Image is not null && entry.AttachmentName is not null
            && _previewAttachmentName == entry.AttachmentName)
        {
            ShowImagePreview();
            return;
        }
        ClearImagePreview();
        _textPreview.Visible = true;
        try
        {
            using var stream = new MemoryStream(_store.ReadImage(entry));
            using var decoded = Image.FromStream(stream, useEmbeddedColorManagement: false, validateImageData: true);
            if ((long)decoded.Width * decoded.Height > 60_000_000) throw new InvalidDataException("图片超过预览尺寸限制。");
            var scale = Math.Min(1d, 1600d / Math.Max(decoded.Width, decoded.Height));
            _imagePreview.Image = new Bitmap(decoded, new Size(Math.Max(1, (int)(decoded.Width * scale)), Math.Max(1, (int)(decoded.Height * scale))));
            _previewAttachmentName = entry.AttachmentName;
            _previewOriginalSize = decoded.Size;
            ShowImagePreview();
        }
        catch (Exception error)
        {
            _textPreview.Text = "暂时无法预览这张图片。\r\n\r\n" + error.Message;
            ReportError("图片预览失败：" + error.Message);
        }
    }

    private void ShowImagePreview()
    {
        var dimensions = $"{_previewOriginalSize.Width} × {_previewOriginalSize.Height} 像素";
        _imagePreview.AccessibleDescription = "图片，" + dimensions;
        _previewDetails.Text += "\n" + dimensions;
        _textPreview.Visible = false;
        _imagePreview.Visible = true;
    }

    private void ClearImagePreview()
    {
        var previous = _imagePreview.Image;
        _imagePreview.Image = null;
        _imagePreview.Visible = false;
        _previewAttachmentName = null;
        _previewOriginalSize = Size.Empty;
        previous?.Dispose();
    }

    private void ToggleFavorite(ClipboardEntry entry)
    {
        _store.UpdateFlags(entry.Id, favorite: !entry.IsFavorite);
        RefreshEntries();
        SetStatus(entry.IsFavorite ? "已取消收藏。" : "已收藏，常规清理会保留这条历史。");
    }

    private void TogglePin(ClipboardEntry entry)
    {
        _store.UpdateFlags(entry.Id, pinned: !entry.IsPinned);
        RefreshEntries();
        SetStatus(entry.IsPinned ? "已取消置顶。" : "已置顶。");
    }

    private void DeleteEntry(ClipboardEntry entry)
    {
        _store.Delete(entry.Id);
        RefreshEntries();
        SetStatus("已删除。按 Ctrl+Z 或点击“撤销删除”可恢复。");
    }

    private void UndoDelete()
    {
        var restored = _store.UndoDelete();
        RefreshEntries();
        SetStatus(restored ? "已恢复删除的历史。" : "没有可撤销的删除。");
    }

    private void ClearUnprotected()
    {
        var count = _store.Entries.Count(entry => !entry.IsFavorite && !entry.IsPinned);
        if (count == 0) { SetStatus("没有可清理的普通历史；收藏和置顶项目会保留。"); return; }
        if (MessageBox.Show(this, $"清理 {count} 条普通历史？\n\n收藏和置顶项目会保留。", "清理历史",
                MessageBoxButtons.YesNo, MessageBoxIcon.Question, MessageBoxDefaultButton.Button2) != DialogResult.Yes) return;
        _store.ClearUnprotected();
        RefreshEntries();
        SetStatus("已清理普通历史，收藏和置顶项目已保留。");
    }

    private void OnPauseChanged(object? sender, EventArgs args)
    {
        if (_changingPause) return;
        try
        {
            PauseChanged?.Invoke(_paused.Checked);
            SetStatus(_paused.Checked ? "已暂停记录。已有历史仍可使用。" : "已恢复剪贴板记录。");
        }
        catch (Exception error)
        {
            _changingPause = true;
            _paused.Checked = !_paused.Checked;
            _changingPause = false;
            ReportError(error.Message);
        }
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (keyData == Keys.Escape) { Hide(); return true; }
        if (keyData == (Keys.Control | Keys.F)) { _search.Focus(); _search.SelectAll(); return true; }
        if (_search.ContainsFocus && keyData is Keys.Down or Keys.Up)
        {
            if (_entries.RowCount > 0) _entries.Focus();
            return true;
        }
        if (keyData == Keys.Enter && (_entries.ContainsFocus || _search.ContainsFocus || _textPreview.ContainsFocus))
        {
            _searchTimer.Stop();
            RefreshEntries();
            Safely(() => WithSelected(entry => PasteRequested?.Invoke(entry)));
            return true;
        }
        if (keyData == (Keys.Control | Keys.C) && _entries.ContainsFocus)
        {
            Safely(() => WithSelected(entry => CopyRequested?.Invoke(entry)));
            return true;
        }
        if (keyData == Keys.Delete && _entries.ContainsFocus)
        {
            Safely(() => WithSelected(DeleteEntry));
            return true;
        }
        if (keyData == (Keys.Control | Keys.Z) && !_search.ContainsFocus)
        {
            Safely(UndoDelete);
            return true;
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    protected override void OnFormClosing(FormClosingEventArgs e)
    {
        if (!AllowClose && e.CloseReason == CloseReason.UserClosing)
        {
            e.Cancel = true;
            Hide();
        }
        base.OnFormClosing(e);
    }

    private void Safely(Action action)
    {
        try { action(); }
        catch (Exception error) { ReportError(error.Message); }
    }

    private void ReportError(string message)
    {
        SetStatus("操作未完成：" + message);
        _status.ForeColor = SystemInformation.HighContrast ? SystemColors.ControlText : Color.FromArgb(160, 32, 32);
    }

    private static string KindLabel(ClipboardKind kind) => kind switch
    {
        ClipboardKind.Text => "文本", ClipboardKind.Image => "图片", ClipboardKind.Files => "文件", _ => "内容"
    };

    private static string FormatTime(DateTimeOffset timestamp)
    {
        var local = timestamp.ToLocalTime();
        return local.Date == DateTime.Now.Date ? "今天 " + local.ToString("HH:mm") : local.ToString("MM-dd HH:mm");
    }

    private static string Summary(ClipboardEntry entry)
    {
        if (entry.Kind == ClipboardKind.Image) return string.IsNullOrWhiteSpace(entry.Content) ? "图片" : Limit(entry.Content, 160);
        var excerpt = entry.Content.Length > 2048 ? entry.Content[..2048] : entry.Content;
        var text = string.Join(" ", excerpt.Split((char[]?)null, StringSplitOptions.RemoveEmptyEntries));
        if (string.IsNullOrWhiteSpace(text) && entry.Kind == ClipboardKind.Files) text = string.Join("、", entry.Files.Select(Path.GetFileName));
        return Limit(text, 160);
    }

    private static string Limit(string text, int length) => text.Length > length ? text[..length] + "…" : text;

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _searchTimer.Dispose();
            _contextMenu.Dispose();
            _toolTip.Dispose();
            ClearImagePreview();
            _titleFont.Dispose();
        }
        base.Dispose(disposing);
    }
}
