using System.Security.Claims;
using JP.Core.Constants;
using JP.Core.Enums;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Schools;
using JP.Infrastructure.Repositories;
using JP.Infrastructure.Storage;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Services;

public interface ISchoolProfileService
{
    Task<SchoolProfileDto> GetProfileAsync(ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<SchoolPublicProfileDto> GetPublicProfileAsync(Guid schoolUid, CancellationToken cancellationToken);

    Task UpdateProfileAsync(UpdateSchoolProfileRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task SaveLogoAsync(Stream content, string fileName, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<long> AddPhotoAsync(Stream content, string fileName, long? branchId, string? caption, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task ReorderPhotosAsync(ReorderPhotosRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task DeletePhotoAsync(long photoId, ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task SaveFacilitiesAsync(SaveFacilitiesRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken);

    /// <summary>The caller's own school id, resolved from their membership.</summary>
    Task<long> ResolveSchoolIdAsync(ClaimsPrincipal caller, CancellationToken cancellationToken);
}

/// <summary>
/// The school's own profile.
/// </summary>
/// <remarks>
/// 🔴 THE SCHOOL IS RESOLVED FROM THE CALLER, NEVER FROM THE REQUEST.
///
/// No type in <c>JP.Domain.Schools</c> carries a SchoolId or an
/// OrganizationUid, and this service is why: it asks the database which schools
/// the caller belongs to and uses that. There is no parameter for a client to
/// set and no code path that would read one (decision 2.39).
/// </remarks>
internal sealed class SchoolProfileService : ISchoolProfileService
{
    /*
      The image rules for logos and photos.

      ⚠️ Constants here rather than from m_mdm_document_types, because that
      master is keyed to APPROVAL-REQUEST documents and a school logo is not one.
      What is NOT duplicated is the checking: the same UploadValidator does
      extension, magic bytes, size and the generated name (2.48).

      🔴 If a future image type does not fit, extend the validator. Do not add a
      second upload path — two paths means one of them eventually skips a check,
      and it will be the one nobody remembers writing.
    */
    private const string ImageExtensions = "jpg,jpeg,png";
    private const int ImageMaxSizeKb = 5120;

    private readonly ISchoolRepository _schools;
    private readonly IFileStorageService _storage;
    private readonly ILogger<SchoolProfileService> _logger;

    public SchoolProfileService(
        ISchoolRepository schools,
        IFileStorageService storage,
        ILogger<SchoolProfileService> logger)
    {
        _schools = schools;
        _storage = storage;
        _logger = logger;
    }

    /// <summary>
    /// Which school is the caller's.
    /// </summary>
    /// <remarks>
    /// <para>
    /// ⚠️ A user with NO membership gets a 403 rather than an empty profile.
    /// That is the "Active school account with no school" state G19 described —
    /// it should not exist any more, but if it recurs the person deserves a
    /// message rather than a blank page.
    /// </para>
    /// <para>
    /// ⚠️ A user with MORE THAN ONE membership is refused explicitly instead of
    /// being given the first one. Nobody has two today (verified), and picking
    /// arbitrarily would be a silent wrong answer for the first group that does.
    /// See G23.
    /// </para>
    /// </remarks>
    public async Task<long> ResolveSchoolIdAsync(ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        /*
          ⚠️ CHECK THE TYPE BEFORE THE MEMBERSHIP, so the refusal is honest.

          Without this a TEACHER hitting a school endpoint fell through to the
          "no membership" branch and was told "your account is not linked to a
          school yet — if you have just been approved, sign out and back in",
          which is written for a school user and is nonsense for a teacher.

          Found by the 3E HTTP verification: the refusal was correct and the
          reason was wrong, which is the kind of thing that sends somebody to
          support with a problem nobody can reproduce.
        */
        if (caller.GetUserType() != UserType.School)
        {
            throw new ForbiddenException("This is a school area. Your account is not a school account.");
        }

        var memberships = await _schools.GetMembershipsAsync(caller.GetUserUid(), cancellationToken)
            .ConfigureAwait(false);

        if (memberships.Count == 0)
        {
            _logger.LogWarning(
                "User {UserUid} reached a school endpoint with no membership in t_app_school_users. " +
                "Either provisioning did not record them (2.53) or they are not a school user.",
                caller.GetUserUid());

            throw new ForbiddenException(
                "Your account is not linked to a school yet. If you have just been approved, sign out and back in — " +
                "if that does not help, contact us and quote your registered email.");
        }

        if (memberships.Count > 1)
        {
            _logger.LogWarning(
                "User {UserUid} belongs to {Count} schools. The API cannot yet express which one a request means.",
                caller.GetUserUid(), memberships.Count);

            throw new BusinessRuleException(
                "Your account is linked to more than one school, which this screen cannot handle yet. " +
                "Contact us and we will sort it out.");
        }

        return memberships[0].SchoolId;
    }

    public async Task<SchoolProfileDto> GetProfileAsync(ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        var schoolId = await ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        return await _schools.GetProfileAsync(schoolId, caller.GetUserUid(), cancellationToken)
                   .ConfigureAwait(false)
               ?? throw new NotFoundException("That school was not found.");
    }

    /// <summary>
    /// The public view. No authentication, so nothing here reads a caller.
    /// </summary>
    /// <remarks>
    /// 🔴 A suspended, unverified or deleted school returns 404, not 403. The
    /// procedure filters on the lookup, so it comes back null — and confirming
    /// that a school exists but is hidden is itself a disclosure, the same
    /// reasoning as the document download (2.48).
    /// </remarks>
    public async Task<SchoolPublicProfileDto> GetPublicProfileAsync(
        Guid schoolUid, CancellationToken cancellationToken)
    {
        return await _schools.GetPublicProfileAsync(schoolUid, cancellationToken).ConfigureAwait(false)
               ?? throw new NotFoundException("That school was not found.");
    }

    public async Task UpdateProfileAsync(
        UpdateSchoolProfileRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        var schoolId = await ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        var result = await _schools
            .UpdateProfileAsync(schoolId, caller.GetUserUid(), request, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();
    }

    public async Task SaveLogoAsync(
        Stream content, string fileName, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        var schoolId = await ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        // 🔴 The SAME validator every other upload goes through (2.48). Not a
        // second path: two upload paths means one of them eventually skips a
        // check, and the one that skips is the one nobody remembers writing.
        var stored = await StoreImageAsync(content, fileName, "school-logos", cancellationToken)
            .ConfigureAwait(false);

        var result = await _schools
            .SaveLogoAsync(schoolId, caller.GetUserUid(), stored, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();
    }

    public async Task<long> AddPhotoAsync(
        Stream content, string fileName, long? branchId, string? caption,
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        var schoolId = await ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        var stored = await StoreImageAsync(content, fileName, "school-photos", cancellationToken)
            .ConfigureAwait(false);

        var result = await _schools
            .SavePhotoAsync(schoolId, caller.GetUserUid(), "ADD", null, branchId, stored, caption, null,
                caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();

        return result.Id ?? 0;
    }

    public async Task ReorderPhotosAsync(
        ReorderPhotosRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var schoolId = await ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        var result = await _schools
            .SavePhotoAsync(schoolId, caller.GetUserUid(), "REORDER", null, null, null, null,
                request.PhotoIds, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();
    }

    public async Task DeletePhotoAsync(long photoId, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        var schoolId = await ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        var result = await _schools
            .SavePhotoAsync(schoolId, caller.GetUserUid(), "DELETE", photoId, null, null, null, null,
                caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();
    }

    public async Task SaveFacilitiesAsync(
        SaveFacilitiesRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var schoolId = await ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        var result = await _schools
            .SaveFacilitiesAsync(schoolId, caller.GetUserUid(), request.BranchId, request.FacilityIds,
                caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();
    }

    /// <summary>
    /// Validates and stores an image, through the Phase 2D hardening.
    /// </summary>
    /// <remarks>
    /// 🔴 The same four checks every other upload gets (2.48): extension, magic
    /// bytes, size, and a generated storage name so a client filename never
    /// becomes a path. Buffered first so the content can be inspected BEFORE
    /// anything reaches disk.
    /// </remarks>
    private async Task<string> StoreImageAsync(
        Stream content, string fileName, string folder, CancellationToken cancellationToken)
    {
        var capBytes = (long)ImageMaxSizeKb * 1024;
        using var buffer = new MemoryStream();
        var chunk = new byte[81920];
        int read;

        while ((read = await content.ReadAsync(chunk, cancellationToken).ConfigureAwait(false)) > 0)
        {
            buffer.Write(chunk, 0, read);

            // Rejected without reading the whole thing into memory.
            if (buffer.Length > capBytes)
            {
                throw new BusinessRuleException(
                    $"That image is larger than the {ImageMaxSizeKb / 1024.0:0.#} MB limit.",
                    ErrorCodes.ValidationFailed);
            }
        }

        var validated = UploadValidator.Validate(
            fileName,
            buffer.GetBuffer().AsSpan(0, (int)buffer.Length),
            ImageExtensions,
            ImageMaxSizeKb);

        /*
          ⚠️ The virus-scanning hook belongs here too — after validation, before
          storage — for the same reason it does in DocumentService (G13). A
          malicious image is still a real image and passes every check above.
        */

        buffer.Position = 0;

        var stored = await _storage
            .SaveAsync(buffer, validated.StorageFileName, folder, cancellationToken)
            .ConfigureAwait(false);

        return stored.RelativePath;
    }
}
