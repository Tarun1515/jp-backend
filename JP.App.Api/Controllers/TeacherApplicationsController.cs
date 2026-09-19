using JP.Core.Common;
using JP.Domain.Applications;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/// <summary>
/// The job market, as a teacher sees it.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 ACTIVE POSTINGS ONLY, BY THE EFFECTIVE STATUS. An Active job whose
/// closing date has passed is EXPIRED and does not list here, and its detail
/// answers 404. Expiry is derived from the date in IST — no sweep job runs, and
/// there is no stored Expired status to be out of date.
/// </para>
/// <para>
/// 🔴 NO SchoolId. A school is identified to a teacher by SchoolUid, its public
/// identifier (2.39).
/// </para>
/// </remarks>
[ApiController]
[Route("api/teacher/jobs")]
[Authorize]
public sealed class TeacherJobsController : ControllerBase
{
    private readonly ITeacherApplicationService _teacher;

    public TeacherJobsController(ITeacherApplicationService teacher)
    {
        _teacher = teacher;
    }

    /// <summary>
    /// Browse open jobs.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 <c>applicationCount</c> on each card is DERIVED — a COUNT of live
    /// application rows, computed on every read. <c>t_app_jobs.ApplicationCount</c>
    /// exists, stays at zero and is never written (024): a maintained counter is
    /// a second source of truth that drifts silently, and the number on a card
    /// would stop matching the list behind it with nothing erroring.
    /// </para>
    /// <para>
    /// ⚠️ A suspended or deactivated school's jobs do not appear. That is an
    /// administrative decision about the organisation and it has to reach the
    /// listing, or it is cosmetic.
    /// </para>
    /// </remarks>
    [HttpGet]
    [ProducesResponseType(typeof(Response<IReadOnlyList<JobBrowseItemDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> Browse(
        [FromQuery] JobBrowseFilter filter, CancellationToken cancellationToken)
    {
        var page = await _teacher.BrowseJobsAsync(User, filter, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Paged(page.Items, page.TotalRecords));
    }

    /// <summary>
    /// One posting, with whether the caller has already applied or saved it.
    /// </summary>
    /// <remarks>
    /// 🔴 An EXPIRED or CLOSED job answers 404 — the same as one that never
    /// existed. This is the URL somebody bookmarks or is mailed a month later,
    /// and a page carrying an Apply button that the server will refuse is worse
    /// than an honest "this posting has gone".
    /// </remarks>
    [HttpGet("{jobId:long}")]
    [ProducesResponseType(typeof(Response<JobForTeacherDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetById(long jobId, CancellationToken cancellationToken)
    {
        var job = await _teacher.GetJobAsync(User, jobId, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(job));
    }

    /// <summary>
    /// Save or unsave a job — the teacher's private shortlist.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 SAVING IS NOT APPLYING, AND IT DOES NOT UNLOCK CONTACT. The school is
    /// told nothing by this; <c>fn_TeacherContactUnlocked</c> does not read
    /// <c>t_app_saved_jobs</c> and must never be made to (2.56, 024). Saving is
    /// interest; applying is consent.
    /// </para>
    /// <para>
    /// ⚠️ A toggle, not a create: unsaving and saving again revives the same
    /// row rather than writing a new one every time somebody changes their mind
    /// (2.4). The response says which state it ended in.
    /// </para>
    /// </remarks>
    [HttpPost("{jobId:long}/save")]
    [ProducesResponseType(typeof(Response<ToggleSavedJobResultDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> ToggleSaved(long jobId, CancellationToken cancellationToken)
    {
        var result = await _teacher.ToggleSavedJobAsync(User, jobId, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(result, result.IsSaved ? "Saved." : "Removed from saved jobs."));
    }

    /// <summary>The jobs the caller has saved. Private to them.</summary>
    [HttpGet("saved")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<SavedJobDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetSaved(CancellationToken cancellationToken)
    {
        var saved = await _teacher.GetSavedJobsAsync(User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(saved));
    }
}

/// <summary>
/// A teacher's own applications.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 APPLYING IS WHAT UNLOCKS THIS TEACHER'S CONTACT DETAILS TO ONE SCHOOL
/// (2.56, LOCKED — consent path 1). Until Phase 5 there was no way for a
/// teacher to consent to anything, and <c>fn_TeacherContactUnlocked</c>
/// returned a hard 0 for everybody. <see cref="Apply"/> is that path.
/// </para>
/// <para>
/// 🔴 APPLYING IS FREE. No endpoint here consumes anything — no quota, no
/// credits, no plan check. The consuming action in this product is the
/// SCHOOL'S publish (2.64).
/// </para>
/// <para>
/// 🔴 NO ENDPOINT HERE TAKES A TEACHER ID, AND NONE EVER MAY. The teacher is
/// resolved from the token. Where a route carries an id it addresses an
/// APPLICATION, and the procedure checks that row against the teacher the token
/// resolved to — somebody else's answers 404, the same as one that never
/// existed.
/// </para>
/// <para>
/// ⚠️ THERE IS NO WITHDRAW IN THIS PHASE, deliberately — see G28. A half-built
/// withdraw that soft-deleted the row would revoke a school's contact access
/// through a path nobody designed, and it is the revocation rather than the
/// button that needs thinking about.
/// </para>
/// </remarks>
[ApiController]
[Route("api/teacher/applications")]
[Authorize]
public sealed class TeacherApplicationsController : ControllerBase
{
    private readonly ITeacherApplicationService _teacher;

    public TeacherApplicationsController(ITeacherApplicationService teacher)
    {
        _teacher = teacher;
    }

    /// <summary>
    /// Apply to a job. 🔴 This is consent path 1.
    /// </summary>
    /// <remarks>
    /// <para>
    /// ⚠️ A 200 CAN CARRY <c>ALREADY_APPLIED</c>, AND THAT IS A SUCCESS. The
    /// teacher wanted to have applied, and they have. Treating a double-tap as
    /// an error would send somebody to support over a working application — and
    /// it is also what the loser of two genuinely parallel applies receives,
    /// with exactly one row written. Branch on the HTTP status first, then the
    /// code (2.12).
    /// </para>
    /// <para>
    /// Refusals keep distinct codes so a screen can act on them:
    /// </para>
    /// <code>
    ///   RESUME_REQUIRED  400  link straight to the resume upload
    ///   JOB_EXPIRED      400  "applications have closed"
    ///   NOT_FOUND        404  no such job, or it is a draft / closed
    ///   APPLY_CONFLICT   409  retryable, and nothing about the person
    /// </code>
    /// <para>
    /// 🔴 VERIFICATION IS NOT CHECKED. An unverified teacher may apply — soft
    /// verification is a locked stance (2.9), and the badge is a signal to
    /// schools rather than a gate on the teacher.
    /// </para>
    /// </remarks>
    [HttpPost]
    [ProducesResponseType(typeof(Response<ApplyResultDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status409Conflict)]
    public async Task<IActionResult> Apply(
        [FromBody] ApplyToJobRequest request, CancellationToken cancellationToken)
    {
        var result = await _teacher.ApplyAsync(User, request, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.SuccessWithCode(result, result.Code,
            result.Created ? "Applied." : "You have already applied to this job."));
    }

    /// <summary>
    /// The caller's own applications.
    /// </summary>
    /// <remarks>
    /// 🔴 <c>statusName</c> is the master's <c>TeacherFacingName</c> — "Not
    /// selected", never "Rejected" — and there is no <c>rejectionReason</c>
    /// property on this shape at all. The school's private note on why somebody
    /// was turned down does not appear in any teacher-facing procedure or type.
    /// </remarks>
    [HttpGet]
    [ProducesResponseType(typeof(Response<IReadOnlyList<MyApplicationListItemDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetList([FromQuery] int? statusId, CancellationToken cancellationToken)
    {
        var applications = await _teacher.GetMyApplicationsAsync(User, statusId, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(applications));
    }

    /// <summary>
    /// Counts and the five most recent — the teacher dashboard's applications
    /// area.
    /// </summary>
    /// <remarks>
    /// 🔴 No parameters. The teacher comes from the token, so there is nothing
    /// to forge. 3I left this area an honest not-yet empty state because there
    /// was no table to count (2.62); there is one now.
    /// </remarks>
    [HttpGet("stats")]
    [ProducesResponseType(typeof(Response<TeacherApplicationStatsDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetStats(CancellationToken cancellationToken)
    {
        var stats = await _teacher.GetStatsAsync(User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(stats));
    }

    /// <summary>
    /// One of the caller's own applications, with its journey.
    /// </summary>
    /// <remarks>
    /// <para>
    /// ⚠️ ANOTHER TEACHER'S APPLICATION ID ANSWERS 404, not 403 — a different
    /// status would confirm it exists (2.6). The procedure matches the row
    /// against the teacher the token resolved to, so there is no id to guess at.
    /// </para>
    /// <para>
    /// 🔴 The history here carries NO remarks and NO actor. The remarks are the
    /// school's internal note, and which colleague pressed the button is the
    /// school's business. What the teacher gets is when it moved and to what,
    /// in their own words.
    /// </para>
    /// </remarks>
    [HttpGet("{applicationId:long}")]
    [ProducesResponseType(typeof(Response<MyApplicationDetailDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetById(long applicationId, CancellationToken cancellationToken)
    {
        var application = await _teacher.GetMyApplicationAsync(User, applicationId, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(application));
    }
}
