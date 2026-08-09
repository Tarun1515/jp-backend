using JP.Core.Common;
using JP.Domain.Approvals;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/// <summary>
/// Request documents: upload, download, verify.
/// </summary>
/// <remarks>
/// Every upload is treated as hostile — extension AND magic bytes, per-type
/// size and extension limits read from the database, a generated storage name,
/// and path-traversal rejection. See <c>UploadValidator</c> for why each check
/// exists and what it stops on its own.
/// </remarks>
[ApiController]
[Route("api/documents")]
[Authorize]
public sealed class DocumentsController : ControllerBase
{
    private readonly IDocumentService _documents;

    public DocumentsController(IDocumentService documents)
    {
        _documents = documents;
    }

    /// <summary>Upload a document against a request.</summary>
    /// <remarks>
    /// The size limit is NOT declared here. It comes from the document type's
    /// own <c>MaxSizeKb</c> (2.47), so raising it for one document is a data
    /// change. The framework limit below is only a backstop against a client
    /// streaming forever — the real answer comes from the database.
    /// </remarks>
    [HttpPost("upload")]
    [RequestSizeLimit(20 * 1024 * 1024)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    public async Task<IActionResult> Upload(
        [FromForm] long requestId,
        [FromForm] int documentTypeId,
        IFormFile file,
        CancellationToken cancellationToken)
    {
        if (file is null || file.Length == 0)
        {
            return BadRequest(ApiResponse.Failure("Choose a file to upload."));
        }

        await using var stream = file.OpenReadStream();

        var documentId = await _documents
            .UploadAsync(requestId, documentTypeId, stream, file.FileName, User, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(new { documentId }, "Document uploaded."));
    }

    /// <summary>
    /// Streams a document to a caller entitled to it.
    /// </summary>
    /// <remarks>
    /// 🔴 The ONLY route to an uploaded file. Documents are stored under
    /// generated names outside any statically served folder, so there is no URL
    /// to guess and no way to reach one without passing the access check in the
    /// service.
    ///
    /// A caller who is not entitled gets 404, not 403 — confirming that a
    /// document exists but belongs to someone else is itself a disclosure.
    /// </remarks>
    [HttpGet("{id:long}")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Download(long id, CancellationToken cancellationToken)
    {
        var download = await _documents.DownloadAsync(id, User, cancellationToken).ConfigureAwait(false);

        return File(download.Content, download.ContentType, download.FileName);
    }

    /// <summary>Verify or reject one document. Requires the verification permission.</summary>
    [HttpPost("{id:long}/verify")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> Verify(
        long id,
        [FromBody] VerifyDocumentRequest request,
        CancellationToken cancellationToken)
    {
        await _documents.VerifyAsync(id, request, User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(request.IsVerified ? "Document verified." : "Document rejected."));
    }
}
