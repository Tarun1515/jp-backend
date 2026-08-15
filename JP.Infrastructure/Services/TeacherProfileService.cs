using System.Security.Claims;
using JP.Core.Constants;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Teachers;
using JP.Infrastructure.Repositories;
using JP.Infrastructure.Storage;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Services;

public interface ITeacherProfileService
{
    Task<TeacherProfileDto> GetProfileAsync(ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task UpdateProfileAsync(UpdateTeacherProfileRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task SavePhotoAsync(Stream content, string fileName, ClaimsPrincipal caller, CancellationToken cancellationToken);
    Task SaveResumeAsync(Stream content, string fileName, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<long> SaveDocumentAsync(int documentTypeId, Stream content, string fileName, ClaimsPrincipal caller, CancellationToken cancellationToken);
    Task DeleteDocumentAsync(long documentId, ClaimsPrincipal caller, CancellationToken cancellationToken);

    /// <summary>
    /// Opens one of the CALLER'S OWN files — their photo, their resume, one of
    /// their documents.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 Uploads live under App_Data, which is not served statically and must
    /// never be: that root holds every resume in the system. So the bytes are
    /// streamed here, and the teacher is resolved from the token — there is no
    /// parameter for whose file it is.
    /// </para>
    /// <para>
    /// ⚠️ This is NOT how a school reads a resume. That is
    /// <c>GET /api/teachers/{uid}/contact</c>, gated on the teacher having
    /// applied or accepted an invite (2.56, LOCKED). A school has no
    /// t_app_teachers row, so every one of these returns nothing for them.
    /// </para>
    /// </remarks>
    Task<(Stream Content, string ContentType)> OpenPhotoAsync(ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<(Stream Content, string ContentType)> OpenResumeAsync(ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<(Stream Content, string ContentType)> OpenDocumentAsync(long documentId, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task SaveSubjectsAsync(SaveIdSetRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken);
    Task SaveClassLevelsAsync(SaveIdSetRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken);
    Task SaveSkillsAsync(SaveIdSetRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken);
    Task SaveLanguagesAsync(SaveLanguagesRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken);
    Task SavePreferredLocationsAsync(SavePreferredLocationsRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<long> SaveExperienceAsync(long? id, SaveExperienceRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken);
    Task DeleteExperienceAsync(long id, ClaimsPrincipal caller, CancellationToken cancellationToken);
}

/// <summary>
/// The teacher's own profile.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 EVERY METHOD TAKES THE TEACHER FROM THE TOKEN. There is no overload that
/// accepts a teacher id, no lookup that resolves one on a caller's behalf, and
/// no request type in <c>JP.Domain.Teachers</c> that carries one.
/// </para>
/// <para>
/// Phase 3D made "edit somebody else's profile" impossible to EXPRESS at the
/// database layer — verified against sys.parameters. Accepting an id here would
/// hand that back, which is why this service resolves nothing and simply passes
/// <c>caller.GetUserUid()</c> through.
/// </para>
/// </remarks>
internal sealed class TeacherProfileService : ITeacherProfileService
{
    /*
      ⚠️ Photo and resume have no m_mdm_document_types row — that master is
      keyed to approval-request documents. Their limits are here; their CHECKING
      is the same UploadValidator every other upload uses (2.48).
    */
    private const string PhotoExtensions = "jpg,jpeg,png";
    private const int PhotoMaxSizeKb = 5120;

    private const string ResumeExtensions = "pdf";
    private const int ResumeMaxSizeKb = 5120;

    private readonly ITeacherRepository _teachers;
    private readonly IMasterRepository _masters;
    private readonly IFileStorageService _storage;
    private readonly ILogger<TeacherProfileService> _logger;

    public TeacherProfileService(
        ITeacherRepository teachers,
        IMasterRepository masters,
        IFileStorageService storage,
        ILogger<TeacherProfileService> logger)
    {
        _teachers = teachers;
        _masters = masters;
        _storage = storage;
        _logger = logger;
    }

    public async Task<TeacherProfileDto> GetProfileAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        return await _teachers.GetProfileAsync(caller.GetUserUid(), cancellationToken).ConfigureAwait(false)
               ?? throw new NotFoundException(
                   "Your profile has not been created yet. Sign out and back in — if that does not help, contact us.");
    }

    public async Task UpdateProfileAsync(
        UpdateTeacherProfileRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(caller);

        (await _teachers.UpdateProfileAsync(caller.GetUserUid(), request, cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();
    }

    public async Task SavePhotoAsync(
        Stream content, string fileName, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        var path = await StoreAsync(content, fileName, "teacher-photos", PhotoExtensions, PhotoMaxSizeKb, cancellationToken)
            .ConfigureAwait(false);

        (await _teachers.SavePhotoAsync(caller.GetUserUid(), path, cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();
    }

    /// <summary>
    /// Stores a teacher's resume.
    /// </summary>
    /// <remarks>
    /// 🔴 The path this writes is returned to a school ONLY by
    /// <c>GET /api/teachers/{uid}/contact</c>, and only when the teacher has
    /// consented (2.56). A resume is a contact detail — it carries an email and
    /// a mobile in its first three lines — so there is deliberately no endpoint
    /// that serves it alongside the browse view.
    /// </remarks>
    public async Task SaveResumeAsync(
        Stream content, string fileName, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        var path = await StoreAsync(content, fileName, "teacher-resumes", ResumeExtensions, ResumeMaxSizeKb, cancellationToken)
            .ConfigureAwait(false);

        (await _teachers.SaveResumeAsync(caller.GetUserUid(), path, cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();
    }

    public async Task<(Stream Content, string ContentType)> OpenPhotoAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        var path = await _teachers.GetPhotoPathAsync(caller.GetUserUid(), cancellationToken)
                       .ConfigureAwait(false)
                   ?? throw new NotFoundException("You have not added a photo yet.");

        return (await _storage.OpenReadAsync(path, cancellationToken).ConfigureAwait(false), ContentTypeFor(path));
    }

    public async Task<(Stream Content, string ContentType)> OpenResumeAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        var path = await _teachers.GetResumePathAsync(caller.GetUserUid(), cancellationToken)
                       .ConfigureAwait(false)
                   ?? throw new NotFoundException("You have not uploaded a resume yet.");

        return (await _storage.OpenReadAsync(path, cancellationToken).ConfigureAwait(false), ContentTypeFor(path));
    }

    public async Task<(Stream Content, string ContentType)> OpenDocumentAsync(
        long documentId, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        // 🔴 A document id belonging to another teacher resolves to nothing —
        // the procedure matches it against the teacher the TOKEN resolves to.
        // 404, not 403: a different status would confirm that it exists.
        var path = await _teachers.GetDocumentPathAsync(documentId, caller.GetUserUid(), cancellationToken)
                       .ConfigureAwait(false)
                   ?? throw new NotFoundException("That document was not found.");

        return (await _storage.OpenReadAsync(path, cancellationToken).ConfigureAwait(false), ContentTypeFor(path));
    }

    /// <summary>
    /// The content type, from the extension the upload validator already allowed.
    /// </summary>
    /// <remarks>
    /// ⚠️ Only what the validators permit is mapped; anything else is served as
    /// a byte stream rather than guessed at. A stored file cannot have another
    /// extension — UploadValidator gave it its name — so a surprise here means
    /// something else is wrong, and the conservative answer is the right one.
    /// </remarks>
    private static string ContentTypeFor(string path) =>
        Path.GetExtension(path).ToLowerInvariant() switch
        {
            ".jpg" or ".jpeg" => "image/jpeg",
            ".png" => "image/png",
            ".pdf" => "application/pdf",
            ".doc" => "application/msword",
            ".docx" => "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
            _ => "application/octet-stream",
        };

    public async Task<long> SaveDocumentAsync(
        int documentTypeId, Stream content, string fileName, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        // 🔴 The limits come from the document type's own row (2.47), not from
        // constants — raising the cap for degree certificates is a data change.
        var type = await _masters.GetDocumentTypeAsync(documentTypeId, cancellationToken).ConfigureAwait(false)
            ?? throw new BusinessRuleException("That document type is not recognised.", ErrorCodes.ValidationFailed);

        var (path, validated) = await StoreWithMetadataAsync(
            content, fileName, "teacher-documents", type.AllowedExtensions, type.MaxSizeKb, cancellationToken)
            .ConfigureAwait(false);

        var result = await _teachers.SaveDocumentAsync(
            caller.GetUserUid(), documentTypeId, path, validated.OriginalFileName,
            validated.SizeKb, validated.MimeType, cancellationToken).ConfigureAwait(false);

        result.EnsureSuccess();

        return result.Id ?? 0;
    }

    public async Task DeleteDocumentAsync(long documentId, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        (await _teachers.DeleteDocumentAsync(caller.GetUserUid(), documentId, cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();
    }

    // ---- the five full-set syncs -------------------------------------------

    public async Task SaveSubjectsAsync(SaveIdSetRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        (await _teachers.SaveSubjectsAsync(caller.GetUserUid(), request.Ids, cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();
    }

    public async Task SaveClassLevelsAsync(SaveIdSetRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        (await _teachers.SaveClassLevelsAsync(caller.GetUserUid(), request.Ids, cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();
    }

    public async Task SaveSkillsAsync(SaveIdSetRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        (await _teachers.SaveSkillsAsync(caller.GetUserUid(), request.Ids, cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();
    }

    public async Task SaveLanguagesAsync(SaveLanguagesRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        (await _teachers.SaveLanguagesAsync(caller.GetUserUid(), request.Languages, cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();
    }

    public async Task SavePreferredLocationsAsync(SavePreferredLocationsRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        (await _teachers.SavePreferredLocationsAsync(caller.GetUserUid(), request.Locations, cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();
    }

    // ---- experiences: entities -----------------------------------------------

    public async Task<long> SaveExperienceAsync(
        long? id, SaveExperienceRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        /*
          🔴 The id comes from the ROUTE, and that is safe because the procedure
          checks it against the teacher the token resolved to — another
          teacher's row answers NOT_FOUND, exactly as a nonexistent one does
          (2.54). This layer does not look the row up first; doing so would be a
          second check to keep in step with the first.
        */
        var result = await _teachers.SaveExperienceAsync(caller.GetUserUid(), id, request, cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();

        return result.Id ?? 0;
    }

    public async Task DeleteExperienceAsync(long id, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        (await _teachers.DeleteExperienceAsync(caller.GetUserUid(), id, cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();
    }

    // ---- uploads: one path, the 2D hardening --------------------------------

    private async Task<string> StoreAsync(
        Stream content, string fileName, string folder, string extensions, int maxSizeKb,
        CancellationToken cancellationToken)
    {
        var (path, _) = await StoreWithMetadataAsync(content, fileName, folder, extensions, maxSizeKb, cancellationToken)
            .ConfigureAwait(false);

        return path;
    }

    private async Task<(string Path, ValidatedUpload Validated)> StoreWithMetadataAsync(
        Stream content, string fileName, string folder, string extensions, int maxSizeKb,
        CancellationToken cancellationToken)
    {
        var capBytes = (long)maxSizeKb * 1024;
        using var buffer = new MemoryStream();
        var chunk = new byte[81920];
        int read;

        // Bounded read: an oversized upload is rejected without being held
        // whole in memory.
        while ((read = await content.ReadAsync(chunk, cancellationToken).ConfigureAwait(false)) > 0)
        {
            buffer.Write(chunk, 0, read);

            if (buffer.Length > capBytes)
            {
                throw new BusinessRuleException(
                    $"That file is larger than the {maxSizeKb / 1024.0:0.#} MB limit.",
                    ErrorCodes.ValidationFailed);
            }
        }

        // 🔴 Extension, magic bytes, size, generated name — the same validator
        // as every other upload in the system (2.48).
        var validated = UploadValidator.Validate(
            fileName,
            buffer.GetBuffer().AsSpan(0, (int)buffer.Length),
            extensions,
            maxSizeKb);

        /*
          ⚠️ The virus-scanning hook belongs HERE — after validation, before
          storage, able to reject (G13). A malicious PDF is a real PDF and passes
          every check above. Do not move it below SaveAsync: a file on disk is a
          file that can be served.
        */

        buffer.Position = 0;

        var stored = await _storage
            .SaveAsync(buffer, validated.StorageFileName, folder, cancellationToken)
            .ConfigureAwait(false);

        return (stored.RelativePath, validated);
    }
}
