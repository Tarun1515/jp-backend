using JP.Core.Common;
using JP.Domain.Applications;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/// <summary>
/// The school's applicants.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 NO SchoolId ANYWHERE — not in a route, not in a query, not in a body, not
/// in a response. It is resolved from the token's OrganizationUid on the server
/// and never leaves it (2.39). A teacher is identified by TeacherUid; there is
/// no TeacherId on the wire either.
/// </para>
/// <para>
/// 🔴 EVERY READ IS BRANCH-SCOPED through <c>fn_VisibleBranches</c>. A
/// branch-bound HR sees applications at their campuses and nothing else, and
/// anything outside that scope answers 404 rather than 403 — "that applicant is
/// not yours" confirms the applicant exists (2.6).
/// </para>
/// <para>
/// 🔴 CONTACT DETAILS APPEAR ON EXACTLY ONE OPERATION HERE — <see cref="GetById"/>
/// — and only because <c>fn_TeacherContactUnlocked</c> said so (2.56, LOCKED).
/// The list carries no contact columns at all, and neither does the stats tile.
/// </para>
/// <para>
/// ⚠️ NOTHING IN THIS CONTROLLER COSTS ANYTHING. There is no entitlement call
/// on any of these routes; the consuming action is the job publish (2.64).
/// </para>
/// </remarks>
[ApiController]
[Route("api/applicants")]
[Authorize]
public sealed class ApplicantsController : ControllerBase
{
    private readonly IApplicantService _applicants;

    public ApplicantsController(IApplicantService applicants)
    {
        _applicants = applicants;
    }

    /// <summary>
    /// The school's applicants — everybody, or one job's.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <paramref name="jobId"/> null means school-wide. A job belonging to
    /// another school simply matches nothing, because the scope join runs
    /// before the filter.
    /// </para>
    /// <para>
    /// 🔴 NO CONTACT FIELDS ON THIS SHAPE. Every applicant here has consented,
    /// so returning an email would not break the rule — it would break the
    /// SHAPE, and the shape is what has held the line since 3D. A list is a
    /// browse surface that ends up in a log or an export; contact is a
    /// deliberate act on one person, which is <see cref="GetById"/>.
    /// </para>
    /// </remarks>
    [HttpGet]
    [ProducesResponseType(typeof(Response<IReadOnlyList<ApplicantListItemDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetList(
        [FromQuery] long? jobId, [FromQuery] int? statusId, [FromQuery] long? branchId,
        CancellationToken cancellationToken)
    {
        var applicants = await _applicants
            .GetListAsync(User, jobId, statusId, branchId, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(applicants));
    }

    /// <summary>
    /// Counts and the five most recent — the dashboard's applicants area.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 NO PARAMETERS, AND THAT IS THE SECURITY PROPERTY — the same one
    /// <c>GET /api/jobs/stats</c> has. There is no schoolId or branchId to send,
    /// so there is nothing to forge: a query string appended by hand is ignored
    /// and the caller's own counts come back.
    /// </para>
    /// <para>
    /// 🔴 APPLICANT.VIEW only. A Viewer sees the dashboard, so a Viewer sees the
    /// counts.
    /// </para>
    /// <para>
    /// ⚠️ 3I left this area an honest not-yet empty state because there was no
    /// table to count (2.62). There is one now, so a school with no applicants
    /// gets a real zero — which is a measurement rather than a placeholder.
    /// </para>
    /// </remarks>
    [HttpGet("stats")]
    [ProducesResponseType(typeof(Response<SchoolApplicantStatsDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetStats(CancellationToken cancellationToken)
    {
        var stats = await _applicants.GetStatsAsync(User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(stats));
    }

    /// <summary>
    /// One applicant in full — including contact, and the status history.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 THE CONTACT BLOCK IS GATED BY <c>fn_TeacherContactUnlocked</c> AND BY
    /// NOTHING ELSE (2.56, LOCKED). It will be unlocked here, because an
    /// application IS the consent — but the question is asked rather than
    /// assumed, so that the shape stays right for the next reader.
    /// </para>
    /// <para>
    /// 🔴 <c>resumePathSnapshot</c> is the resume AS IT WAS WHEN THEY APPLIED.
    /// A teacher replacing their file does not change what this school was
    /// given, and a school that shortlisted somebody can re-read what it
    /// shortlisted.
    /// </para>
    /// <para>
    /// ⚠️ OPENING AN APPLICATION STAMPS IT VIEWED. Applied → Viewed happens
    /// here, idempotently, because opening one IS how a school sees it — the
    /// teacher's list says "Seen by the school" on the strength of it. A
    /// separate button would report whether somebody remembered to press it.
    /// The stamp never fails the read.
    /// </para>
    /// </remarks>
    [HttpGet("{applicationId:long}")]
    [ProducesResponseType(typeof(Response<ApplicantDetailDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetById(long applicationId, CancellationToken cancellationToken)
    {
        var applicant = await _applicants.GetByIdAsync(User, applicationId, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(applicant));
    }

    /// <summary>
    /// The resume the school was given.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 REQUIRES RESUME.DOWNLOAD ON TOP OF APPLICANT.VIEW, and that second
    /// permission is the point: SCHOOL_VIEWER holds the first and not the
    /// second, so a read-only account sees that a resume exists and cannot open
    /// it. A resume carries a phone number and an address in its first three
    /// lines — it IS a contact detail and is gated as one (2.56).
    /// </para>
    /// <para>
    /// 🔴 Serves the SNAPSHOT, never the teacher's live file. Uploads live under
    /// App_Data, which is not served statically and never may be — that root
    /// holds every resume in the system.
    /// </para>
    /// </remarks>
    [HttpGet("{applicationId:long}/resume")]
    [ProducesResponseType(StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetResume(long applicationId, CancellationToken cancellationToken)
    {
        var (content, contentType) = await _applicants
            .OpenResumeAsync(User, applicationId, cancellationToken).ConfigureAwait(false);

        return File(content, contentType);
    }

    /// <summary>
    /// Move an application along the pipeline.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 THE PERMISSION DEPENDS ON THE DESTINATION, because the seed draws the
    /// line there: rejecting needs APPLICANT.REJECT, every other move needs
    /// APPLICANT.SHORTLIST. HR holds the second and not the first, so an HR
    /// screens and shortlists and somebody senior turns people down.
    /// </para>
    /// <para>
    /// 🔴 THE MAP DECIDES WHAT IS LEGAL, not this endpoint and not the screen
    /// that drew the buttons. Rejected is TERMINAL — Rejected → Shortlisted is
    /// refused with INVALID_TRANSITION, because a teacher has already been told
    /// "not selected" and moving them back would mean the product had said
    /// something untrue.
    /// </para>
    /// <para>
    /// ⚠️ Statuses 7–10 — the offer chain — refuse with their own code,
    /// OFFER_STAGE_UNAVAILABLE. They are seeded so the ids never move (2.47),
    /// and <c>t_app_offers</c> is Phase 6. That is a not-yet, not a mistake the
    /// person made, and it gets its own word.
    /// </para>
    /// <para>
    /// ⚠️ A 200 can carry NO_CHANGE: asking for the state it is already in is
    /// not an error (2.48), and nothing is written to the history. Branch on
    /// the status first, then the code.
    /// </para>
    /// <para>
    /// ⚠️ <c>remarks</c> on a rejection is the school's OWN note. It is stored
    /// and is never shown to the teacher in this phase — they see "Not
    /// selected" and nothing more.
    /// </para>
    /// </remarks>
    [HttpPost("{applicationId:long}/status")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> SetStatus(
        long applicationId, [FromBody] SetApplicationStatusRequest request,
        CancellationToken cancellationToken)
    {
        await _applicants.SetStatusAsync(User, applicationId, request, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success("Updated."));
    }
}
