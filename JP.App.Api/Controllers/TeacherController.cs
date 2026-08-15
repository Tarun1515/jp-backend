using JP.Core.Common;
using JP.Domain.Teachers;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/// <summary>
/// A teacher's own profile.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 NO ENDPOINT HERE TAKES A TEACHER ID, AND NONE EVER MAY.
/// </para>
/// <para>
/// Phase 3D built the procedures so that editing somebody else's profile cannot
/// be EXPRESSED — no procedure accepts a TeacherId, verified against
/// sys.parameters. Accepting one at this layer and looking it up would hand back
/// exactly what the database refuses to offer.
/// </para>
/// <para>
/// Where a route does carry an id — an experience, a document — it addresses a
/// CHILD row, and the procedure checks that row against the teacher the token
/// resolved to. Another teacher's id answers 404, the same as one that never
/// existed.
/// </para>
/// </remarks>
[ApiController]
[Route("api/teacher")]
[Authorize]
public sealed class TeacherController : ControllerBase
{
    private readonly ITeacherProfileService _teachers;

    public TeacherController(ITeacherProfileService teachers)
    {
        _teachers = teachers;
    }

    /// <summary>The teacher's own view — everything, including the resume path.</summary>
    [HttpGet("profile")]
    [ProducesResponseType(typeof(Response<TeacherProfileDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetProfile(CancellationToken cancellationToken)
    {
        var profile = await _teachers.GetProfileAsync(User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success(profile));
    }

    /// <summary>
    /// Updates the profile. RowVersion required.
    /// </summary>
    /// <remarks>
    /// ⚠️ IsVerified is not updatable here. Verification is an administrator's
    /// decision about a person's documents (2.9); a teacher marking themselves
    /// verified would make the badge worthless.
    /// </remarks>
    [HttpPut("profile")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status409Conflict)]
    public async Task<IActionResult> UpdateProfile(
        [FromBody] UpdateTeacherProfileRequest request, CancellationToken cancellationToken)
    {
        await _teachers.UpdateProfileAsync(request, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success("Profile saved."));
    }

    [HttpPost("photo")]
    [RequestSizeLimit(10 * 1024 * 1024)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> SavePhoto(IFormFile file, CancellationToken cancellationToken)
    {
        if (file is null || file.Length == 0)
        {
            return BadRequest(ApiResponse.Failure("Choose a photo to upload."));
        }

        await using var stream = file.OpenReadStream();
        await _teachers.SavePhotoAsync(stream, file.FileName, User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success("Photo saved."));
    }

    /// <summary>
    /// Uploads the teacher's resume.
    /// </summary>
    /// <remarks>
    /// 🔴 This file is never served to a school from here or anywhere else
    /// except <c>GET /api/teachers/{uid}/contact</c>, and only once the teacher
    /// has consented (2.56). A resume carries a phone number and an email in its
    /// first three lines — it IS a contact detail, and it is gated as one.
    /// </remarks>
    [HttpPost("resume")]
    [RequestSizeLimit(10 * 1024 * 1024)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> SaveResume(IFormFile file, CancellationToken cancellationToken)
    {
        if (file is null || file.Length == 0)
        {
            return BadRequest(ApiResponse.Failure("Choose a file to upload."));
        }

        await using var stream = file.OpenReadStream();
        await _teachers.SaveResumeAsync(stream, file.FileName, User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success("Resume saved."));
    }

    /// <summary>
    /// Adds a document.
    /// </summary>
    /// <remarks>
    /// ⚠️ Adds only — it never replaces. Two degree certificates or two
    /// experience letters are legitimate, which is why 3A gave the table no
    /// unique index on (teacher, type) (2.51). Replacing is delete-then-add, and
    /// the teacher does it deliberately.
    ///
    /// 🔴 No identity NUMBER is stored anywhere (2.50) — the teacher chooses
    /// which government photo ID they are uploading and uploads the document.
    /// </remarks>
    [HttpPost("documents")]
    [RequestSizeLimit(20 * 1024 * 1024)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> SaveDocument(
        [FromForm] int documentTypeId, IFormFile file, CancellationToken cancellationToken)
    {
        if (file is null || file.Length == 0)
        {
            return BadRequest(ApiResponse.Failure("Choose a file to upload."));
        }

        await using var stream = file.OpenReadStream();

        var documentId = await _teachers
            .SaveDocumentAsync(documentTypeId, stream, file.FileName, User, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(new { documentId }, "Document uploaded."));
    }

    /// <summary>Removes one of your own documents. 404 for anybody else's.</summary>
    [HttpDelete("documents/{id:long}")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> DeleteDocument(long id, CancellationToken cancellationToken)
    {
        await _teachers.DeleteDocumentAsync(id, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success("Document removed."));
    }

    // =========================================================================
    // 🔴 THE FIVE FULL-SET ENDPOINTS
    //
    // Every one of these takes the COMPLETE desired set, not a delta. The
    // procedure diffs it against what is stored: new rows are inserted, absent
    // ones are soft-deleted, unchanged ones are not touched at all (2.53, 2.54).
    //
    // ⚠️ Sending only the addition REMOVES everything else. That is the
    // contract, and it is written on each endpoint because a client that sends
    // one subject and finds the others gone will file it as a bug — rightly, if
    // it was never stated.
    // =========================================================================

    /// <summary>
    /// 🔴 THE COMPLETE LIST OF SUBJECTS, not just the new one.
    /// </summary>
    /// <remarks>
    /// Sending <c>[2]</c> when the teacher already has <c>[1, 2, 10]</c> removes
    /// 1 and 10. To add a subject, send the existing list plus the new one.
    /// Re-adding something previously removed revives the original row rather
    /// than creating a second.
    /// </remarks>
    [HttpPut("subjects")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> SaveSubjects(
        [FromBody] SaveIdSetRequest request, CancellationToken cancellationToken)
    {
        await _teachers.SaveSubjectsAsync(request, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success("Subjects saved."));
    }

    /// <summary>🔴 THE COMPLETE LIST of class levels. Absent ids are removed.</summary>
    [HttpPut("class-levels")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> SaveClassLevels(
        [FromBody] SaveIdSetRequest request, CancellationToken cancellationToken)
    {
        await _teachers.SaveClassLevelsAsync(request, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success("Class levels saved."));
    }

    /// <summary>🔴 THE COMPLETE LIST of skills. Absent ids are removed.</summary>
    [HttpPut("skills")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> SaveSkills(
        [FromBody] SaveIdSetRequest request, CancellationToken cancellationToken)
    {
        await _teachers.SaveSkillsAsync(request, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success("Skills saved."));
    }

    /// <summary>
    /// 🔴 THE COMPLETE LIST of languages. Absent ones are removed.
    /// </summary>
    /// <remarks>
    /// ⚠️ A language already present whose ProficiencyLevel changed is UPDATED
    /// in place — it keeps its row and its date. Only genuinely new languages
    /// are inserted (2.54).
    /// </remarks>
    [HttpPut("languages")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> SaveLanguages(
        [FromBody] SaveLanguagesRequest request, CancellationToken cancellationToken)
    {
        await _teachers.SaveLanguagesAsync(request, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success("Languages saved."));
    }

    /// <summary>
    /// 🔴 THE COMPLETE LIST of preferred locations. Absent ones are removed.
    /// </summary>
    /// <remarks>
    /// ⚠️ <c>cityId</c> null means "anywhere in this state" — a real preference,
    /// and the only one available until the city dataset is imported (2.47). The
    /// same place sent twice in one request is deduplicated rather than
    /// rejected.
    /// </remarks>
    [HttpPut("preferred-locations")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> SavePreferredLocations(
        [FromBody] SavePreferredLocationsRequest request, CancellationToken cancellationToken)
    {
        await _teachers.SavePreferredLocationsAsync(request, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success("Preferred locations saved."));
    }

    // =========================================================================
    // EXPERIENCES — entities, NOT a set
    // =========================================================================

    /// <summary>
    /// Adds one experience row.
    /// </summary>
    /// <remarks>
    /// ⚠️ Unlike the five above, this is NOT a set sync. Each row is a thing the
    /// teacher writes and edits on its own — two roles at one school starting
    /// the same month are legitimate, which is why the table has no unique index
    /// (2.51).
    ///
    /// TotalExperienceMonths is recomputed from these rows on every change
    /// (2.54); the client never sends it.
    /// </remarks>
    [HttpPost("experiences")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> AddExperience(
        [FromBody] SaveExperienceRequest request, CancellationToken cancellationToken)
    {
        var id = await _teachers.SaveExperienceAsync(null, request, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success(new { id }, "Experience added."));
    }

    /// <summary>Edits one of your own experience rows. 404 for anybody else's.</summary>
    [HttpPut("experiences/{id:long}")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> UpdateExperience(
        long id, [FromBody] SaveExperienceRequest request, CancellationToken cancellationToken)
    {
        await _teachers.SaveExperienceAsync(id, request, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success("Experience updated."));
    }

    /// <summary>Removes one of your own experience rows. 404 for anybody else's.</summary>
    [HttpDelete("experiences/{id:long}")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> DeleteExperience(long id, CancellationToken cancellationToken)
    {
        await _teachers.DeleteExperienceAsync(id, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success("Experience removed."));
    }
}

/// <summary>
/// A teacher as a SCHOOL sees them.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 TWO ENDPOINTS, TWO SHAPES, AND NO PATH BETWEEN THEM.
/// </para>
/// <para>
/// <c>/browse</c> returns <see cref="TeacherBrowseDto"/>, which has no
/// ContactEmail, no ContactMobile, no ResumePath and no date of birth — not
/// null, ABSENT. <c>/contact</c> returns <see cref="TeacherContactDto"/> and is
/// gated by the teacher's own consent (2.56, LOCKED).
/// </para>
/// <para>
/// They are separate because Phase 3D made them separate procedures for the same
/// reason: a single shape with an "include contact" flag is one forgotten column
/// away from a leak, and the forgetting happens later.
/// </para>
/// </remarks>
[ApiController]
[Route("api/teachers")]
[Authorize]
public sealed class TeacherDirectoryController : ControllerBase
{
    private readonly ITeacherDirectoryService _directory;

    public TeacherDirectoryController(ITeacherDirectoryService directory)
    {
        _directory = directory;
    }

    /// <summary>
    /// What a school sees while browsing.
    /// </summary>
    /// <remarks>
    /// Everything needed to decide whether to invite this person, and no way to
    /// reach them off-platform. Documents appear as a type and a verified flag —
    /// the fact, never the file.
    /// </remarks>
    [HttpGet("{uid:guid}/browse")]
    [ProducesResponseType(typeof(Response<TeacherBrowseDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Browse(Guid uid, CancellationToken cancellationToken)
    {
        var profile = await _directory.BrowseAsync(uid, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success(profile));
    }

    /// <summary>
    /// Contact details — email, mobile and resume — once the teacher has
    /// consented.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 Unlocks when the teacher APPLIED to your school, or ACCEPTED an invite
    /// from you (2.56, LOCKED). Nothing else unlocks it — not a paid plan, and
    /// not an invite you merely sent.
    /// </para>
    /// <para>
    /// Returns 403 with a message naming what would unlock it, so the path is
    /// visible rather than just the door being shut.
    /// </para>
    /// <para>
    /// ⚠️ Returns 403 for everybody today. Applications arrive in Phase 5 and
    /// invites in Phase 6, so no teacher has consented to anything yet — that is
    /// the correct answer, not an unfinished one.
    /// </para>
    /// </remarks>
    [HttpGet("{uid:guid}/contact")]
    [ProducesResponseType(typeof(Response<TeacherContactDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Contact(Guid uid, CancellationToken cancellationToken)
    {
        var contact = await _directory.GetContactAsync(uid, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success(contact));
    }
}
