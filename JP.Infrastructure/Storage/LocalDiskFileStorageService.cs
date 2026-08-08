using JP.Core.Constants;
using JP.Core.Exceptions;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Storage;

/// <summary>
/// Stores uploads on local disk under a configured root.
/// </summary>
/// <remarks>
/// Files are given a generated GUID name and grouped into year/month folders.
/// The generated name matters for more than tidiness: serving a file back
/// under a user-supplied name is how a "resume.pdf.html" ends up executing in
/// somebody's browser.
/// <para>
/// Every path derived from caller input is resolved to an absolute path and
/// checked to be inside the root before any I/O happens, so a
/// <c>../../appsettings.json</c> cannot escape the storage directory.
/// </para>
/// </remarks>
public sealed class LocalDiskFileStorageService : IFileStorageService
{
    private static readonly Dictionary<string, string> ContentTypes =
        new(StringComparer.OrdinalIgnoreCase)
        {
            [".pdf"] = "application/pdf",
            [".jpg"] = "image/jpeg",
            [".jpeg"] = "image/jpeg",
            [".png"] = "image/png",
            [".webp"] = "image/webp",
            [".doc"] = "application/msword",
            [".docx"] = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        };

    private readonly FileStorageOptions _options;
    private readonly ILogger<LocalDiskFileStorageService> _logger;
    private readonly string _rootPath;

    public LocalDiskFileStorageService(
        IOptions<FileStorageOptions> options,
        IHostEnvironment environment,
        ILogger<LocalDiskFileStorageService> logger)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(environment);

        _options = options.Value;
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));

        var configured = _options.RootPath;
        _rootPath = Path.IsPathRooted(configured)
            ? Path.GetFullPath(configured)
            : Path.GetFullPath(Path.Combine(environment.ContentRootPath, configured));

        Directory.CreateDirectory(_rootPath);
    }

    public async Task<StoredFile> SaveAsync(
        Stream content,
        string originalFileName,
        string folder,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(content);

        if (string.IsNullOrWhiteSpace(originalFileName))
        {
            throw new ArgumentException("A file name is required.", nameof(originalFileName));
        }

        var extension = Path.GetExtension(originalFileName).ToLowerInvariant();

        if (string.IsNullOrEmpty(extension) ||
            !_options.AllowedExtensions.Contains(extension, StringComparer.OrdinalIgnoreCase))
        {
            throw new BusinessRuleException(
                $"Files of type '{extension}' are not accepted. Allowed: {string.Join(", ", _options.AllowedExtensions)}.",
                ErrorCodes.FileTypeNotAllowed);
        }

        // Checked before writing where the length is known, and again after,
        // because a chunked upload reports no length up front.
        if (content.CanSeek && content.Length > _options.MaxFileSizeKb * 1024L)
        {
            throw new BusinessRuleException(
                $"This file is larger than the {_options.MaxFileSizeKb} KB limit.",
                ErrorCodes.FileTooLarge);
        }

        var storedFileName = $"{Guid.NewGuid():N}{extension}";
        var relativeFolder = BuildDatedFolder(folder);
        var relativePath = $"{relativeFolder}/{storedFileName}";
        var absolutePath = ResolveWithinRoot(relativePath);

        Directory.CreateDirectory(Path.GetDirectoryName(absolutePath)!);

        long bytesWritten;
        try
        {
            await using var destination = new FileStream(
                absolutePath, FileMode.CreateNew, FileAccess.Write, FileShare.None,
                bufferSize: 81_920, useAsync: true);

            await content.CopyToAsync(destination, cancellationToken).ConfigureAwait(false);
            bytesWritten = destination.Length;
        }
        catch (OperationCanceledException)
        {
            TryDelete(absolutePath);
            throw;
        }

        if (bytesWritten > _options.MaxFileSizeKb * 1024L)
        {
            // Only knowable now for a stream that could not report its length.
            TryDelete(absolutePath);
            throw new BusinessRuleException(
                $"This file is larger than the {_options.MaxFileSizeKb} KB limit.",
                ErrorCodes.FileTooLarge);
        }

        _logger.LogInformation(
            "Stored upload {RelativePath} ({SizeKb} KB)", relativePath, bytesWritten / 1024);

        return new StoredFile(
            RelativePath: relativePath,
            OriginalFileName: Path.GetFileName(originalFileName),
            StoredFileName: storedFileName,
            SizeKb: (int)Math.Ceiling(bytesWritten / 1024d),
            ContentType: ContentTypes.TryGetValue(extension, out var contentType)
                ? contentType
                : "application/octet-stream");
    }

    public Task<Stream> OpenReadAsync(string relativePath, CancellationToken cancellationToken = default)
    {
        var absolutePath = ResolveWithinRoot(relativePath);

        if (!File.Exists(absolutePath))
        {
            throw new NotFoundException("The requested file was not found.");
        }

        Stream stream = new FileStream(
            absolutePath, FileMode.Open, FileAccess.Read, FileShare.Read,
            bufferSize: 81_920, useAsync: true);

        return Task.FromResult(stream);
    }

    public Task<bool> DeleteAsync(string relativePath, CancellationToken cancellationToken = default)
    {
        var absolutePath = ResolveWithinRoot(relativePath);

        if (!File.Exists(absolutePath))
        {
            return Task.FromResult(false);
        }

        File.Delete(absolutePath);
        _logger.LogInformation("Deleted stored file {RelativePath}", relativePath);
        return Task.FromResult(true);
    }

    public bool Exists(string relativePath) => File.Exists(ResolveWithinRoot(relativePath));

    /// <summary>
    /// Turns a logical folder into a dated one: <c>documents</c> becomes
    /// <c>documents/2026/08</c>, which keeps any single directory from growing
    /// to the point where enumeration crawls.
    /// </summary>
    private static string BuildDatedFolder(string folder)
    {
        var safeFolder = SanitiseFolder(folder);
        var now = DateTime.UtcNow;
        return $"{safeFolder}/{now:yyyy}/{now:MM}";
    }

    /// <summary>Strips everything that could redirect a path out of its folder.</summary>
    private static string SanitiseFolder(string folder)
    {
        if (string.IsNullOrWhiteSpace(folder))
        {
            return "misc";
        }

        var segments = folder
            .Replace('\\', '/')
            .Split('/', StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries)
            .Where(segment => segment is not "." and not "..")
            .Select(segment => new string(segment
                .Where(c => char.IsLetterOrDigit(c) || c is '-' or '_')
                .ToArray()))
            .Where(segment => segment.Length > 0)
            .ToArray();

        return segments.Length == 0 ? "misc" : string.Join('/', segments);
    }

    /// <summary>
    /// Resolves a storage-relative path to an absolute one, refusing anything
    /// that lands outside the configured root.
    /// </summary>
    private string ResolveWithinRoot(string relativePath)
    {
        if (string.IsNullOrWhiteSpace(relativePath))
        {
            throw new ArgumentException("A file path is required.", nameof(relativePath));
        }

        var combined = Path.GetFullPath(Path.Combine(_rootPath, relativePath.Replace('/', Path.DirectorySeparatorChar)));

        // Compare against the root WITH a trailing separator, otherwise a
        // sibling directory named "uploads-public" would pass a naive
        // StartsWith("...\uploads") check.
        var rootWithSeparator = _rootPath.EndsWith(Path.DirectorySeparatorChar)
            ? _rootPath
            : _rootPath + Path.DirectorySeparatorChar;

        if (!combined.StartsWith(rootWithSeparator, StringComparison.OrdinalIgnoreCase))
        {
            _logger.LogWarning("Blocked a file path that resolved outside storage: {RelativePath}", relativePath);
            throw new ForbiddenException("That file path is not valid.");
        }

        return combined;
    }

    private void TryDelete(string absolutePath)
    {
        try
        {
            if (File.Exists(absolutePath))
            {
                File.Delete(absolutePath);
            }
        }
        catch (IOException ex)
        {
            // Best effort: the upload already failed, and failing to clean up
            // after it must not replace the real error.
            _logger.LogWarning(ex, "Could not remove partial upload {Path}", absolutePath);
        }
    }
}
