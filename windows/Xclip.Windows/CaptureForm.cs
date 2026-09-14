using System.Drawing.Drawing2D;
using System.Drawing.Imaging;

namespace Xclip.Windows;

/// <summary>A frozen-desktop editor. All drawing coordinates are bitmap pixels.</summary>
public sealed class CaptureForm : Form
{
    private const int HandleRadius = 5;
    private const int HandleHitRadius = 10;
    private const long MaximumCapturePixels = 64_000_000;
    private const int MaximumCaptureDimension = 16_384;
    private static readonly Color Accent = Color.FromArgb(0, 116, 153);
    private static readonly Color Ink = Color.FromArgb(230, 48, 65);
    private readonly Bitmap _snapshot;
    private readonly Rectangle _desktopBounds;
    private readonly bool _renderOnly;
    private readonly Font _interfaceFont = new("Microsoft YaHei UI", 14, FontStyle.Regular, GraphicsUnit.Pixel);
    private readonly Font _annotationFont = new("Microsoft YaHei UI", 24, FontStyle.Regular, GraphicsUnit.Pixel);
    private readonly FlowLayoutPanel _toolbar;
    private readonly Label _hint;
    private readonly Dictionary<EditorTool, Button> _toolButtons = [];
    private readonly Button _undoButton;
    private readonly Button _completeButton;
    private readonly Button _saveButton;
    private readonly List<Annotation> _annotations = [];
    private readonly Stack<EditState> _history = [];
    private Bitmap _composite;
    private Bitmap? _result;
    private Rectangle _selection;
    private Rectangle _selectionBeforeDrag;
    private EditorTool _tool;
    private DragKind _drag;
    private Point _dragStart;
    private Point _dragEnd;
    private int _resizeHandle = -1;
    private Panel? _textPanel;
    private TextBox? _textBox;
    private Point _textOrigin;

    private CaptureForm(Bitmap snapshot, Rectangle desktopBounds, bool renderOnly = false)
    {
        _snapshot = snapshot;
        _desktopBounds = desktopBounds;
        _renderOnly = renderOnly;
        _composite = (Bitmap)snapshot.Clone();
        AutoScaleMode = AutoScaleMode.None;
        FormBorderStyle = FormBorderStyle.None;
        StartPosition = FormStartPosition.Manual;
        if (!renderOnly)
        {
            Bounds = desktopBounds;
            ClientSize = snapshot.Size;
            TopMost = true;
        }
        ShowInTaskbar = false;
        KeyPreview = true;
        DoubleBuffered = true;
        Font = _interfaceFont;
        Text = "Xclip 截图";
        AccessibleName = "Xclip 截图与标注";
        Cursor = Cursors.Cross;

        _toolbar = new FlowLayoutPanel
        {
            AutoSize = false,
            WrapContents = true,
            Padding = new Padding(8),
            BackColor = Color.FromArgb(245, 248, 251),
            BorderStyle = BorderStyle.FixedSingle,
            AccessibleName = "截图工具栏"
        };
        _hint = new Label
        {
            AutoSize = false,
            Height = 24,
            ForeColor = Color.FromArgb(30, 45, 60),
            Margin = new Padding(4, 0, 4, 4),
            TextAlign = ContentAlignment.MiddleLeft
        };
        _toolbar.Controls.Add(_hint);
        _toolbar.SetFlowBreak(_hint, true);
        AddToolButton("选区", EditorTool.Selection);
        AddToolButton("箭头", EditorTool.Arrow);
        AddToolButton("文字", EditorTool.Text);
        AddToolButton("马赛克", EditorTool.Mosaic);
        _undoButton = AddButton("撤销", Undo);
        _completeButton = AddButton("复制完成", Complete);
        _saveButton = AddButton("另存 PNG", SavePng);
        AddButton("取消", CancelCapture);
        Controls.Add(_toolbar);
        UpdateToolbar();
    }

    /// <summary>
    /// Call on the STA UI thread. The caller owns the returned bitmap and must dispose it.
    /// Cancellation returns null; capture errors are passed to the caller.
    /// </summary>
    public static Bitmap? CaptureAndAnnotate()
    {
        Rectangle bounds = SystemInformation.VirtualScreen;
        ValidateCaptureBounds(bounds);

        using var snapshot = new Bitmap(bounds.Width, bounds.Height, PixelFormat.Format32bppArgb);
        using (Graphics graphics = Graphics.FromImage(snapshot))
            graphics.CopyFromScreen(bounds.Location, Point.Empty, bounds.Size, CopyPixelOperation.SourceCopy);

        using var editor = new CaptureForm(snapshot, bounds);
        if (editor.ShowDialog() != DialogResult.OK)
            return null;
        Bitmap? result = editor._result;
        editor._result = null;
        return result;
    }

    private static void ValidateCaptureBounds(Rectangle bounds)
    {
        if (bounds.Width <= 0 || bounds.Height <= 0)
            throw new InvalidOperationException("没有可截图的显示器。");
        if (bounds.Width > MaximumCaptureDimension || bounds.Height > MaximumCaptureDimension ||
            (long)bounds.Width * bounds.Height > MaximumCapturePixels)
            throw new InvalidOperationException("桌面尺寸过大：截图最多支持 6400 万像素，单边不超过 16384 像素。请降低显示分辨率或减少显示器后重试。");
    }

    /// <summary>Runs deterministic pixel checks without reading the screen, showing a window, or using the clipboard.</summary>
    internal static void RunRenderingSmokeTest()
    {
        static void Check(bool condition, string message)
        {
            if (!condition)
                throw new InvalidOperationException($"截图合成自检失败：{message}");
        }

        static int ChangedPixels(Bitmap actual, Bitmap expected)
        {
            Check(actual.Size == expected.Size, "比较图像尺寸必须一致");
            int changed = 0;
            for (int y = 0; y < actual.Height; y++)
                for (int x = 0; x < actual.Width; x++)
                    if (actual.GetPixel(x, y).ToArgb() != expected.GetPixel(x, y).ToArgb())
                        changed++;
            return changed;
        }

        static void CheckRejectedBounds(Rectangle bounds)
        {
            bool rejected = false;
            try { ValidateCaptureBounds(bounds); }
            catch (InvalidOperationException) { rejected = true; }
            Check(rejected, $"应拒绝超限桌面尺寸 {bounds.Width} × {bounds.Height}");
        }

        // Validate the allocation guard without allocating large images; negative desktop origins are valid.
        ValidateCaptureBounds(new Rectangle(-4000, -2000, 8000, 8000));
        ValidateCaptureBounds(new Rectangle(0, 0, MaximumCaptureDimension, 1));
        CheckRejectedBounds(new Rectangle(0, 0, 8001, 8000));
        CheckRejectedBounds(new Rectangle(0, 0, MaximumCaptureDimension + 1, 1));
        CheckRejectedBounds(new Rectangle(0, 0, 1, MaximumCaptureDimension + 1));
        CheckRejectedBounds(Rectangle.Empty);

        using var checkerboard = new Bitmap(96, 96, PixelFormat.Format32bppArgb);
        for (int y = 0; y < checkerboard.Height; y++)
            for (int x = 0; x < checkerboard.Width; x++)
                checkerboard.SetPixel(x, y, (x + y) % 2 == 0 ? Color.Black : Color.White);
        using var editor = new CaptureForm(checkerboard, new Rectangle(-96, -96, 96, 96), renderOnly: true);

        // Cropping must use source pixels with an exclusive right/bottom edge and clamp to the bitmap.
        editor._selection = new Rectangle(-4, -3, 36, 31);
        using (Bitmap crop = editor.RenderSelection())
        {
            Check(crop.Size == new Size(32, 28), "左上越界选区应裁切到位图范围");
            Check(crop.GetPixel(0, 0) == checkerboard.GetPixel(0, 0), "左上裁切像素位置");
            crop.SetPixel(0, 0, Color.Magenta);
            Check(editor._composite.GetPixel(0, 0) == checkerboard.GetPixel(0, 0), "返回位图必须独立于编辑底图");
        }
        editor._selection = new Rectangle(81, 82, 30, 40);
        using (Bitmap crop = editor.RenderSelection())
        {
            Check(crop.Size == new Size(15, 14), "右下越界选区应保留真实像素尺寸");
            Check(crop.GetPixel(0, 0) == checkerboard.GetPixel(81, 82), "右下裁切起点位置");
            Check(crop.GetPixel(14, 13) == checkerboard.GetPixel(95, 95), "右下最后一个像素应保留");
        }
        Check(ClampPoint(new Point(-12, 120), new Rectangle(10, 20, 40, 50), false) == new Point(10, 69),
            "标注坐标限制在末端像素以内");
        Check(ClampPoint(new Point(120, 120), new Rectangle(10, 20, 40, 50), true) == new Point(50, 70),
            "选区边界允许指向像素外边缘");

        var rectangle = new Rectangle(20, 20, 30, 30);
        Point[] flippedPoints = [new(60, 65), new(35, 65), new(10, 65), new(10, 35),
            new(10, 5), new(35, 5), new(60, 5), new(60, 35)];
        Rectangle[] flippedResults = [new(50, 50, 10, 15), new(20, 50, 30, 15), new(10, 50, 10, 15),
            new(10, 20, 10, 30), new(10, 5, 10, 15), new(20, 5, 30, 15), new(50, 5, 10, 15), new(50, 20, 10, 30)];
        for (int handle = 0; handle < 8; handle++)
            Check(ResizeSelection(rectangle, flippedPoints[handle], handle) == flippedResults[handle],
                $"第 {handle + 1} 个控制点跨越对边后应正确翻转");
        Check(editor.MoveSelection(new Rectangle(70, 70, 16, 16), 100, 100) == new Rectangle(80, 80, 16, 16),
            "移动选区不能超出右下边界");
        Check(editor.MoveSelection(new Rectangle(70, 70, 16, 16), -100, -100) == new Rectangle(0, 0, 16, 16),
            "移动选区不能超出左上边界");

        editor._selection = editor.ImageBounds;
        Check(editor.HandlePoints().Distinct().Count() == 8, "选区应有八个不同的控制点");
        Rectangle mosaicArea = PixelAreaFromPoints(new Point(8, 8), new Point(55, 55));
        Check(mosaicArea == new Rectangle(8, 8, 48, 48), "马赛克必须包含鼠标端点像素");
        editor.AddAnnotation(new MosaicAnnotation(editor._selection, mosaicArea));
        using (Bitmap mosaic = editor.RenderSelection())
        {
            for (int y = 0; y < mosaic.Height; y++)
                for (int x = 0; x < mosaic.Width; x++)
                {
                    Color pixel = mosaic.GetPixel(x, y);
                    if (!mosaicArea.Contains(x, y))
                    {
                        Check(pixel == checkerboard.GetPixel(x, y), "马赛克不应改变区域外像素");
                        continue;
                    }
                    int blockX = mosaicArea.Left + ((x - mosaicArea.Left) / 16) * 16;
                    int blockY = mosaicArea.Top + ((y - mosaicArea.Top) / 16) * 16;
                    Check(pixel == mosaic.GetPixel(blockX, blockY), "马赛克块内应为均匀像素，包括末行和末列");
                    Check(pixel.R is > 0 and < 255, "马赛克必须合成到图片中，不能保留原棋盘像素");
                }
        }
        editor.Undo();
        Check(ChangedPixels(editor._composite, checkerboard) == 0, "撤销马赛克应逐像素恢复原图");

        editor.AddAnnotation(new ArrowAnnotation(editor._selection, new Point(12, 32), new Point(82, 32)));
        Check(editor._composite.GetPixel(40, 32) != checkerboard.GetPixel(40, 32), "箭头线条应写入输出像素");
        Check(ChangedPixels(editor._composite, checkerboard) > 60, "箭头应实际绘制线条与箭头端点");
        using Bitmap arrow = editor.RenderSelection();
        editor.AddAnnotation(new TextAnnotation(editor._selection, new Point(10, 48), "测试 Xclip"));
        Check(ChangedPixels(editor._composite, arrow) > 30, "文字应实际写入输出像素");
        editor.Undo();
        Check(ChangedPixels(editor._composite, arrow) == 0, "撤销文字应保留之前的箭头");
        editor.Undo();
        Check(ChangedPixels(editor._composite, checkerboard) == 0, "继续撤销应恢复原图");
        editor.PushHistory();
        editor._selection = new Rectangle(10, 10, 20, 20);
        editor.Undo();
        Check(editor._selection == editor.ImageBounds, "撤销应恢复之前的选区");
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        // Keep the frozen bitmap and borderless client area at a 1:1 pixel scale.
        Bounds = _desktopBounds;
        ClientSize = _snapshot.Size;
        UpdateToolbar();
        Activate();
        Focus();
    }

    private Button AddButton(string label, Action action)
    {
        var button = new Button
        {
            Text = label,
            AutoSize = true,
            MinimumSize = new Size(64, 36),
            Padding = new Padding(7, 2, 7, 2),
            Margin = new Padding(3),
            UseVisualStyleBackColor = true,
            AccessibleName = label
        };
        button.Click += (_, _) => action();
        _toolbar.Controls.Add(button);
        return button;
    }

    private void AddToolButton(string label, EditorTool tool)
    {
        Button button = AddButton(label, () =>
        {
            CommitText();
            _tool = tool;
            UpdateToolbar();
            Focus();
            Invalidate();
        });
        button.Tag = label;
        _toolButtons.Add(tool, button);
    }

    private void UpdateToolbar()
    {
        if (_renderOnly)
            return;
        bool hasSelection = HasSelection;
        foreach ((EditorTool tool, Button button) in _toolButtons)
        {
            bool selected = tool == _tool;
            button.Enabled = hasSelection || tool == EditorTool.Selection;
            button.Text = $"{(selected ? "● " : "")}{button.Tag}";
            button.BackColor = selected ? Color.FromArgb(211, 237, 246) : SystemColors.Control;
            button.ForeColor = selected ? Color.FromArgb(0, 70, 98) : SystemColors.ControlText;
            button.UseVisualStyleBackColor = !selected;
            button.AccessibleDescription = selected ? "当前工具" : "切换工具";
        }
        _undoButton.Enabled = _history.Count > 0;
        _completeButton.Enabled = hasSelection;
        _saveButton.Enabled = hasSelection;
        string toolHint = _tool switch
        {
            EditorTool.Arrow => "在选区内拖动绘制箭头",
            EditorTool.Text => "点击选区添加文字；输入时 Enter 确认，Shift+Enter 换行",
            EditorTool.Mosaic => "在选区内拖动覆盖隐私区域",
            _ => "拖动边角调整；方向键移动，Shift 加速"
        };
        _hint.Text = hasSelection
            ? $"{_selection.Width} × {_selection.Height} 像素  ·  {toolHint}"
            : "拖动框选区域  ·  Esc 取消  ·  选定后 Enter 复制，Ctrl+Z 撤销";

        Point anchor = hasSelection
            ? new Point(_selection.Right, _selection.Bottom)
            : PointToClient(Control.MousePosition);
        Rectangle monitor = Screen.FromPoint(new Point(
            _desktopBounds.Left + anchor.X, _desktopBounds.Top + anchor.Y)).Bounds;
        monitor.Offset(-_desktopBounds.Left, -_desktopBounds.Top);
        monitor.Intersect(new Rectangle(Point.Empty, _snapshot.Size));
        if (monitor.IsEmpty)
            monitor = new Rectangle(Point.Empty, _snapshot.Size);

        int width = Math.Min(860, Math.Max(160, monitor.Width - 16));
        _hint.Width = Math.Max(120, width - 32);
        _hint.Height = _tool == EditorTool.Text && width < 780 ? 44 : 24;
        _toolbar.Width = width;
        _toolbar.Height = _toolbar.GetPreferredSize(new Size(width, 0)).Height;
        int x = hasSelection ? _selection.Left : anchor.X - width / 2;
        int y = hasSelection ? _selection.Bottom + 14 : monitor.Top + 24;
        if (y + _toolbar.Height > monitor.Bottom - 8 && hasSelection)
            y = _selection.Top - _toolbar.Height - 14;
        _toolbar.Location = new Point(
            Math.Clamp(x, monitor.Left + 8, Math.Max(monitor.Left + 8, monitor.Right - width - 8)),
            Math.Clamp(y, monitor.Top + 8, Math.Max(monitor.Top + 8, monitor.Bottom - _toolbar.Height - 8)));
        _toolbar.Visible = _drag == DragKind.None && _textBox is null;
        _toolbar.BringToFront();
    }

    private bool HasSelection => _selection.Width >= 2 && _selection.Height >= 2;
    private Rectangle ImageBounds => new(Point.Empty, _snapshot.Size);

    protected override void OnPaint(PaintEventArgs e)
    {
        base.OnPaint(e);
        Graphics graphics = e.Graphics;
        graphics.DrawImageUnscaled(_composite, Point.Empty);
        using var shade = new SolidBrush(Color.FromArgb(140, 0, 0, 0));
        using var outside = new Region(ImageBounds);
        if (HasSelection)
            outside.Exclude(_selection);
        graphics.FillRegion(shade, outside);
        if (!HasSelection)
            return;

        if (_drag == DragKind.Annotation)
        {
            GraphicsState state = graphics.Save();
            graphics.SetClip(_selection);
            if (_tool == EditorTool.Arrow)
                DrawArrow(graphics, _dragStart, _dragEnd);
            else if (_tool == EditorTool.Mosaic)
            {
                using var previewPen = new Pen(Ink, 2) { DashStyle = DashStyle.Dash };
                Rectangle preview = Rectangle.Intersect(_selection, PixelAreaFromPoints(_dragStart, _dragEnd));
                graphics.DrawRectangle(previewPen, preview);
            }
            graphics.Restore(state);
        }

        using var border = new Pen(Color.FromArgb(29, 204, 239), 1);
        graphics.DrawRectangle(border, _selection.X, _selection.Y, _selection.Width - 1, _selection.Height - 1);
        if (_tool == EditorTool.Selection)
        {
            foreach (Point point in HandlePoints())
            {
                var handle = new Rectangle(point.X - HandleRadius, point.Y - HandleRadius,
                    HandleRadius * 2, HandleRadius * 2);
                graphics.FillRectangle(Brushes.White, handle);
                graphics.DrawRectangle(border, handle);
            }
        }
    }

    protected override void OnMouseDown(MouseEventArgs e)
    {
        base.OnMouseDown(e);
        if (e.Button != MouseButtons.Left)
            return;
        CommitText();
        Focus();
        _dragStart = ClampPoint(e.Location, ImageBounds, true);
        _dragEnd = _dragStart;
        _selectionBeforeDrag = _selection;
        if (_tool == EditorTool.Selection)
        {
            _resizeHandle = HitHandle(e.Location);
            if (_resizeHandle >= 0)
                _drag = DragKind.Resize;
            else if (HasSelection && _selection.Contains(e.Location))
                _drag = DragKind.Move;
            else
            {
                _drag = DragKind.NewSelection;
                _selection = Rectangle.Empty;
            }
        }
        else if (HasSelection && _selection.Contains(e.Location))
        {
            if (_tool == EditorTool.Text)
            {
                BeginText(e.Location);
                return;
            }
            _dragStart = ClampPoint(e.Location, _selection, false);
            _drag = DragKind.Annotation;
        }
        else
            return;

        Capture = true;
        _toolbar.Visible = false;
        Invalidate();
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        base.OnMouseMove(e);
        if (_drag == DragKind.None)
        {
            Cursor = _tool == EditorTool.Text && _selection.Contains(e.Location)
                ? Cursors.IBeam : CursorForHandle(HitHandle(e.Location));
            return;
        }
        _dragEnd = ClampPoint(e.Location, ImageBounds, true);
        switch (_drag)
        {
            case DragKind.NewSelection:
                _selection = RectangleFromPoints(_dragStart, _dragEnd);
                break;
            case DragKind.Move:
                _selection = MoveSelection(_selectionBeforeDrag, _dragEnd.X - _dragStart.X, _dragEnd.Y - _dragStart.Y);
                break;
            case DragKind.Resize:
                _selection = ResizeSelection(_selectionBeforeDrag, _dragEnd, _resizeHandle);
                break;
            case DragKind.Annotation:
                _dragEnd = ClampPoint(e.Location, _selection, false);
                break;
        }
        Invalidate();
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        base.OnMouseUp(e);
        if (e.Button != MouseButtons.Left || _drag == DragKind.None)
            return;
        OnMouseMove(e);
        if (_drag == DragKind.Annotation)
        {
            if (_tool == EditorTool.Arrow && DistanceSquared(_dragStart, _dragEnd) >= 16)
                AddAnnotation(new ArrowAnnotation(_selection, _dragStart, _dragEnd));
            else if (_tool == EditorTool.Mosaic)
            {
                Rectangle area = Rectangle.Intersect(_selection, PixelAreaFromPoints(_dragStart, _dragEnd));
                if (area.Width > 0 && area.Height > 0)
                    AddAnnotation(new MosaicAnnotation(_selection, area));
            }
        }
        else if (!HasSelection)
            _selection = _selectionBeforeDrag;
        else if (_selection != _selectionBeforeDrag)
            _history.Push(new EditState(_selectionBeforeDrag, _annotations.ToArray()));
        _drag = DragKind.None;
        Capture = false;
        UpdateToolbar();
        Invalidate();
    }

    protected override void OnMouseCaptureChanged(EventArgs e)
    {
        base.OnMouseCaptureChanged(e);
        if (!Capture && _drag != DragKind.None)
        {
            // Losing mouse capture must not leave the toolbar or editor stuck hidden.
            _selection = _selectionBeforeDrag;
            _drag = DragKind.None;
            UpdateToolbar();
            Invalidate();
        }
    }

    protected override bool ProcessCmdKey(ref Message msg, Keys keyData)
    {
        if (_textBox is not null)
        {
            if (keyData == Keys.Escape)
            {
                CloseTextEditor();
                return true;
            }
            if (keyData == Keys.Enter || keyData == (Keys.Control | Keys.Enter))
            {
                CommitText();
                return true;
            }
            return base.ProcessCmdKey(ref msg, keyData);
        }
        if (keyData == Keys.Escape)
        {
            CancelCapture();
            return true;
        }
        if (keyData == Keys.Enter)
        {
            Complete();
            return true;
        }
        if (keyData == (Keys.Control | Keys.Z))
        {
            Undo();
            return true;
        }
        if (HasSelection && _drag == DragKind.None && (keyData & (Keys.Control | Keys.Alt)) == Keys.None)
        {
            int step = (keyData & Keys.Shift) != 0 ? 10 : 1;
            Point delta = (keyData & Keys.KeyCode) switch
            {
                Keys.Left => new Point(-step, 0),
                Keys.Right => new Point(step, 0),
                Keys.Up => new Point(0, -step),
                Keys.Down => new Point(0, step),
                _ => Point.Empty
            };
            if (delta != Point.Empty)
            {
                Rectangle moved = MoveSelection(_selection, delta.X, delta.Y);
                if (moved != _selection)
                {
                    PushHistory();
                    _selection = moved;
                    UpdateToolbar();
                    Invalidate();
                }
                return true;
            }
        }
        return base.ProcessCmdKey(ref msg, keyData);
    }

    private void BeginText(Point origin)
    {
        _textOrigin = ClampPoint(origin, _selection, false);
        Rectangle monitor = Screen.FromPoint(PointToScreen(origin)).Bounds;
        monitor.Offset(-_desktopBounds.Left, -_desktopBounds.Top);
        monitor.Intersect(ImageBounds);
        int width = Math.Min(420, Math.Max(140, monitor.Width - 16));
        int height = Math.Min(176, Math.Max(100, monitor.Height - 16));
        _textPanel = new Panel
        {
            Size = new Size(width, height),
            BackColor = Color.FromArgb(245, 248, 251),
            BorderStyle = BorderStyle.FixedSingle,
            Padding = new Padding(6),
            Location = new Point(
                Math.Clamp(origin.X, monitor.Left + 8, Math.Max(monitor.Left + 8, monitor.Right - width - 8)),
                Math.Clamp(origin.Y, monitor.Top + 8, Math.Max(monitor.Top + 8, monitor.Bottom - height - 8)))
        };
        var label = new Label
        {
            Text = "文字内容 · Enter 确认，Shift+Enter 换行，Esc 放弃",
            Dock = DockStyle.Top,
            Height = 24,
            ForeColor = Color.FromArgb(30, 45, 60),
            AutoEllipsis = true
        };
        _textBox = new TextBox
        {
            Multiline = true,
            AcceptsReturn = true,
            WordWrap = false,
            Dock = DockStyle.Fill,
            Font = _annotationFont,
            ForeColor = Ink,
            BackColor = Color.White,
            ScrollBars = ScrollBars.Both,
            AccessibleName = "截图标注文字",
            AccessibleDescription = "Enter 确认文字，Shift 加 Enter 换行，Escape 放弃文字"
        };
        _textPanel.Controls.Add(_textBox);
        _textPanel.Controls.Add(label);
        Controls.Add(_textPanel);
        _toolbar.Visible = false;
        _textPanel.BringToFront();
        _textBox.Focus();
    }

    private void CommitText()
    {
        if (_textBox is null)
            return;
        string value = _textBox.Text;
        if (!string.IsNullOrWhiteSpace(value))
            AddAnnotation(new TextAnnotation(_selection, _textOrigin, value));
        CloseTextEditor();
    }

    private void CloseTextEditor()
    {
        Panel? panel = _textPanel;
        _textBox = null;
        _textPanel = null;
        if (panel is not null)
        {
            Controls.Remove(panel);
            panel.Dispose();
        }
        UpdateToolbar();
        Focus();
        Invalidate();
    }

    private void PushHistory() => _history.Push(new EditState(_selection, _annotations.ToArray()));

    private void AddAnnotation(Annotation annotation)
    {
        PushHistory();
        _annotations.Add(annotation);
        RebuildComposite();
    }

    private void Undo()
    {
        CommitText();
        if (!_history.TryPop(out EditState? previous))
            return;
        _selection = previous.Selection;
        _annotations.Clear();
        _annotations.AddRange(previous.Annotations);
        RebuildComposite();
        UpdateToolbar();
        if (!_renderOnly)
            Focus();
        Invalidate();
    }

    private void RebuildComposite()
    {
        using (Graphics graphics = Graphics.FromImage(_composite))
        {
            graphics.CompositingMode = CompositingMode.SourceCopy;
            graphics.DrawImageUnscaled(_snapshot, Point.Empty);
        }
        foreach (Annotation annotation in _annotations)
            annotation.Apply(_composite, _annotationFont);
        Invalidate();
    }

    private Bitmap RenderSelection()
    {
        Rectangle area = Rectangle.Intersect(ImageBounds, _selection);
        if (area.Width < 2 || area.Height < 2)
            throw new InvalidOperationException("请先选择截图区域。");
        return _composite.Clone(area, PixelFormat.Format32bppArgb);
    }

    private void Complete()
    {
        if (!HasSelection || _drag != DragKind.None)
            return;
        CommitText();
        _result?.Dispose();
        _result = RenderSelection();
        DialogResult = DialogResult.OK;
        Close();
    }

    private void SavePng()
    {
        if (!HasSelection)
            return;
        CommitText();
        using var dialog = new SaveFileDialog
        {
            Title = "保存截图",
            Filter = "PNG 图片 (*.png)|*.png",
            DefaultExt = "png",
            AddExtension = true,
            OverwritePrompt = true,
            FileName = $"Xclip-{DateTime.Now:yyyyMMdd-HHmmss}.png"
        };
        if (dialog.ShowDialog(this) != DialogResult.OK)
            return;
        try
        {
            using Bitmap image = RenderSelection();
            // Encode before touching the destination, so encoding failures retain the old file.
            using var encoded = new MemoryStream();
            image.Save(encoded, ImageFormat.Png);
            File.WriteAllBytes(dialog.FileName, encoded.ToArray());
            _hint.Text = "截图已保存 · 可继续标注，或点击“复制完成”";
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException or System.Runtime.InteropServices.ExternalException)
        {
            MessageBox.Show(this, $"保存失败，编辑内容仍在。\n{exception.Message}", "无法保存截图",
                MessageBoxButtons.OK, MessageBoxIcon.Error);
        }
        Focus();
    }

    private void CancelCapture()
    {
        DialogResult = DialogResult.Cancel;
        Close();
    }

    private Point[] HandlePoints() =>
    [
        new(_selection.Left, _selection.Top),
        new(_selection.Left + _selection.Width / 2, _selection.Top),
        new(_selection.Right, _selection.Top),
        new(_selection.Right, _selection.Top + _selection.Height / 2),
        new(_selection.Right, _selection.Bottom),
        new(_selection.Left + _selection.Width / 2, _selection.Bottom),
        new(_selection.Left, _selection.Bottom),
        new(_selection.Left, _selection.Top + _selection.Height / 2)
    ];

    private int HitHandle(Point point)
    {
        if (_tool != EditorTool.Selection || !HasSelection)
            return -1;
        Point[] handles = HandlePoints();
        for (int index = 0; index < handles.Length; index++)
            if (Math.Abs(point.X - handles[index].X) <= HandleHitRadius &&
                Math.Abs(point.Y - handles[index].Y) <= HandleHitRadius)
                return index;
        return -1;
    }

    private Cursor CursorForHandle(int handle) => handle switch
    {
        0 or 4 => Cursors.SizeNWSE,
        2 or 6 => Cursors.SizeNESW,
        1 or 5 => Cursors.SizeNS,
        3 or 7 => Cursors.SizeWE,
        _ => _tool == EditorTool.Selection && HasSelection && _selection.Contains(PointToClient(Control.MousePosition))
            ? Cursors.SizeAll : Cursors.Cross
    };

    private Rectangle MoveSelection(Rectangle rectangle, int dx, int dy) => new(
        Math.Clamp(rectangle.X + dx, 0, _snapshot.Width - rectangle.Width),
        Math.Clamp(rectangle.Y + dy, 0, _snapshot.Height - rectangle.Height),
        rectangle.Width, rectangle.Height);

    private static Rectangle ResizeSelection(Rectangle rectangle, Point point, int handle)
    {
        int left = handle is 0 or 6 or 7 ? point.X : rectangle.Left;
        int top = handle is 0 or 1 or 2 ? point.Y : rectangle.Top;
        int right = handle is 2 or 3 or 4 ? point.X : rectangle.Right;
        int bottom = handle is 4 or 5 or 6 ? point.Y : rectangle.Bottom;
        return RectangleFromPoints(new Point(left, top), new Point(right, bottom));
    }

    private static Point ClampPoint(Point point, Rectangle bounds, bool includeEdge) => new(
        Math.Clamp(point.X, bounds.Left, Math.Max(bounds.Left, bounds.Right - (includeEdge ? 0 : 1))),
        Math.Clamp(point.Y, bounds.Top, Math.Max(bounds.Top, bounds.Bottom - (includeEdge ? 0 : 1))));

    private static Rectangle RectangleFromPoints(Point start, Point end) => Rectangle.FromLTRB(
        Math.Min(start.X, end.X), Math.Min(start.Y, end.Y), Math.Max(start.X, end.X), Math.Max(start.Y, end.Y));

    private static Rectangle PixelAreaFromPoints(Point start, Point end) => Rectangle.FromLTRB(
        Math.Min(start.X, end.X), Math.Min(start.Y, end.Y), Math.Max(start.X, end.X) + 1, Math.Max(start.Y, end.Y) + 1);

    private static long DistanceSquared(Point start, Point end) =>
        ((long)end.X - start.X) * (end.X - start.X) + ((long)end.Y - start.Y) * (end.Y - start.Y);

    private static void DrawArrow(Graphics graphics, Point start, Point end)
    {
        graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using var cap = new AdjustableArrowCap(5, 6, true);
        using var pen = new Pen(Ink, 3) { StartCap = LineCap.Round, CustomEndCap = cap };
        graphics.DrawLine(pen, start, end);
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing)
        {
            _composite.Dispose();
            _result?.Dispose();
        }
        base.Dispose(disposing);
        if (disposing)
        {
            _interfaceFont.Dispose();
            _annotationFont.Dispose();
        }
    }

    private enum EditorTool { Selection, Arrow, Text, Mosaic }
    private enum DragKind { None, NewSelection, Move, Resize, Annotation }
    private sealed record EditState(Rectangle Selection, Annotation[] Annotations);
    private abstract record Annotation(Rectangle Clip)
    {
        public abstract void Apply(Bitmap canvas, Font textFont);
    }

    private sealed record ArrowAnnotation(Rectangle Clip, Point Start, Point End) : Annotation(Clip)
    {
        public override void Apply(Bitmap canvas, Font textFont)
        {
            using Graphics graphics = Graphics.FromImage(canvas);
            graphics.SetClip(Clip);
            DrawArrow(graphics, Start, End);
        }
    }

    private sealed record TextAnnotation(Rectangle Clip, Point Origin, string Value) : Annotation(Clip)
    {
        public override void Apply(Bitmap canvas, Font textFont)
        {
            using Graphics graphics = Graphics.FromImage(canvas);
            graphics.SetClip(Clip);
            graphics.TextRenderingHint = System.Drawing.Text.TextRenderingHint.AntiAliasGridFit;
            using var brush = new SolidBrush(Ink);
            using var format = new StringFormat(StringFormat.GenericTypographic)
            {
                FormatFlags = StringFormatFlags.MeasureTrailingSpaces
            };
            graphics.DrawString(Value, textFont, brush, Origin, format);
        }
    }

    private sealed record MosaicAnnotation(Rectangle Clip, Rectangle Area) : Annotation(Clip)
    {
        public override void Apply(Bitmap canvas, Font textFont)
        {
            Rectangle area = Rectangle.Intersect(new Rectangle(Point.Empty, canvas.Size), Rectangle.Intersect(Clip, Area));
            if (area.Width <= 0 || area.Height <= 0)
                return;
            const int blockSize = 16;
            using var small = new Bitmap(Math.Max(1, (area.Width + blockSize - 1) / blockSize),
                Math.Max(1, (area.Height + blockSize - 1) / blockSize), PixelFormat.Format32bppArgb);
            using (Graphics downsample = Graphics.FromImage(small))
            {
                downsample.CompositingMode = CompositingMode.SourceCopy;
                downsample.InterpolationMode = InterpolationMode.HighQualityBilinear;
                using var attributes = new ImageAttributes();
                attributes.SetWrapMode(WrapMode.TileFlipXY);
                downsample.DrawImage(canvas, new Rectangle(Point.Empty, small.Size), area.X, area.Y,
                    area.Width, area.Height, GraphicsUnit.Pixel, attributes);
            }
            using Graphics graphics = Graphics.FromImage(canvas);
            graphics.CompositingMode = CompositingMode.SourceCopy;
            graphics.InterpolationMode = InterpolationMode.NearestNeighbor;
            graphics.PixelOffsetMode = PixelOffsetMode.Half;
            graphics.DrawImage(small, area, 0, 0, small.Width, small.Height, GraphicsUnit.Pixel);
        }
    }
}
