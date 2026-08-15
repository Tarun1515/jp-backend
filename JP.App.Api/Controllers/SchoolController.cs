using JP.Core.Common;
using JP.Domain.Schools;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/// <summary>
/// A school's own profile, photos and facilities.
/// </summary>
/// <remarks>
/// 🔴 No endpoint here takes a school id. The school is resolved from the
/// caller's membership inside the service (decision 2.39), so there is no
/// parameter a client could point at somebody else's school.
/// </remarks>
[ApiController]
[Route("api/school")]
[Authorize]
public sealed class SchoolController : ControllerBase
{
    private readonly ISchoolProfileService _schools;

    public SchoolController(ISchoolProfileService schools)
    {
        _schools = schools;
    }

    /// <summary>The school's own view — everything, including PAN and suspension.</summary>
    [HttpGet("profile")]
    [ProducesResponseType(typeof(Response<SchoolProfileDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetProfile(CancellationToken cancellationToken)
    {
        var profile = await _schools.GetProfileAsync(User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success(profile));
    }

    /// <summary>
    /// Updates the editable half of the profile.
    /// </summary>
    /// <remarks>
    /// ⚠️ The name, the verification flags and the suspension flags are not
    /// updatable here — a rename changes what was verified, and suspension is an
    /// administrator's decision (2.53).
    /// </remarks>
    [HttpPut("profile")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status409Conflict)]
    public async Task<IActionResult> UpdateProfile(
        [FromBody] UpdateSchoolProfileRequest request, CancellationToken cancellationToken)
    {
        await _schools.UpdateProfileAsync(request, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success("School profile updated."));
    }

    /// <summary>Replaces the school logo.</summary>
    /// <remarks>
    /// Goes through the same validator as every other upload (2.48): extension,
    /// magic bytes, size, and a generated storage name.
    /// </remarks>
    [HttpPost("logo")]
    [RequestSizeLimit(10 * 1024 * 1024)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    public async Task<IActionResult> SaveLogo(IFormFile file, CancellationToken cancellationToken)
    {
        if (file is null || file.Length == 0)
        {
            return BadRequest(ApiResponse.Failure("Choose an image to upload."));
        }

        await using var stream = file.OpenReadStream();

        await _schools.SaveLogoAsync(stream, file.FileName, User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success("Logo updated."));
    }

    /// <summary>Adds a photo to the school gallery.</summary>
    [HttpPost("photos")]
    [RequestSizeLimit(10 * 1024 * 1024)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> AddPhoto(
        IFormFile file,
        [FromForm] long? branchId,
        [FromForm] string? caption,
        CancellationToken cancellationToken)
    {
        if (file is null || file.Length == 0)
        {
            return BadRequest(ApiResponse.Failure("Choose an image to upload."));
        }

        await using var stream = file.OpenReadStream();

        var photoId = await _schools
            .AddPhotoAsync(stream, file.FileName, branchId, caption, User, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(new { photoId }, "Photo added."));
    }

    /// <summary>Reorders the gallery. Send the photo ids in their new order.</summary>
    [HttpPut("photos/order")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> ReorderPhotos(
        [FromBody] ReorderPhotosRequest request, CancellationToken cancellationToken)
    {
        await _schools.ReorderPhotosAsync(request, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success("Photos reordered."));
    }

    /// <summary>Removes one photo. Soft delete — the row is kept.</summary>
    [HttpDelete("photos/{id:long}")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> DeletePhoto(long id, CancellationToken cancellationToken)
    {
        await _schools.DeletePhotoAsync(id, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success("Photo removed."));
    }

    /// <summary>
    /// 🔴 SEND THE COMPLETE SET OF FACILITIES, NOT JUST THE NEW ONE.
    /// </summary>
    /// <remarks>
    /// <para>
    /// This is a full-set sync, not a delta. The procedure diffs what you send
    /// against what is stored: anything new is added, anything absent is
    /// removed, and anything unchanged is left completely alone (2.53).
    /// </para>
    /// <para>
    /// ⚠️ So sending <c>[7]</c> when the school already has <c>[1, 3, 7]</c>
    /// REMOVES 1 and 3. To add a facility, send the existing list plus the new
    /// one.
    /// </para>
    /// <para>
    /// Stated here because a client that sends only the addition and finds the
    /// rest gone will file it as a bug — and they would be right to, if the
    /// contract were never written down.
    /// </para>
    /// <para>
    /// <c>branchId</c> null means the school as a whole; a value means that one
    /// campus. The two are independent sets.
    /// </para>
    /// </remarks>
    [HttpPut("facilities")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> SaveFacilities(
        [FromBody] SaveFacilitiesRequest request, CancellationToken cancellationToken)
    {
        await _schools.SaveFacilitiesAsync(request, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success("Facilities saved."));
    }
}

/// <summary>
/// The public view of a school.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 THE ONLY UNAUTHENTICATED ENDPOINT IN THIS PHASE.
/// </para>
/// <para>
/// It maps <c>USP_GetSchoolPublicProfile</c>, which is a SEPARATE procedure
/// from the own-view rather than the same one with a flag (2.53) — and it maps
/// into <see cref="SchoolPublicProfileDto"/>, which has no PAN, no
/// OrganizationUid, no suspension reason and no RowVersion to be filled in.
/// </para>
/// <para>
/// ⚠️ A suspended, unverified or deleted school returns 404. Not 403:
/// confirming that a school exists but is hidden is itself a disclosure.
/// </para>
/// </remarks>
[ApiController]
[Route("api/schools")]
public sealed class SchoolPublicController : ControllerBase
{
    private readonly ISchoolProfileService _schools;

    public SchoolPublicController(ISchoolProfileService schools)
    {
        _schools = schools;
    }

    /// <summary>What a teacher sees of a school.</summary>
    [HttpGet("{uid:guid}/public")]
    [AllowAnonymous]
    [ProducesResponseType(typeof(Response<SchoolPublicProfileDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetPublicProfile(Guid uid, CancellationToken cancellationToken)
    {
        var profile = await _schools.GetPublicProfileAsync(uid, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success(profile));
    }
}
