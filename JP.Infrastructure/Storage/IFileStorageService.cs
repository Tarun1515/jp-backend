namespace JP.Infrastructure.Storage;

/// <summary>A file that has been written to storage.</summary>
/// <param name="RelativePath">
/// Storage-relative path, e.g. <c>school-documents/2026/08/a1b2….pdf</c>.
/// This is what goes in <c>FilePath</c> columns — never an absolute path, so
/// moving to S3 or Blob later does not invalidate stored rows.
/// </param>
/// <param name="OriginalFileName">The name the user uploaded, for display and download.</param>
/// <param name="StoredFileName">The generated name on disk.</param>
/// <param name="SizeKb">Size in kilobytes, matching the <c>FileSizeKb</c> columns.</param>
/// <param name="ContentType">Detected MIME type.</param>
public sealed record StoredFile(
    string RelativePath,
    string OriginalFileName,
    string StoredFileName,
    int SizeKb,
    string ContentType);

/// <summary>
/// File storage behind an interface so the backing store can change.
/// </summary>
/// <remarks>
/// Local disk today. Client question 9 (S3 / Azure Blob / local server) is
/// still open, and this interface is what keeps that decision cheap: swapping
/// implementations touches one DI registration and nothing else.
/// </remarks>
public interface IFileStorageService
{
    /// <summary>
    /// Validates and stores an uploaded file under <paramref name="folder"/>.
    /// </summary>
    /// <param name="content">The upload stream.</param>
    /// <param name="originalFileName">Used for its extension and kept for display.</param>
    /// <param name="folder">Logical folder, e.g. <c>school-documents</c>.</param>
    /// <param name="cancellationToken">Cancellation token.</param>
    /// <exception cref="JP.Core.Exceptions.BusinessRuleException">
    /// The file is too large, or its extension is not allowed.
    /// </exception>
    Task<StoredFile> SaveAsync(
        Stream content,
        string originalFileName,
        string folder,
        CancellationToken cancellationToken = default);

    /// <summary>Opens a stored file for reading. The caller disposes the stream.</summary>
    /// <exception cref="JP.Core.Exceptions.NotFoundException">No such file.</exception>
    Task<Stream> OpenReadAsync(string relativePath, CancellationToken cancellationToken = default);

    /// <summary>Deletes a stored file. Returns false if it was already gone.</summary>
    /// <remarks>
    /// Database rows are soft-deleted, never removed. This exists for genuinely
    /// orphaned blobs — an upload whose transaction rolled back, for example.
    /// </remarks>
    Task<bool> DeleteAsync(string relativePath, CancellationToken cancellationToken = default);

    /// <summary>Whether a stored file exists.</summary>
    bool Exists(string relativePath);
}
