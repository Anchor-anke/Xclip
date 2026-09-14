using Xclip.Core;

namespace Xclip.Windows;

internal static class Program
{
    [STAThread]
    private static int Main(string[] args)
    {
        ApplicationConfiguration.Initialize();
        if (args.Contains("--smoke-test")) return SmokeTest.Run();
        using var mutex = new Mutex(true, @"Local\Xclip.Windows.Preview", out var firstInstance);
        using var showEvent = new EventWaitHandle(false, EventResetMode.AutoReset, @"Local\Xclip.Windows.Show");
        if (!firstInstance) { showEvent.Set(); return 0; }
        try
        {
            var dataDirectory = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Xclip");
            var store = new HistoryStore(dataDirectory);
            using var context = new XclipContext(store, showEvent);
            Application.Run(context);
            return 0;
        }
        catch (Exception ex)
        {
            MessageBox.Show($"Xclip 无法启动。已有历史不会被清空。\n\n{ex.Message}", "Xclip", MessageBoxButtons.OK, MessageBoxIcon.Error);
            return 1;
        }
        finally { mutex.ReleaseMutex(); }
    }
}
