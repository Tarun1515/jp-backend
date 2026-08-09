using JP.Core.Constants;
using JP.Core.Exceptions;

namespace JP.Infrastructure.Storage;

/// <summary>
/// What a validated upload turned out to be.
/// </summary>
public sealed record ValidatedUpload
{
    /// <summary>The generated storage name. Never anything the client sent.</summary>
    public string StorageFileName { get; init; } = string.Empty;

    /// <summary>The client's filename, sanitised, kept as metadata only.</summary>
    public string OriginalFileName { get; init; } = string.Empty;

    public string Extension { get; init; } = string.Empty;
    public string MimeType { get; init; } = string.Empty;
    public int SizeKb { get; init; }
}

/// <summary>
/// Treats every upload as hostile.
/// </summary>
/// <remarks>
/// <para>
/// An upload endpoint is the one place a stranger hands the server a file and
/// asks it to keep it. Four separate things have to be true, and each one
/// exists because the others are individually bypassable:
/// </para>
/// <list type="number">
///   <item>
///     <b>The extension is allowed</b> — read from the document type's own
///     <c>AllowedExtensions</c>, never a constant here.
///   </item>
///   <item>
///     <b>The CONTENT matches</b> — magic-byte sniffing. An extension check
///     alone passes a .exe renamed to .pdf, which is the entire attack.
///   </item>
///   <item>
///     <b>The size is within the type's limit</b> — again from the seeded row.
///   </item>
///   <item>
///     <b>The stored name is generated</b> — a GUID. The client's filename is
///     never used to build a path, so <c>../../web.config</c> has nowhere to go.
///   </item>
/// </list>
/// </remarks>
public static class UploadValidator
{
    /// <summary>
    /// Leading bytes that identify the formats this platform accepts.
    /// </summary>
    /// <remarks>
    /// Deliberately a small allow-list rather than a general sniffing library:
    /// the platform accepts certificates and photographs, and every format
    /// outside this table is something nobody needs to upload.
    ///
    /// JPEG is matched on the first two bytes because the third varies across
    /// encoders (FFE0 JFIF, FFE1 Exif, FFDB raw). Matching all three would
    /// reject valid photographs from ordinary phones.
    /// </remarks>
    private static readonly Dictionary<string, (byte[] Magic, string Mime)[]> Signatures = new(StringComparer.OrdinalIgnoreCase)
    {
        ["pdf"] = [([0x25, 0x50, 0x44, 0x46], "application/pdf")],                   // %PDF
        ["png"] = [([0x89, 0x50, 0x4E, 0x47], "image/png")],                          // .PNG
        ["jpg"] = [([0xFF, 0xD8, 0xFF], "image/jpeg")],
        ["jpeg"] = [([0xFF, 0xD8, 0xFF], "image/jpeg")],
    };

    /// <summary>
    /// Validates an upload and produces its storage identity.
    /// </summary>
    /// <param name="originalFileName">Whatever the client called it. Untrusted.</param>
    /// <param name="content">The bytes. Read, not trusted.</param>
    /// <param name="allowedExtensions">Comma-separated, from m_mdm_document_types.</param>
    /// <param name="maxSizeKb">From m_mdm_document_types.</param>
    /// <exception cref="BusinessRuleException">The upload is not acceptable.</exception>
    public static ValidatedUpload Validate(
        string? originalFileName,
        ReadOnlySpan<byte> content,
        string allowedExtensions,
        int maxSizeKb)
    {
        if (string.IsNullOrWhiteSpace(originalFileName))
        {
            throw new BusinessRuleException("The file has no name.", ErrorCodes.ValidationFailed);
        }

        // ---- 1. the filename is never used as a path ------------------------
        //
        // Path.GetFileName strips any directory the client tried to smuggle in,
        // so "../../../web.config" becomes "web.config". The check afterwards
        // is belt and braces: if anything path-like survives, refuse rather
        // than continue with a value that surprised us.
        var safeName = Path.GetFileName(originalFileName.Trim());

        if (string.IsNullOrWhiteSpace(safeName)
            || safeName.Contains("..", StringComparison.Ordinal)
            || safeName.Contains('/', StringComparison.Ordinal)
            || safeName.Contains('\\', StringComparison.Ordinal)
            || safeName.IndexOfAny(Path.GetInvalidFileNameChars()) >= 0)
        {
            throw new BusinessRuleException(
                "That file name is not acceptable. Rename the file and try again.",
                ErrorCodes.ValidationFailed);
        }

        // ---- 2. size, from the document type's own limit --------------------
        if (content.Length == 0)
        {
            throw new BusinessRuleException("That file is empty.", ErrorCodes.ValidationFailed);
        }

        // Round up: a 1500-byte file is 2 KB of a 2048 KB allowance, not 1.
        var sizeKb = (int)Math.Ceiling(content.Length / 1024.0);

        if (maxSizeKb > 0 && sizeKb > maxSizeKb)
        {
            throw new BusinessRuleException(
                $"That file is larger than the {maxSizeKb / 1024.0:0.#} MB limit for this document.",
                ErrorCodes.ValidationFailed);
        }

        // ---- 3. the extension is on the type's allow-list -------------------
        var extension = Path.GetExtension(safeName).TrimStart('.').ToLowerInvariant();

        if (string.IsNullOrEmpty(extension))
        {
            throw new BusinessRuleException(
                "That file has no extension, so its type cannot be checked.",
                ErrorCodes.ValidationFailed);
        }

        var allowed = (allowedExtensions ?? string.Empty)
            .Split(',', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Select(e => e.TrimStart('.').ToLowerInvariant())
            .ToHashSet(StringComparer.OrdinalIgnoreCase);

        if (allowed.Count == 0 || !allowed.Contains(extension))
        {
            throw new BusinessRuleException(
                $"That file type is not accepted for this document. Allowed: {allowedExtensions}.",
                ErrorCodes.ValidationFailed);
        }

        // ---- 4. 🔴 THE CONTENT MUST MATCH THE EXTENSION ---------------------
        //
        // The check the other three cannot substitute for. Without it, a .exe
        // renamed to .pdf passes everything above.
        if (!Signatures.TryGetValue(extension, out var candidates))
        {
            // On the allow-list but with no signature defined. Refuse rather
            // than wave it through — an extension nobody taught us to verify is
            // an extension we cannot verify.
            throw new BusinessRuleException(
                "That file type cannot be verified and was not accepted.",
                ErrorCodes.ValidationFailed);
        }

        // A plain loop rather than LINQ: ReadOnlySpan<byte> is a ref struct and
        // cannot be captured by a lambda. The comparison itself is identical.
        string? sniffedMime = null;

        foreach (var candidate in candidates)
        {
            if (StartsWith(content, candidate.Magic))
            {
                sniffedMime = candidate.Mime;
                break;
            }
        }

        if (sniffedMime is null)
        {
            throw new BusinessRuleException(
                "That file's contents do not match its extension. Upload the original file rather than a renamed one.",
                ErrorCodes.ValidationFailed);
        }

        // ---- 5. the stored name is ours ------------------------------------
        //
        // A GUID. Nothing the client sent reaches the filesystem, so there is
        // no traversal to defend against at the storage layer and no way to
        // guess another tenant's file by name.
        var storageFileName = $"{Guid.NewGuid():N}.{extension}";

        return new ValidatedUpload
        {
            StorageFileName = storageFileName,
            OriginalFileName = safeName,
            Extension = extension,

            // The sniffed type, NOT the Content-Type header — that is client
            // input and is trusted by nothing here.
            MimeType = sniffedMime,
            SizeKb = sizeKb,
        };
    }

    private static bool StartsWith(ReadOnlySpan<byte> content, byte[] magic)
    {
        if (content.Length < magic.Length)
        {
            return false;
        }

        for (var i = 0; i < magic.Length; i++)
        {
            if (content[i] != magic[i])
            {
                return false;
            }
        }

        return true;
    }
}
