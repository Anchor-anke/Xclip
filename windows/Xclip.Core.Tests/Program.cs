using System.Text.Json.Nodes;
using Xclip.Core;

// No test framework/NuGet dependency. Each scenario uses a real isolated temporary directory.
var cases = new (string Name, Action<string> Run)[]
{
    ("文本、图片和文件重启后保留", directory =>
    {
        var store = new HistoryStore(directory);
        var text = store.AddText("你好，Xclip 👋", "记事本");
        var image = store.AddImage(Png(), "画图");
        var files = store.AddFiles([@"C:\资料\a.txt", @"D:\b.png"], "资源管理器");
        var reopened = new HistoryStore(directory);
        Equal(3, reopened.Entries.Count);
        Equal(text.Content, reopened.Entries.Single(entry => entry.Id == text.Id).Content);
        Equal("记事本", reopened.Entries.Single(entry => entry.Id == text.Id).SourceApp);
        True(reopened.ReadImage(reopened.Entries.Single(entry => entry.Id == image.Id)).SequenceEqual(Png()));
        True(reopened.Entries.Single(entry => entry.Id == files.Id).Files.SequenceEqual(files.Files));
        True(File.Exists(Path.Combine(directory, "history.json")));
        Equal(1, Directory.GetFiles(Path.Combine(directory, "attachments"), "*.png").Length);
    }),
    ("文本去重保留 ID、收藏、置顶并更新来源", directory =>
    {
        var store = new HistoryStore(directory);
        var first = store.AddText("same", "old");
        store.UpdateFlags(first.Id, favorite: true, pinned: true);
        var duplicate = store.AddText("same", "new");
        Equal(first.Id, duplicate.Id);
        True(duplicate.IsFavorite && duplicate.IsPinned);
        True(duplicate.CreatedAt >= first.CreatedAt);
        Equal("new", duplicate.SourceApp);
        Equal(1, store.Entries.Count);
        store.AddText("Same");
        Equal(2, store.Entries.Count);
    }),
    ("图片按字节去重，文件按 Windows 大小写去重", directory =>
    {
        var store = new HistoryStore(directory);
        var image = store.AddImage(Png());
        store.UpdateFlags(image.Id, favorite: true);
        Equal(image.Id, store.AddImage(Png()).Id);
        True(store.Entries.Single().IsFavorite);
        var file = store.AddFiles([@"C:\Reports\A.txt"]);
        Equal(file.Id, store.AddFiles([@"c:\reports\a.TXT"]).Id);
        Equal(2, store.Entries.Count);
    }),
    ("搜索覆盖内容、文件路径、来源和收藏筛选", directory =>
    {
        var store = new HistoryStore(directory);
        var text = store.AddText("Hello 世界", "Editor");
        store.AddFiles([@"C:\Reports\Budget.xlsx"]);
        store.UpdateFlags(text.Id, favorite: true);
        Equal(text.Id, store.Search("hELLo").Single().Id);
        Equal(text.Id, store.Search("世界").Single().Id);
        Equal(text.Id, store.Search("editor").Single().Id);
        Equal(1, store.Search("budget").Count);
        Equal(0, store.Search("budget", favoritesOnly: true).Count);
        Equal(1, store.Search("", favoritesOnly: true).Count);
    }),
    ("置顶排序和标志持久化", directory =>
    {
        var store = new HistoryStore(directory);
        var old = store.AddText("old");
        store.AddText("new");
        store.UpdateFlags(old.Id, pinned: true);
        Equal(old.Id, store.Entries[0].Id);
        store.UpdateFlags(old.Id, favorite: true);
        var reopened = new HistoryStore(directory);
        True(reopened.Entries[0].IsPinned && reopened.Entries[0].IsFavorite);
        store.UpdateFlags(old.Id, pinned: false);
        True(store.Entries.Single(entry => entry.Id == old.Id).IsFavorite);
    }),
    ("仅裁剪普通条目并保护收藏和置顶", directory =>
    {
        var store = new HistoryStore(directory, maxItems: 2);
        var favorite = store.AddText("favorite");
        store.UpdateFlags(favorite.Id, favorite: true);
        var pinned = store.AddText("pinned");
        store.UpdateFlags(pinned.Id, pinned: true);
        store.AddText("ordinary1");
        store.AddText("ordinary2");
        store.AddText("ordinary3");
        Equal(4, store.Entries.Count);
        True(store.Entries.Any(entry => entry.Id == favorite.Id));
        True(store.Entries.Any(entry => entry.Id == pinned.Id));
        True(!store.Entries.Any(entry => entry.Content == "ordinary1"));
        Equal(2, store.Entries.Count(entry => !entry.IsPinned && !entry.IsFavorite));
        store.UpdateFlags(favorite.Id, favorite: false);
        Equal(3, store.Entries.Count);
    }),
    ("单条删除撤销及重启持久化", directory =>
    {
        var store = new HistoryStore(directory);
        var entry = store.AddText("restore");
        store.UpdateFlags(entry.Id, favorite: true, pinned: true);
        store.Delete(entry.Id);
        True(store.CanUndo);
        Equal(0, store.Entries.Count);
        Equal(0, new HistoryStore(directory).Entries.Count);
        True(store.UndoDelete());
        Equal(entry.Id, store.Entries.Single().Id);
        True(store.Entries.Single().IsFavorite && store.Entries.Single().IsPinned);
        True(!store.CanUndo && !store.UndoDelete());
        Equal(entry.Id, new HistoryStore(directory).Entries.Single().Id);
    }),
    ("清除普通条目可撤销且保护收藏置顶", directory =>
    {
        var store = new HistoryStore(directory);
        var favorite = store.AddText("favorite");
        store.UpdateFlags(favorite.Id, favorite: true);
        var pinned = store.AddText("pinned");
        store.UpdateFlags(pinned.Id, pinned: true);
        store.AddText("clear1");
        store.AddText("clear2");
        store.ClearUnprotected();
        Equal(2, store.Entries.Count);
        True(store.Entries.All(entry => entry.IsFavorite || entry.IsPinned));
        True(store.UndoDelete());
        Equal(4, store.Entries.Count);
    }),
    ("图片删除保留撤销附件，后续写入回收附件", directory =>
    {
        var store = new HistoryStore(directory);
        var image = store.AddImage(Png());
        var path = Path.Combine(directory, "attachments", image.AttachmentName!);
        store.Delete(image.Id);
        True(File.Exists(path));
        True(store.UndoDelete());
        True(store.ReadImage(image).SequenceEqual(Png()));
        store.Delete(image.Id);
        store.AddText("next write");
        True(!store.CanUndo);
        True(!File.Exists(path));
    }),
    ("调用方不能通过数组修改内部历史", directory =>
    {
        var store = new HistoryStore(directory);
        string[] input = [@"C:\original.txt"];
        var entry = store.AddFiles(input);
        input[0] = "input mutation";
        entry.Files[0] = "return mutation";
        store.Entries[0].Files[0] = "snapshot mutation";
        store.Search("")[0].Files[0] = "search mutation";
        Equal(@"C:\original.txt", store.Entries[0].Files[0]);
        Equal(@"C:\original.txt", new HistoryStore(directory).Entries[0].Files[0]);
    }),
    ("损坏 JSON 保留且拒绝加载", directory =>
    {
        var path = Path.Combine(directory, "history.json");
        const string invalid = "{ invalid history";
        File.WriteAllText(path, invalid);
        Throws<InvalidDataException>(() => new HistoryStore(directory));
        Equal(invalid, File.ReadAllText(path));
    }),
    ("不支持版本、缺失字段、重复字段均拒绝", directory =>
    {
        var store = new HistoryStore(directory);
        store.AddText("safe");
        var path = Path.Combine(directory, "history.json");
        var original = File.ReadAllText(path);
        foreach (var replacement in new[]
        {
            original.Replace("\"schemaVersion\": 1", "\"schemaVersion\": 2", StringComparison.Ordinal),
            original.Replace("\"isFavorite\": false,", "", StringComparison.Ordinal),
            original.Replace("\"schemaVersion\": 1", "\"schemaVersion\": 1, \"schemaVersion\": 1", StringComparison.Ordinal)
        })
        {
            File.WriteAllText(path, replacement);
            Throws<InvalidDataException>(() => new HistoryStore(directory));
            Equal(replacement, File.ReadAllText(path));
        }
    }),
    ("无效 ID、类型、文件字段及重复条目拒绝", directory =>
    {
        var store = new HistoryStore(directory);
        store.AddText("safe");
        var path = Path.Combine(directory, "history.json");
        var original = File.ReadAllText(path);
        foreach (var mutate in new Action<JsonObject>[]
        {
            row => row["id"] = Guid.Empty.ToString(),
            row => row["kind"] = 0,
            row => row["kind"] = "Unknown",
            row => row["files"] = new JsonArray("unexpected"),
            row => row["files"] = null,
            row => row["createdAt"] = "0001-01-01T00:00:00+00:00"
        })
        {
            var root = JsonNode.Parse(original)!;
            mutate(root["entries"]![0]!.AsObject());
            var modified = root.ToJsonString();
            File.WriteAllText(path, modified);
            Throws<InvalidDataException>(() => new HistoryStore(directory));
            Equal(modified, File.ReadAllText(path));
        }
        var duplicateRoot = JsonNode.Parse(original)!;
        var copy = duplicateRoot["entries"]![0]!.DeepClone();
        copy["id"] = Guid.NewGuid().ToString();
        duplicateRoot["entries"]!.AsArray().Add(copy);
        File.WriteAllText(path, duplicateRoot.ToJsonString());
        Throws<InvalidDataException>(() => new HistoryStore(directory));
    }),
    ("加载及读取拒绝附件路径穿越", directory =>
    {
        var store = new HistoryStore(directory);
        var image = store.AddImage(Png());
        var path = Path.Combine(directory, "history.json");
        var original = File.ReadAllText(path);
        foreach (var name in new[] { "../outside.png", "..\\outside.png", "/tmp/outside.png", "C:\\outside.png", new string('a', 64) + ".PNG" })
        {
            Throws<InvalidDataException>(() => store.ReadImage(image with { AttachmentName = name }));
            var root = JsonNode.Parse(original)!;
            root["entries"]![0]!["attachmentName"] = name;
            var modified = root.ToJsonString();
            File.WriteAllText(path, modified);
            Throws<InvalidDataException>(() => new HistoryStore(directory));
            Equal(modified, File.ReadAllText(path));
        }
    }),
    ("附件被损坏时禁止覆盖元数据", directory =>
    {
        var store = new HistoryStore(directory);
        var image = store.AddImage(Png());
        var path = Path.Combine(directory, "attachments", image.AttachmentName!);
        var metadata = File.ReadAllText(Path.Combine(directory, "history.json"));
        File.WriteAllText(path, "damaged");
        Throws<InvalidDataException>(() => store.ReadImage(image));
        Throws<InvalidDataException>(() => new HistoryStore(directory));
        Throws<InvalidDataException>(() => store.AddText("must not commit"));
        Equal(1, store.Entries.Count);
        Equal(metadata, File.ReadAllText(Path.Combine(directory, "history.json")));
        Equal("damaged", File.ReadAllText(path));
    }),
    ("外部修改不能被运行中实例覆盖", directory =>
    {
        var store = new HistoryStore(directory);
        store.AddText("before");
        var path = Path.Combine(directory, "history.json");
        File.WriteAllText(path, "external invalid data");
        Throws<InvalidDataException>(() => store.AddText("after"));
        Equal("before", store.Entries.Single().Content);
        Equal("external invalid data", File.ReadAllText(path));
    }),
    ("并存实例拒绝用旧快照覆盖新内容", directory =>
    {
        var first = new HistoryStore(directory);
        var second = new HistoryStore(directory);
        first.AddText("first committed");
        Throws<InvalidDataException>(() => second.AddText("stale write"));
        Equal(0, second.Entries.Count);
        Equal("first committed", new HistoryStore(directory).Entries.Single().Content);
    }),
    ("原子写入失败保留内存与撤销状态", directory =>
    {
        var store = new HistoryStore(directory);
        var entry = store.AddText("safe");
        store.Delete(entry.Id);
        True(store.CanUndo);
        var path = Path.Combine(directory, "history.json");
        File.Delete(path);
        Directory.CreateDirectory(path);
        Throws<InvalidDataException>(() => store.AddText("failed"));
        True(store.CanUndo);
        Equal(0, store.Entries.Count);
        True(Directory.Exists(path));
    }),
    ("安全输入限制在写盘前生效", directory =>
    {
        var store = new HistoryStore(directory);
        Throws<ArgumentException>(() => store.AddText(""));
        Throws<ArgumentException>(() => store.AddText("a\0b"));
        Throws<ArgumentException>(() => store.AddText("a\uD800b"));
        Throws<ArgumentException>(() => store.AddText(new string('x', HistoryStore.MaximumTextCharacters + 1)));
        Throws<ArgumentException>(() => store.AddText("safe", new string('x', 1025)));
        Throws<ArgumentException>(() => store.AddFiles([]));
        Throws<ArgumentException>(() => store.AddFiles(Enumerable.Repeat("C:\\x", 257).ToArray()));
        Throws<ArgumentException>(() => store.AddFiles(["C:\\a\nb"]));
        Throws<ArgumentException>(() => store.AddImage([1, 2, 3]));
        Throws<ArgumentException>(() => store.AddImage(Png()[..^1]));
        var oversizeDimensions = Png();
        oversizeDimensions[16] = 1;
        Throws<ArgumentException>(() => store.AddImage(oversizeDimensions));
        Throws<ArgumentException>(() => store.Search(new string('x', 4097)));
        Throws<ArgumentOutOfRangeException>(() => new HistoryStore(directory, 0));
        Equal(0, store.Entries.Count);
        True(!File.Exists(Path.Combine(directory, "history.json")));
    }),
    ("总条目上限保护收藏数据且写入失败不丢记录", directory =>
    {
        // Seed a valid schema directly so this limit check does not perform 1000 redundant disk commits.
        var store = new HistoryStore(directory);
        store.AddText("seed");
        var path = Path.Combine(directory, "history.json");
        var root = JsonNode.Parse(File.ReadAllText(path))!;
        var prototype = root["entries"]![0]!.DeepClone();
        var rows = new JsonArray();
        for (var index = 0; index < HistoryStore.MaximumEntries; index++)
        {
            var row = prototype.DeepClone();
            row["id"] = Guid.NewGuid().ToString();
            row["content"] = "protected " + index;
            row["isFavorite"] = true;
            rows.Add(row);
        }
        root["entries"] = rows;
        File.WriteAllText(path, root.ToJsonString());
        var full = new HistoryStore(directory);
        var before = File.ReadAllText(path);
        Throws<InvalidDataException>(() => full.AddText("beyond limit"));
        Equal(HistoryStore.MaximumEntries, full.Entries.Count);
        Equal(before, File.ReadAllText(path));
    }),
    ("未知附件保留且纳入磁盘预算", directory =>
    {
        var store = new HistoryStore(directory);
        var attachments = Path.Combine(directory, "attachments");
        Directory.CreateDirectory(attachments);
        var unknown = Path.Combine(attachments, "unrecognized.bin");
        using (var file = File.Create(unknown)) file.SetLength(HistoryStore.MaximumAttachmentBytes);
        Throws<InvalidOperationException>(() => store.AddImage(Png()));
        True(File.Exists(unknown));
        Equal(0, store.Entries.Count);
    })
};

var failed = 0;
foreach (var (name, run) in cases)
{
    var directory = Path.Combine(Path.GetTempPath(), "Xclip.Core.Tests-" + Guid.NewGuid().ToString("N"));
    Directory.CreateDirectory(directory);
    try { run(directory); Console.WriteLine("PASS " + name); }
    catch (Exception exception) { failed++; Console.Error.WriteLine("FAIL " + name + "\n" + exception); }
    finally { Directory.Delete(directory, recursive: true); }
}
Console.WriteLine($"{cases.Length - failed} passed / {failed} failed");
return failed == 0 ? 0 : 1;

static byte[] Png() => Convert.FromBase64String("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAusB9Wl2ZpQAAAAASUVORK5CYII=");
static void True(bool condition) { if (!condition) throw new InvalidOperationException("Expected true."); }
static void Equal<T>(T expected, T actual)
{
    if (!EqualityComparer<T>.Default.Equals(expected, actual)) throw new InvalidOperationException($"Expected {expected}, got {actual}.");
}
static void Throws<T>(Action action) where T : Exception
{
    try { action(); }
    catch (T) { return; }
    throw new InvalidOperationException("Expected " + typeof(T).Name + ".");
}
