using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Xclip.Core;

/// <summary>Local, bounded clipboard history. A failed commit leaves the previous in-memory history intact.</summary>
public sealed class HistoryStore
{
    public const int MaximumTextCharacters = 1_048_576;
    public const int MaximumImageBytes = 32 * 1024 * 1024;
    public const long MaximumAttachmentBytes = 512L * 1024 * 1024;
    public const int MaximumEntries = 1000;
    private const int MaximumMetadataBytes = 32 * 1024 * 1024;
    private const int MaximumAttachmentFiles = 4096;
    private static readonly byte[] PngSignature = [137, 80, 78, 71, 13, 10, 26, 10];
    private static readonly string[] EntryProperties =
        ["id", "kind", "content", "createdAt", "isFavorite", "isPinned", "sourceApp", "attachmentName", "files"];
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        WriteIndented = true,
        UnmappedMemberHandling = JsonUnmappedMemberHandling.Disallow,
        Converters = { new JsonStringEnumConverter(allowIntegerValues: false) }
    };
    private readonly object _gate = new();
    private readonly int _maxItems;
    private readonly string _metadataPath;
    private readonly string _attachmentDirectory;
    private readonly string _lockPath;
    private readonly Dictionary<string, (long Length, long LastWriteTicks)> _verifiedAttachments = new(StringComparer.Ordinal);
    private List<ClipboardEntry> _entries = [];
    private List<ClipboardEntry>? _undo;
    private byte[]? _diskHash;

    public HistoryStore(string directory, int maxItems = 300)
    {
        ArgumentException.ThrowIfNullOrWhiteSpace(directory);
        if (maxItems is < 1 or > MaximumEntries)
            throw new ArgumentOutOfRangeException(nameof(maxItems), $"普通历史上限必须为 1–{MaximumEntries}。");
        DirectoryPath = Path.GetFullPath(directory);
        _maxItems = maxItems;
        _metadataPath = Path.Combine(DirectoryPath, "history.json");
        _attachmentDirectory = Path.Combine(DirectoryPath, "attachments");
        _lockPath = Path.Combine(DirectoryPath, "history.lock");
        Directory.CreateDirectory(DirectoryPath);
        EnsureNotLink(DirectoryPath);
        using var diskLock = AcquireDiskLock();
        if (File.Exists(_metadataPath))
        {
            try
            {
                var bytes = ReadBoundedFile(_metadataPath, MaximumMetadataBytes);
                using var document = JsonDocument.Parse(bytes, new JsonDocumentOptions { MaxDepth = 16 });
                ValidateSchema(document.RootElement);
                var state = JsonSerializer.Deserialize<HistoryDocument>(bytes, JsonOptions)
                    ?? throw new InvalidDataException("历史文件内容为空。");
                if (state.SchemaVersion != 1 || state.Entries is null)
                    throw new InvalidDataException("历史文件版本不受支持。");
                ValidateEntries(state.Entries, verifyAttachments: true);
                _entries = Sort(state.Entries);
                _diskHash = SHA256.HashData(bytes);
            }
            catch (Exception exception) when (exception is JsonException or ArgumentException or OverflowException)
            {
                throw new InvalidDataException("历史文件损坏，原文件已保留；请先备份并修复，程序不会覆盖它。", exception);
            }
        }
        else if (Directory.Exists(_metadataPath))
        {
            throw new InvalidDataException("历史文件路径被目录占用。");
        }
    }

    public string DirectoryPath { get; }

    // Copies keep a caller's mutable Files array from modifying the persisted state accidentally.
    public IReadOnlyList<ClipboardEntry> Entries
    {
        get { lock (_gate) return Snapshot(_entries).AsReadOnly(); }
    }

    public bool CanUndo { get { lock (_gate) return _undo is not null; } }

    public ClipboardEntry AddText(string text, string? source = null)
    {
        ValidateText(text);
        ValidateSource(source);
        return Add(new ClipboardEntry { Kind = ClipboardKind.Text, Content = text, SourceApp = source });
    }

    public ClipboardEntry AddFiles(string[] paths, string? source = null)
    {
        ArgumentNullException.ThrowIfNull(paths);
        var copy = paths.ToArray();
        ValidateFiles(copy);
        ValidateSource(source);
        return Add(new ClipboardEntry
        {
            Kind = ClipboardKind.Files, Files = copy, Content = string.Join('\n', copy), SourceApp = source
        });
    }

    public ClipboardEntry AddImage(byte[] png, string? source = null)
    {
        ArgumentNullException.ThrowIfNull(png);
        if (png.Length > MaximumImageBytes) throw new ArgumentException("图片超过 32 MB 上限。", nameof(png));
        var copy = png.ToArray();
        var (width, height) = ValidatePng(copy);
        ValidateSource(source);
        return Add(new ClipboardEntry
        {
            Kind = ClipboardKind.Image,
            Content = $"图片 · {width} × {height}",
            SourceApp = source,
            AttachmentName = Convert.ToHexStringLower(SHA256.HashData(copy)) + ".png"
        }, copy);
    }

    public IReadOnlyList<ClipboardEntry> Search(string query, bool favoritesOnly = false)
    {
        ArgumentNullException.ThrowIfNull(query);
        if (query.Length > 4096) throw new ArgumentException("搜索词超过 4096 字符上限。", nameof(query));
        lock (_gate)
        {
            return Snapshot(_entries.Where(entry => (!favoritesOnly || entry.IsFavorite) &&
                (query.Length == 0 || entry.Content.Contains(query, StringComparison.OrdinalIgnoreCase) ||
                 (entry.SourceApp?.Contains(query, StringComparison.OrdinalIgnoreCase) ?? false)))).AsReadOnly();
        }
    }

    public void UpdateFlags(Guid id, bool? favorite = null, bool? pinned = null)
    {
        lock (_gate)
        {
            var index = FindIndex(id);
            var candidate = Snapshot(_entries);
            candidate[index] = candidate[index] with
            {
                IsFavorite = favorite ?? candidate[index].IsFavorite,
                IsPinned = pinned ?? candidate[index].IsPinned
            };
            Commit(Trim(candidate), undo: null);
        }
    }

    public void Delete(Guid id)
    {
        lock (_gate)
        {
            var index = FindIndex(id);
            var candidate = Snapshot(_entries);
            candidate.RemoveAt(index);
            Commit(candidate, Snapshot(_entries));
        }
    }

    public void ClearUnprotected()
    {
        lock (_gate)
        {
            var candidate = _entries.Where(IsProtected).ToList();
            if (candidate.Count == _entries.Count) return;
            Commit(candidate, Snapshot(_entries));
        }
    }

    public bool UndoDelete()
    {
        lock (_gate)
        {
            if (_undo is null) return false;
            Commit(Snapshot(_undo), undo: null);
            return true;
        }
    }

    public byte[] ReadImage(ClipboardEntry entry)
    {
        ArgumentNullException.ThrowIfNull(entry);
        if (entry.Kind != ClipboardKind.Image) throw new ArgumentException("该历史记录不是图片。", nameof(entry));
        lock (_gate) return ReadAttachment(entry.AttachmentName);
    }

    private ClipboardEntry Add(ClipboardEntry proposed, byte[]? image = null)
    {
        lock (_gate)
        {
            using var diskLock = AcquireDiskLock();
            VerifyDiskSnapshot();
            var candidate = Snapshot(_entries);
            var duplicate = candidate.FirstOrDefault(entry => SameContent(entry, proposed));
            var entry = proposed with
            {
                Id = duplicate?.Id ?? Guid.NewGuid(), CreatedAt = DateTimeOffset.UtcNow,
                IsFavorite = duplicate?.IsFavorite ?? false, IsPinned = duplicate?.IsPinned ?? false
            };
            if (duplicate is not null) candidate.Remove(duplicate);
            candidate.Add(entry);
            candidate = Trim(candidate);
            ValidateEntries(candidate, verifyAttachments: false);
            if (image is not null) WriteAttachment(entry.AttachmentName!, image);
            CommitLocked(candidate, undo: null);
            return Copy(entry);
        }
    }

    private void Commit(List<ClipboardEntry> candidate, List<ClipboardEntry>? undo)
    {
        using var diskLock = AcquireDiskLock();
        VerifyDiskSnapshot();
        CommitLocked(candidate, undo);
    }

    private void CommitLocked(List<ClipboardEntry> candidate, List<ClipboardEntry>? undo)
    {
        candidate = Sort(candidate);
        ValidateEntries(candidate, verifyAttachments: true);
        var bytes = JsonSerializer.SerializeToUtf8Bytes(new HistoryDocument { SchemaVersion = 1, Entries = candidate }, JsonOptions);
        if (bytes.Length > MaximumMetadataBytes)
            throw new InvalidOperationException("历史元数据超过 32 MB 上限，请先删除部分记录。");
        WriteAtomically(_metadataPath, bytes, overwrite: true);
        _entries = candidate;
        _undo = undo;
        _diskHash = SHA256.HashData(bytes);
        CleanupUnreferencedAttachments();
    }

    private List<ClipboardEntry> Trim(List<ClipboardEntry> entries)
    {
        var keep = entries.Where(entry => !IsProtected(entry)).OrderByDescending(entry => entry.CreatedAt)
            .ThenBy(entry => entry.Id).Take(_maxItems).Select(entry => entry.Id).ToHashSet();
        return entries.Where(entry => IsProtected(entry) || keep.Contains(entry.Id)).ToList();
    }

    private static bool IsProtected(ClipboardEntry entry) => entry.IsFavorite || entry.IsPinned;

    private static bool SameContent(ClipboardEntry left, ClipboardEntry right) => left.Kind == right.Kind &&
        (left.Kind switch
        {
            ClipboardKind.Image => left.AttachmentName == right.AttachmentName,
            ClipboardKind.Files => left.Files.SequenceEqual(right.Files, StringComparer.OrdinalIgnoreCase),
            _ => left.Content == right.Content
        });

    private int FindIndex(Guid id)
    {
        var index = _entries.FindIndex(entry => entry.Id == id);
        return index >= 0 ? index : throw new KeyNotFoundException("该历史记录已不存在。");
    }

    private static ClipboardEntry Copy(ClipboardEntry entry) => entry with { Files = entry.Files.ToArray() };
    private static List<ClipboardEntry> Snapshot(IEnumerable<ClipboardEntry> entries) => entries.Select(Copy).ToList();
    private static List<ClipboardEntry> Sort(IEnumerable<ClipboardEntry> entries) => entries.OrderByDescending(entry => entry.IsPinned)
        .ThenByDescending(entry => entry.CreatedAt).ThenBy(entry => entry.Id).ToList();

    private static void ValidateText(string? text)
    {
        if (string.IsNullOrEmpty(text) || text.Length > MaximumTextCharacters || text.Contains('\0') || HasInvalidUnicode(text))
            throw new ArgumentException("文本必须非空、Unicode 有效且不含空字符，不超过 1,048,576 字符。");
    }

    private static void ValidateSource(string? source)
    {
        if (source is not null && (source.Length > 1024 || source.Contains('\0') || HasInvalidUnicode(source)))
            throw new ArgumentException("来源应用名称无效或过长。");
    }

    private static void ValidateFiles(string[]? files)
    {
        if (files is null || files.Length is < 1 or > 256) throw new ArgumentException("文件列表必须包含 1–256 个路径。");
        long total = 0;
        foreach (var path in files)
        {
            if (string.IsNullOrWhiteSpace(path) || path.Length > 32767 || path.IndexOfAny(['\0', '\r', '\n']) >= 0 || HasInvalidUnicode(path))
                throw new ArgumentException("文件路径为空、过长或包含无效字符。");
            total += path.Length;
        }
        if (total > MaximumTextCharacters) throw new ArgumentException("文件路径总长度超出上限。");
    }

    private static bool HasInvalidUnicode(string text)
    {
        for (var index = 0; index < text.Length; index++)
        {
            if (char.IsHighSurrogate(text[index]))
            {
                if (++index == text.Length || !char.IsLowSurrogate(text[index])) return true;
            }
            else if (char.IsLowSurrogate(text[index])) return true;
        }
        return false;
    }

    private void ValidateEntries(List<ClipboardEntry> entries, bool verifyAttachments)
    {
        if (entries.Count > MaximumEntries) throw new InvalidDataException("历史总量超过 1000 条上限，请先删除部分受保护记录。");
        var ids = new HashSet<Guid>();
        var fingerprints = new HashSet<string>(StringComparer.Ordinal);
        var verifiedImages = new HashSet<string>(StringComparer.Ordinal);
        foreach (var entry in entries)
        {
            if (entry is null || entry.Id == Guid.Empty || !ids.Add(entry.Id) || !Enum.IsDefined(entry.Kind) ||
                entry.CreatedAt == default || entry.Content is null || entry.Files is null)
                throw new InvalidDataException("历史记录的标识、时间或类型无效。");
            ValidateSource(entry.SourceApp);
            switch (entry.Kind)
            {
                case ClipboardKind.Text:
                    ValidateText(entry.Content);
                    if (entry.Files.Length != 0 || entry.AttachmentName is not null) throw new InvalidDataException("文本记录格式无效。");
                    break;
                case ClipboardKind.Files:
                    ValidateFiles(entry.Files);
                    if (entry.AttachmentName is not null || entry.Content != string.Join('\n', entry.Files))
                        throw new InvalidDataException("文件记录格式无效。");
                    break;
                case ClipboardKind.Image:
                    ValidateAttachmentName(entry.AttachmentName);
                    ValidateText(entry.Content);
                    if (entry.Files.Length != 0 || entry.Content.Length > 1024) throw new InvalidDataException("图片记录格式无效。");
                    if (verifyAttachments && verifiedImages.Add(entry.AttachmentName!)) VerifyAttachment(entry.AttachmentName!);
                    break;
            }
            var payload = entry.Kind == ClipboardKind.Image ? entry.AttachmentName! :
                entry.Kind == ClipboardKind.Files ? entry.Content.ToUpperInvariant() : entry.Content;
            var fingerprint = ((int)entry.Kind).ToString() + ":" + payload;
            if (!fingerprints.Add(fingerprint)) throw new InvalidDataException("历史文件存在重复内容，原文件已保留。");
        }
    }

    private static void ValidateSchema(JsonElement root)
    {
        RequireProperties(root, ["schemaVersion", "entries"]);
        if (root.GetProperty("entries").ValueKind != JsonValueKind.Array)
            throw new InvalidDataException("历史记录列表格式无效。");
        foreach (var entry in root.GetProperty("entries").EnumerateArray()) RequireProperties(entry, EntryProperties);
    }

    private static void RequireProperties(JsonElement element, string[] required)
    {
        if (element.ValueKind != JsonValueKind.Object) throw new InvalidDataException("历史文件结构无效。");
        var seen = new HashSet<string>(StringComparer.Ordinal);
        foreach (var property in element.EnumerateObject())
            if (!required.Contains(property.Name, StringComparer.Ordinal) || !seen.Add(property.Name))
                throw new InvalidDataException("历史文件包含未知或重复字段。");
        if (seen.Count != required.Length) throw new InvalidDataException("历史文件缺少必要字段。");
    }

    private static (uint Width, uint Height) ValidatePng(byte[] bytes)
    {
        if (bytes.Length is < 45 or > MaximumImageBytes || !bytes.AsSpan(0, 8).SequenceEqual(PngSignature))
            throw new ArgumentException("图片不是受支持的 PNG，或超过 32 MB 上限。");
        var width = BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(16, 4));
        var height = BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(20, 4));
        if (BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(8, 4)) != 13 ||
            !bytes.AsSpan(12, 4).SequenceEqual("IHDR"u8) || width is 0 or > 16384 || height is 0 or > 16384 ||
            (ulong)width * height > 64_000_000)
            throw new ArgumentException("PNG 头部无效，或图片尺寸超过 16,384 边长 / 6400 万像素上限。");
        // Structural checks are independent of platform image decoders. Decoder validation remains the UI's responsibility.
        var offset = 8;
        var hasData = false;
        while (offset <= bytes.Length - 12)
        {
            var length = BinaryPrimitives.ReadUInt32BigEndian(bytes.AsSpan(offset, 4));
            if (length > bytes.Length - offset - 12) throw new ArgumentException("PNG 数据块被截断。");
            var type = bytes.AsSpan(offset + 4, 4);
            if (type.SequenceEqual("IDAT"u8)) hasData = true;
            if (type.SequenceEqual("IEND"u8))
            {
                if (length != 0 || offset + 12 != bytes.Length || !hasData) throw new ArgumentException("PNG 结束数据块无效。");
                return (width, height);
            }
            offset += checked((int)length + 12);
        }
        throw new ArgumentException("PNG 缺少结束数据块。");
    }

    private static void ValidateAttachmentName(string? name)
    {
        if (name is null || name.Length != 68 || !name.EndsWith(".png", StringComparison.Ordinal) ||
            name.AsSpan(0, 64).ContainsAnyExcept("0123456789abcdef"))
            throw new InvalidDataException("图片附件名称无效；禁止路径穿越或外部引用。");
    }

    private byte[] ReadAttachment(string? name)
    {
        ValidateAttachmentName(name);
        EnsureNotLink(_attachmentDirectory);
        var bytes = ReadBoundedFile(Path.Combine(_attachmentDirectory, name!), MaximumImageBytes);
        if (Convert.ToHexStringLower(SHA256.HashData(bytes)) + ".png" != name)
            throw new InvalidDataException("图片附件校验失败，原文件已保留。");
        try { ValidatePng(bytes); }
        catch (ArgumentException exception) { throw new InvalidDataException("图片附件已损坏，原文件已保留。", exception); }
        var info = new FileInfo(Path.Combine(_attachmentDirectory, name!));
        _verifiedAttachments[name!] = (info.Length, info.LastWriteTimeUtc.Ticks);
        return bytes;
    }

    private void VerifyAttachment(string name)
    {
        EnsureNotLink(_attachmentDirectory);
        var path = Path.Combine(_attachmentDirectory, name);
        EnsureNotLink(path);
        var info = new FileInfo(path);
        var signature = (info.Length, info.LastWriteTimeUtc.Ticks);
        // Repeated text captures only stat each image. Loading, changed files and explicit ReadImage still hash all bytes.
        if (!_verifiedAttachments.TryGetValue(name, out var verified) || verified != signature) ReadAttachment(name);
    }

    private void WriteAttachment(string name, byte[] bytes)
    {
        Directory.CreateDirectory(_attachmentDirectory);
        EnsureNotLink(_attachmentDirectory);
        var path = Path.Combine(_attachmentDirectory, name);
        if (File.Exists(path)) { ReadAttachment(name); return; }
        CleanupUnreferencedAttachments();
        long total = bytes.Length;
        var count = 1;
        foreach (var existing in Directory.EnumerateFileSystemEntries(_attachmentDirectory))
        {
            EnsureNotLink(existing);
            if (Directory.Exists(existing)) throw new InvalidDataException("附件目录包含未知子目录，请先检查。");
            total += new FileInfo(existing).Length;
            if (++count > MaximumAttachmentFiles || total > MaximumAttachmentBytes)
                throw new InvalidOperationException("图片附件已达到 512 MB / 4096 文件上限，请先删除部分图片记录。");
        }
        WriteAtomically(path, bytes, overwrite: false);
    }

    private void CleanupUnreferencedAttachments()
    {
        // Cleanup never changes the outcome of an already successful metadata commit.
        try
        {
            if (!Directory.Exists(_attachmentDirectory)) return;
            EnsureNotLink(_attachmentDirectory);
            var retained = _entries.Concat(_undo ?? []).Where(entry => entry.AttachmentName is not null)
                .Select(entry => entry.AttachmentName!).ToHashSet(StringComparer.Ordinal);
            foreach (var path in Directory.EnumerateFiles(_attachmentDirectory, "*.png"))
            {
                var name = Path.GetFileName(path);
                try { ValidateAttachmentName(name); }
                catch (InvalidDataException) { continue; }
                if (!retained.Contains(name)) { EnsureNotLink(path); File.Delete(path); _verifiedAttachments.Remove(name); }
            }
        }
        catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
    }

    private FileStream AcquireDiskLock()
    {
        EnsureNotLink(DirectoryPath);
        if (File.Exists(_lockPath)) EnsureNotLink(_lockPath);
        return new FileStream(_lockPath, FileMode.OpenOrCreate, FileAccess.ReadWrite, FileShare.None);
    }

    private void VerifyDiskSnapshot()
    {
        if (!File.Exists(_metadataPath))
        {
            if (_diskHash is not null || Directory.Exists(_metadataPath))
                throw new InvalidDataException("历史文件被移走或替换，请重新打开应用；现有内容未被覆盖。");
            return;
        }
        var hash = SHA256.HashData(ReadBoundedFile(_metadataPath, MaximumMetadataBytes));
        if (_diskHash is null || !hash.AsSpan().SequenceEqual(_diskHash))
            throw new InvalidDataException("历史文件已被外部修改，请重新打开应用；外部内容未被覆盖。");
    }

    private static byte[] ReadBoundedFile(string path, int maxBytes)
    {
        EnsureNotLink(path);
        using var stream = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read);
        if (stream.Length > maxBytes) throw new InvalidDataException("数据文件超出安全大小上限。");
        var bytes = new byte[checked((int)stream.Length)];
        stream.ReadExactly(bytes);
        return bytes;
    }

    private static void EnsureNotLink(string path)
    {
        if ((File.GetAttributes(path) & FileAttributes.ReparsePoint) != 0)
            throw new InvalidDataException("数据路径包含符号链接或重解析点，已停止访问。");
    }

    private static void WriteAtomically(string destination, byte[] bytes, bool overwrite)
    {
        if (File.Exists(destination)) EnsureNotLink(destination);
        var temporary = Path.Combine(Path.GetDirectoryName(destination)!, ".xclip-" + Guid.NewGuid().ToString("N") + ".tmp");
        try
        {
            using (var stream = new FileStream(temporary, FileMode.CreateNew, FileAccess.Write, FileShare.None))
            {
                stream.Write(bytes);
                stream.Flush(flushToDisk: true);
            }
            File.Move(temporary, destination, overwrite);
        }
        finally
        {
            try { if (File.Exists(temporary)) File.Delete(temporary); }
            catch (Exception exception) when (exception is IOException or UnauthorizedAccessException) { }
        }
    }

    private sealed class HistoryDocument
    {
        public HistoryDocument() { }
        public int SchemaVersion { get; set; }
        public List<ClipboardEntry>? Entries { get; set; }
    }
}
