using System.Security.Claims;
using JP.Core.Constants;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Approvals;
using JP.Infrastructure.Repositories;
using JP.Infrastructure.Storage;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Services;

/// <summary>A document being handed back to a caller who is allowed to have it.</summary>
public sealed record DocumentDownload(Stream Content, string FileName, string ContentType);

public interface IDocumentService
{
    Task<long> UploadAsync(long requestId, int documentTypeId, Stream content, string? originalFileName, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<DocumentDownload> DownloadAsync(long documentId, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task VerifyAsync(long documentId, VerifyDocumentRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken);
}

/// <summary>
/// Uploads, downloads and verification of request documents.
/// </summary>
/// <remarks>
/// Every upload is treated as hostile — see <see cref="UploadValidator"/> for
/// the four checks and why each is needed. This class adds the two things the
/// validator cannot know about: the per-type limits come from the database, and
/// the caller must be entitled to the request.
/// </remarks>
internal sealed class DocumentService : IDocumentService
{
    private const string DocumentFolder = "request-documents";

    private readonly IApprovalRepository _approvals;
    private readonly IMasterRepository _masters;
    private readonly IFileStorageService _storage;
    private readonly ILogger<DocumentService> _logger;

    public DocumentService(
        IApprovalRepository approvals,
        IMasterRepository masters,
        IFileStorageService storage,
        ILogger<DocumentService> logger)
    {
        _approvals = approvals;
        _masters = masters;
        _storage = storage;
        _logger = logger;
    }

    public async Task<long> UploadAsync(
        long requestId,
        int documentTypeId,
        Stream content,
        string? originalFileName,
        ClaimsPrincipal caller,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(content);
        ArgumentNullException.ThrowIfNull(caller);

        // ---- 1. may this caller touch this request at all? ------------------
        var detail = await _approvals.GetByIdAsync(requestId, cancellationToken).ConfigureAwait(false)
            ?? throw new NotFoundException("That request was not found.");

        ApprovalService.EnsureCanRead(detail.Header, caller);

        // ---- 2. the limits come from the document type's own row ------------
        //
        // 🔴 Not constants. m_mdm_document_types carries MaxSizeKb and
        // AllowedExtensions per type (2.47) precisely so raising the limit for
        // one document is a data change rather than a deployment.
        var documentType = await _masters.GetDocumentTypeAsync(documentTypeId, cancellationToken)
            .ConfigureAwait(false)
            ?? throw new BusinessRuleException(
                "That document type is not recognised.", ErrorCodes.ValidationFailed);

        if (documentType.RequestTypeId != detail.Header.RequestTypeId)
        {
            throw new BusinessRuleException(
                "That document does not belong on this kind of request.", ErrorCodes.ValidationFailed);
        }

        // ---- 3. read the bytes, bounded ------------------------------------
        //
        // Buffered so the magic bytes can be inspected before anything is
        // written to disk. Capped at the type's own limit plus one byte, so an
        // oversized upload is rejected without reading it all into memory.
        var capBytes = (long)documentType.MaxSizeKb * 1024;
        using var buffer = new MemoryStream();
        var chunk = new byte[81920];
        int read;

        while ((read = await content.ReadAsync(chunk, cancellationToken).ConfigureAwait(false)) > 0)
        {
            buffer.Write(chunk, 0, read);

            if (buffer.Length > capBytes)
            {
                throw new BusinessRuleException(
                    $"That file is larger than the {documentType.MaxSizeKb / 1024.0:0.#} MB limit for this document.",
                    ErrorCodes.ValidationFailed);
            }
        }

        // ---- 4. validate: extension, magic bytes, size, safe name ----------
        var validated = UploadValidator.Validate(
            originalFileName,
            buffer.GetBuffer().AsSpan(0, (int)buffer.Length),
            documentType.AllowedExtensions,
            documentType.MaxSizeKb);

        /*
          ---- 5. 🔴 VIRUS SCANNING HOOK -------------------------------------

          NOTHING SCANS THIS FILE YET. The content has been proved to be a real
          PDF or image rather than a renamed executable, which stops the crude
          attack — but a malicious PDF is still a real PDF and would pass every
          check above.

          When a scanner is chosen (ClamAV daemon, or a cloud scanning API),
          it goes HERE: after validation, before the bytes reach storage, and it
          must be able to reject. Do not move it after SaveAsync — a file on
          disk is a file that can be served.

              await _scanner.ScanAsync(buffer, cancellationToken);   // throws on detection

          Tracked in PROJECT_MEMORY known gaps.
        */

        // ---- 6. store under a generated name -------------------------------
        buffer.Position = 0;

        var stored = await _storage
            .SaveAsync(buffer, validated.StorageFileName, DocumentFolder, cancellationToken)
            .ConfigureAwait(false);

        // ---- 7. record it. The procedure bumps Version, never overwrites ----
        var result = await _approvals.SaveDocumentAsync(
            requestId,
            documentTypeId,

            // The storage-relative path, not an absolute one — moving to S3
            // later must not invalidate stored rows.
            stored.RelativePath,

            // The ORIGINAL name, for display only. It never touches a path.
            validated.OriginalFileName,
            validated.SizeKb,

            // The SNIFFED type, not the Content-Type header the client sent.
            validated.MimeType,
            caller.GetUserId(),
            cancellationToken).ConfigureAwait(false);

        result.EnsureSuccess();

        _logger.LogInformation(
            "Document {DocumentId} ({DocumentTypeCode}) uploaded to request {RequestId} by user {UserId}: " +
            "{SizeKb} KB, sniffed as {MimeType}.",
            result.Id, documentType.Code, requestId, caller.GetUserId(), validated.SizeKb, validated.MimeType);

        return result.Id ?? 0;
    }

    /// <summary>
    /// Streams a document to a caller who is entitled to it.
    /// </summary>
    /// <remarks>
    /// 🔴 The access check is the whole point. Documents are stored under
    /// generated names in a folder the web server does not serve, so the ONLY
    /// route to one is this method — and it refuses anyone who neither owns the
    /// request nor holds the verification permission.
    ///
    /// Serving these from a static path would make every uploaded certificate
    /// reachable by anyone who could guess or leak a URL, with no audit and no
    /// revocation.
    /// </remarks>
    public async Task<DocumentDownload> DownloadAsync(
        long documentId,
        ClaimsPrincipal caller,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        var (document, header) = await FindDocumentAsync(documentId, cancellationToken).ConfigureAwait(false);

        // Owner, or an admin with the verification permission. Nothing else.
        var isAdmin = caller.GetUserType() == Core.Enums.UserType.Admin;
        var required = header.RequestTypeId == 2
            ? AppConstants.PermissionCodes.VerificationTeacher
            : AppConstants.PermissionCodes.VerificationSchool;

        if (!(isAdmin && caller.HasPermission(required)))
        {
            // Falls back to the same ownership rule the request itself uses,
            // and throws NotFound rather than Forbidden — confirming a document
            // exists but is not yours is itself a leak.
            ApprovalService.EnsureCanRead(header, caller);
        }

        var stream = await _storage.OpenReadAsync(document.FilePath, cancellationToken).ConfigureAwait(false);

        _logger.LogInformation(
            "Document {DocumentId} on request {RequestId} served to user {UserId}.",
            documentId, header.RequestId, caller.GetUserId());

        return new DocumentDownload(stream, document.FileName, document.MimeType);
    }

    public async Task VerifyAsync(
        long documentId,
        VerifyDocumentRequest request,
        ClaimsPrincipal caller,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(caller);

        var (_, header) = await FindDocumentAsync(documentId, cancellationToken).ConfigureAwait(false);

        var required = header.RequestTypeId == 2
            ? AppConstants.PermissionCodes.VerificationTeacher
            : AppConstants.PermissionCodes.VerificationSchool;

        if (caller.GetUserType() != Core.Enums.UserType.Admin || !caller.HasPermission(required))
        {
            throw new ForbiddenException("You do not have permission to verify this document.");
        }

        var result = await _approvals.VerifyDocumentAsync(
            documentId, request.IsVerified, caller.GetUserId(),
            request.RejectionReasonId, request.Remarks, cancellationToken).ConfigureAwait(false);

        result.EnsureSuccess();
    }

    /// <summary>
    /// Finds a document and the request it belongs to.
    /// </summary>
    /// <remarks>
    /// There is no "get document by id" procedure, and adding one that returned
    /// a file path without its request would be a footgun — the path is only
    /// safe to act on alongside the ownership information. So this walks from
    /// the request, which is the only context in which a document means
    /// anything.
    /// </remarks>
    private async Task<(RequestDocumentDto Document, ApprovalRequestListItemDto Header)> FindDocumentAsync(
        long documentId,
        CancellationToken cancellationToken)
    {
        var requestId = await _approvals.GetRequestIdForDocumentAsync(documentId, cancellationToken)
            .ConfigureAwait(false)
            ?? throw new NotFoundException("That document was not found.");

        var detail = await _approvals.GetByIdAsync(requestId, cancellationToken).ConfigureAwait(false)
            ?? throw new NotFoundException("That document was not found.");

        var document = detail.Documents.FirstOrDefault(d => d.DocumentId == documentId)
            ?? throw new NotFoundException("That document was not found.");

        return (document, detail.Header);
    }
}
