using Xclip.Core;

namespace Xclip.Windows;

/// <summary>Isolated layout/interop smoke; never reads the desktop or system clipboard.</summary>
internal static class SmokeTest
{
    internal static int Run()
    {
        var directory = Path.Combine(Path.GetTempPath(), "xclip-smoke-" + Guid.NewGuid().ToString("N"));
        try
        {
            if (NativeMethods.InputSize != (Environment.Is64BitProcess ? 40 : 28))
                throw new InvalidOperationException("Win32 INPUT size mismatch.");
            CaptureForm.RunRenderingSmokeTest();
            var store = new HistoryStore(directory);
            store.AddText("Xclip 测试文本\n第二行", "Smoke test");
            using var form = new HistoryForm(store);
            form.Show();
            form.PrepareToShow();
            form.RefreshEntries();
            form.SetStatus("隔离烟雾测试");
            Application.DoEvents();
            using var render = new Bitmap(form.Width, form.Height);
            form.DrawToBitmap(render, new Rectangle(Point.Empty, form.Size));
            var reportDirectory = Environment.GetEnvironmentVariable("XCLIP_SMOKE_OUTPUT");
            if (!string.IsNullOrWhiteSpace(reportDirectory))
            {
                Directory.CreateDirectory(reportDirectory);
                render.Save(Path.Combine(reportDirectory, "history-smoke.png"), System.Drawing.Imaging.ImageFormat.Png);
                File.WriteAllText(Path.Combine(reportDirectory, "smoke.txt"), "PASS: history form initialization, layout, screenshot pixel composition/undo, geometry and Win32 INPUT size. No system clipboard or desktop capture performed.");
            }
            form.AllowClose = true;
            form.Close();
            return 0;
        }
        catch (Exception ex) { Console.Error.WriteLine(ex); return 1; }
        finally { if (Directory.Exists(directory)) Directory.Delete(directory, true); }
    }
}
