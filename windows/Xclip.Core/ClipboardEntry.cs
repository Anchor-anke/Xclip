namespace Xclip.Core;

public enum ClipboardKind { Text, Image, Files }

public sealed record ClipboardEntry
{
    public Guid Id { get; init; }
    public ClipboardKind Kind { get; init; }
    public string Content { get; init; } = "";
    public DateTimeOffset CreatedAt { get; init; }
    public bool IsFavorite { get; init; }
    public bool IsPinned { get; init; }
    public string? SourceApp { get; init; }
    public string? AttachmentName { get; init; }
    public string[] Files { get; init; } = [];
}
