using System.ComponentModel.DataAnnotations;

namespace JP.Infrastructure.Storage;

/// <summary>File storage configuration, bound from the <c>FileStorage</c> section.</summary>
public sealed class FileStorageOptions
{
    public const string SectionName = "FileStorage";

    /// <summary>
    /// Root directory for uploads. Relative paths resolve against the
    /// application's content root. Must be outside wwwroot — files are served
    /// through an authorised endpoint, never as static content, or a document
    /// URL would be readable by anyone who guessed it.
    /// </summary>
    [Required]
    public string RootPath { get; set; } = "App_Data/uploads";

    /// <summary>
    /// Ceiling across all upload types. Per-document-type limits come from
    /// <c>m_mdm_document_types.MaxSizeKb</c> and are checked on top of this.
    /// </summary>
    [Range(1, 102_400)]
    public int MaxFileSizeKb { get; set; } = 10_240;

    /// <summary>
    /// Allowed extensions, lowercase and dotted. An allowlist, deliberately —
    /// a blocklist of dangerous types is always incomplete.
    /// </summary>
    public string[] AllowedExtensions { get; set; } =
    [
        ".pdf", ".jpg", ".jpeg", ".png", ".webp", ".doc", ".docx",
    ];
}
