using JP.Core.Common;
using JP.Domain.Admin;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/*==============================================================================
  THE ADMIN OPERATIONS DESK. Phase 7B.

  ----------------------------------------------------------------------------
  🔒 EVERY ROUTE HERE IS GATED ON A PERMISSION, IN THE SERVICE
  ----------------------------------------------------------------------------
      MODERATION.JOB      pull, restore, any job's history
      MODERATION.REPORT   the reports queue and its state machine
      ENQUIRY.MANAGE      the contact queue
      CMS.MANAGE          the FAQ, the content blocks, featured placement

  VERIFICATION_ADMIN holds none of them, so a verifier reaches every one of
  these routes and is refused by all of them — which 7B's verification forces
  with devtools rather than inferring from this comment.

  ⚠️ [Authorize] HERE AND THE PERMISSION IN THE SERVICE, deliberately. An
  attribute-based permission filter would put the rule in two places for the
  routes that also need a scoped read (the school's own history), and the
  service is where the scoping already lives.

  🔴 PULLING A JOB TAKES EFFECT ON THE PUBLIC SITE IMMEDIATELY, and that is
  7A-0's cache decision paying for itself: PublicController sends
  `no-store, no-cache, must-revalidate` on the job endpoints, so there is no
  cached copy anywhere to outlive this call. 2.81 weighed a 30-second cache for
  the listing and declined it for exactly this moment — a pulled job surviving
  as a card for half a minute. The verification pulls a job and re-reads the
  public route in the same second.
==============================================================================*/

[ApiController]
[Route("api/admin/desk")]
[Authorize]
[Produces("application/json")]
public sealed class AdminDeskController : ControllerBase
{
    private readonly IAdminDeskService _desk;

    private readonly IAdminAnalyticsService _analytics;

    public AdminDeskController(IAdminDeskService desk, IAdminAnalyticsService analytics)
    {
        _desk = desk;
        _analytics = analytics;
    }

    // ---- moderation --------------------------------------------------------

    /// <summary>Platform analytics. 🔒 REPORT.VIEW, and an ADMIN user type.</summary>
    /// <remarks>
    /// 🔴 ONE CALL, THREE DATABASES — assembled in the service, because no
    /// object in this product may join across them (2.2).
    ///
    /// 🔒 HOW MANY, NEVER WHO. No email, no uid, no request number, no school
    /// or teacher name appears in the response, and the two identity
    /// databases' procedures carry a build guard that fails if one does.
    /// REPORT.VIEW is not USER.MANAGE.
    ///
    /// ⚠️ Every figure is COUNTED. Not one denormalised counter is read — 027's
    /// guard enforces that, because one phase ago the moderation queue read
    /// ApplicationCount and reported 0 applied for every advert.
    /// </remarks>
    [HttpGet("analytics")]
    [ProducesResponseType(typeof(Response<AdminAnalyticsDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetAnalytics(CancellationToken cancellationToken)
    {
        var data = await _analytics.GetAsync(User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(data));
    }

    /// <summary>Jobs to moderate, newest-and-noisiest first. 🔒 MODERATION.JOB.</summary>
    /// <remarks>
    /// 🔴 ADDED SO THE DESK IS USABLE WITHOUT ALREADY KNOWING A UID. Pull and
    /// restore address a job by uid, which proved the behaviour; a moderator
    /// opening the screen on Monday needs "what was reported, and what is
    /// currently pulled?" answered first.
    ///
    /// ⚠️ A pulled job IS in this list, and must be: restoring one is
    /// impossible to reach otherwise.
    /// </remarks>
    [HttpGet("jobs")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<ModeratableJobDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> SearchJobs(
        [FromQuery] int? statusId = null,
        [FromQuery] string? search = null,
        [FromQuery] Guid? jobUid = null,
        [FromQuery] bool reportedOnly = false,
        [FromQuery] int pageNumber = 1,
        [FromQuery] int pageSize = 20,
        CancellationToken cancellationToken = default)
    {
        var (rows, total) = await _desk
            .SearchJobsForModerationAsync(
                User, statusId, search, jobUid, reportedOnly, pageNumber, pageSize, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Paged(rows, total));
    }

    /// <summary>Pull a job off the public site. 🔒 MODERATION.JOB.</summary>
    /// <remarks>
    /// 🔴 THE APPLICATIONS ARE NOT TOUCHED. The candidates did nothing wrong —
    /// 025 writes the job's status and one log row, and a build guard fails if
    /// it ever reads or writes application data.
    /// </remarks>
    [HttpPost("jobs/{jobUid:guid}/pull")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> PullJob(
        Guid jobUid, [FromBody] JobModerationRequest request, CancellationToken cancellationToken)
    {
        var message = await _desk.PullJobAsync(User, jobUid, request, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success<object?>(null, message));
    }

    /// <summary>Put it back — to the status it had, not to Active. 🔒 MODERATION.JOB.</summary>
    [HttpPost("jobs/{jobUid:guid}/restore")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> RestoreJob(
        Guid jobUid, [FromBody] JobModerationRequest request, CancellationToken cancellationToken)
    {
        var message = await _desk.RestoreJobAsync(User, jobUid, request, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success<object?>(null, message));
    }

    /// <summary>Any job's moderation history. 🔒 MODERATION.JOB.</summary>
    [HttpGet("jobs/{jobUid:guid}/history")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<JobModerationEntryDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetHistory(Guid jobUid, CancellationToken cancellationToken)
    {
        var rows = await _desk.GetModerationHistoryForAdminAsync(User, jobUid, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(rows));
    }

    // ---- reports -----------------------------------------------------------

    /// <summary>The reports queue. 🔒 MODERATION.REPORT.</summary>
    /// <remarks>
    /// 🔒 THIS IS THE ONLY ROUTE IN THE PRODUCT THAT RETURNS A REPORTER'S UID.
    /// No school-facing or teacher-facing endpoint returns ReportDto, 025
    /// guards the column's projection, and 7B's verification reads the raw
    /// bytes of every response the reported party can fetch.
    /// </remarks>
    [HttpGet("reports")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<ReportDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> SearchReports(
        [FromQuery] int? statusId = null,
        [FromQuery] string? entityType = null,
        [FromQuery] int pageNumber = 1,
        [FromQuery] int pageSize = 20,
        CancellationToken cancellationToken = default)
    {
        var (rows, total) = await _desk
            .SearchReportsAsync(User, statusId, entityType, pageNumber, pageSize, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Paged(rows, total));
    }

    /// <summary>Move a report along. 🔒 MODERATION.REPORT.</summary>
    [HttpPost("reports/{reportUid:guid}/status")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> UpdateReportStatus(
        Guid reportUid, [FromBody] UpdateReportStatusRequest request, CancellationToken cancellationToken)
    {
        var message = await _desk.UpdateReportStatusAsync(User, reportUid, request, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success<object?>(null, message));
    }

    // ---- featured ----------------------------------------------------------

    /// <summary>Featured windows, with "is it live today" computed. 🔒 CMS.MANAGE.</summary>
    [HttpGet("featured")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<FeaturedWindowDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> ListFeatured(CancellationToken cancellationToken)
    {
        var rows = await _desk.ListFeaturedAsync(User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(rows));
    }

    /// <summary>Feature a job or a school for a date window. 🔒 CMS.MANAGE.</summary>
    [HttpPost("featured")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> SaveFeatured(
        [FromBody] SaveFeaturedRequest request, CancellationToken cancellationToken)
    {
        var message = await _desk.SaveFeaturedAsync(User, request, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success<object?>(null, message));
    }

    /// <summary>Remove one window. 🔒 CMS.MANAGE.</summary>
    [HttpDelete("featured/{featuredType}/{featuredId:long}")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> RemoveFeatured(
        string featuredType, long featuredId, CancellationToken cancellationToken)
    {
        var message = await _desk
            .RemoveFeaturedAsync(User, featuredType, featuredId, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success<object?>(null, message));
    }

    // ---- the site's copy ---------------------------------------------------

    /// <summary>Every FAQ, including the hidden ones. 🔒 CMS.MANAGE.</summary>
    [HttpGet("faqs")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<AdminFaqDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> ListFaqs(CancellationToken cancellationToken)
    {
        var rows = await _desk.ListFaqsAsync(User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(rows));
    }

    /// <summary>Add or edit one. 🔒 CMS.MANAGE.</summary>
    [HttpPost("faqs")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> SaveFaq(
        [FromBody] SaveFaqRequest request, CancellationToken cancellationToken)
    {
        var message = await _desk.SaveFaqAsync(User, request, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success<object?>(null, message));
    }

    /// <summary>
    /// Remove one. 🔒 CMS.MANAGE.
    /// </summary>
    /// <remarks>
    /// ⚠️ Refused when it is the last live question in its section: /faq groups
    /// by category, so an empty heading reads as a broken page rather than a
    /// deliberate edit. 003's build guard asserts the same floor.
    /// </remarks>
    [HttpDelete("faqs/{faqId:int}")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> DeleteFaq(int faqId, CancellationToken cancellationToken)
    {
        var message = await _desk.DeleteFaqAsync(User, faqId, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success<object?>(null, message));
    }

    /// <summary>The content blocks. 🔒 CMS.MANAGE.</summary>
    [HttpGet("content-blocks")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<AdminContentBlockDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> ListContentBlocks(CancellationToken cancellationToken)
    {
        var rows = await _desk.ListContentBlocksAsync(User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(rows));
    }

    /// <summary>Add or edit one, addressed by its key. 🔒 CMS.MANAGE.</summary>
    [HttpPost("content-blocks")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> SaveContentBlock(
        [FromBody] SaveContentBlockRequest request, CancellationToken cancellationToken)
    {
        var message = await _desk.SaveContentBlockAsync(User, request, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success<object?>(null, message));
    }

    // ---- enquiries ---------------------------------------------------------

    /// <summary>The contact queue. 🔒 ENQUIRY.MANAGE.</summary>
    /// <remarks>
    /// 🔒 There is no caller identity to show: 033 gave the table none, because
    /// an enquiry arrives from an anonymous visitor.
    /// </remarks>
    [HttpGet("enquiries")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<EnquiryDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> SearchEnquiries(
        [FromQuery] bool? isResolved = null,
        [FromQuery] int pageNumber = 1,
        [FromQuery] int pageSize = 20,
        CancellationToken cancellationToken = default)
    {
        var (rows, total) = await _desk
            .SearchEnquiriesAsync(User, isResolved, pageNumber, pageSize, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Paged(rows, total));
    }

    /// <summary>Mark one answered, with what you told them. 🔒 ENQUIRY.MANAGE.</summary>
    [HttpPost("enquiries/{enquiryId:long}/resolve")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> ResolveEnquiry(
        long enquiryId, [FromBody] ResolveEnquiryRequest request, CancellationToken cancellationToken)
    {
        var message = await _desk.ResolveEnquiryAsync(User, enquiryId, request, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success<object?>(null, message));
    }
}

/*==============================================================================
  REPORTING, AND THE SCHOOL'S OWN MODERATION HISTORY.

  🔴 A SEPARATE CONTROLLER BECAUSE THESE ARE NOT ADMIN ROUTES, and the route
  prefix is what a reader checks first. Putting "report this job" under
  /api/admin/ would make every future reader pause over whether it is gated.
==============================================================================*/

[ApiController]
[Route("api")]
[Authorize]
[Produces("application/json")]
public sealed class ReportsController : ControllerBase
{
    private readonly IAdminDeskService _desk;

    public ReportsController(IAdminDeskService desk) => _desk = desk;

    /// <summary>
    /// Report a job, a school or a teacher.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 NO PERMISSION — any signed-in account may report. A teacher reports a
    /// job; a school reports a profile. The reporter comes from the token
    /// (2.39), so reporting as somebody else cannot be expressed.
    /// </para>
    /// <para>
    /// ⚠️ IDEMPOTENT (2.48). A second report on the same thing by the same
    /// person returns the first one's uid and succeeds, with
    /// <c>alreadyReported</c> true. Pressing a button twice is not an error,
    /// and refusing it would invite a different reason to get through.
    /// </para>
    /// </remarks>
    [HttpPost("reports")]
    [ProducesResponseType(typeof(Response<SubmitReportOutcome>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> SubmitReport(
        [FromBody] SubmitReportRequest request, CancellationToken cancellationToken)
    {
        var outcome = await _desk.SubmitReportAsync(User, request, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(outcome, outcome.Message));
    }

    /// <summary>
    /// A school reading why its OWN job was pulled. 2.62's "not allowed, stated".
    /// </summary>
    /// <remarks>
    /// 🔒 SCOPED TO THE CALLER'S OWN ORGANISATION, inside the procedure. A
    /// school asking about somebody else's job gets an empty list — the same
    /// answer a job that never existed gives, because 2.6 says NOT_FOUND and
    /// never FORBIDDEN.
    ///
    /// 🔒 AND IT CARRIES NO REPORTER AND NO ADMINISTRATOR. The school learns
    /// what is wrong with the advert, which is what they can act on; they do
    /// not learn that somebody complained, or who pulled it.
    /// </remarks>
    [HttpGet("jobs/{jobUid:guid}/moderation")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<JobModerationEntryDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetOwnJobModeration(Guid jobUid, CancellationToken cancellationToken)
    {
        var rows = await _desk.GetModerationHistoryForSchoolAsync(User, jobUid, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(rows));
    }
}
