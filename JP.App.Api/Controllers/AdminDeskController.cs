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

    // ---- campus pins (SR-2) ------------------------------------------------

    /*==========================================================================
      THE CAMPUS-PIN DESK. 🔒 MODERATION.CAMPUS_PIN on every route, in the
      service.

      🔴 MOVED HERE FROM ReportsController ON 14 Nov 2026, AND THE SCREEN HAD
      NEVER WORKED.

      These actions were written at the foot of this file but INSIDE
      ReportsController, which carries [Route("api")] — so they served
      /api/campus-pins while jp-admin's campus-pin.service.ts called
      /api/admin/desk/campus-pins, which is also what that service's own
      documentation comment says and what this block's heading implies. Every
      call 404ed, and the screen's error copy — "the review list could not be
      loaded … try again in a moment" — reads as a passing blip rather than a
      route that does not exist.

      ⚠️ NOTHING CAUGHT IT, AND TWO THINGS CAME CLOSE. swagger.mjs asserts the
      endpoints are DOCUMENTED, which they were, at the wrong prefix. And
      campus-pin.mjs found the 404 first — then I "fixed the suite" by pointing
      it at the server's actual path, which is the moment the real bug was
      available and was walked past. The suite now asserts the prefix the
      CLIENT uses, so the two can never drift apart silently again.

      ⚠️ ReportsController's own header says it exists "BECAUSE THESE ARE NOT
      ADMIN ROUTES". That was true of its two actions and never true of these
      six, which sit behind an admin permission and are read by an admin
      screen. Appending to the end of a file is not the same as appending to
      the right class.

      ⚠️ NOT VERIFICATION.SCHOOL, which was the first choice: a verification is
      settled ONCE before a school's first job goes live, and a campus pin is
      corrected years later about a campus that did not exist then.
      AppConstants.PermissionCodes.ModerationCampusPin carries the argument and
      jp_sso/03_seed/009 asserts the closed set of holders.

      🔴 pinRef IS AN OPAQUE STRING, so the route parameter is {pinRef} and NOT
      {branchUid:guid}. A :guid constraint would publish the format in the URL
      template, which is exactly what the contract promises not to do — and
      would turn a reference the desk may later discriminate ("B:..." / "R:...")
      into a 404 from the router instead of a decision the service makes. The
      service is the one place that knows the format.

      🔴 THE THRESHOLD IS NOT A QUERY PARAMETER, and it must not become one. It
      is configuration (CampusPinReview:MaxDistanceKm); a client-supplied
      threshold would let anybody with the permission produce whatever queue
      they wanted and would be a second answer to a question the configuration
      answers.
    ==========================================================================*/

    /// <summary>
    /// Campus pins, the ones needing review first. 🔒 MODERATION.CAMPUS_PIN.
    /// </summary>
    /// <remarks>
    /// 🔴 EVERY ROW CARRIES <c>thresholdKm</c>. The client keeps no copy of the
    /// server's setting — one would be silently wrong the day it is configured
    /// to anything else, and the screen would then explain the queue using the
    /// wrong number.
    ///
    /// ⚠️ <c>needsReview</c> IS NOT <c>distanceKm &gt; thresholdKm</c>. A
    /// CLEARED pin is a large distance an administrator has judged correct, and
    /// <c>isCleared</c> sits beside it so the screen can say so.
    ///
    /// ⚠️ <c>trail</c> IS EMPTY HERE. Twenty trails for a page nobody opened is
    /// twenty queries nobody asked for; the single-row reads below populate it.
    /// </remarks>
    [HttpGet("campus-pins")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<CampusPinReviewDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> SearchCampusPins(
        [FromQuery] bool needsReviewOnly = false,
        [FromQuery] bool includeCleared = true,
        [FromQuery] string? search = null,
        [FromQuery] int pageNumber = 1,
        [FromQuery] int pageSize = 20,
        CancellationToken cancellationToken = default)
    {
        var (rows, total) = await _desk
            .SearchCampusPinsAsync(
                User, needsReviewOnly, includeCleared, search, pageNumber, pageSize, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Paged(rows, total));
    }

    /// <summary>One campus's pin and its trail. 🔒 MODERATION.CAMPUS_PIN.</summary>
    /// <remarks>
    /// ⚠️ A reference that resolves to nothing — including one that is not even
    /// the right shape — is a 404 and never a 400. The format is the server's
    /// business, so an error naming it would publish the format and tell a
    /// prober when they had guessed right (2.6).
    /// </remarks>
    [HttpGet("campus-pins/{pinRef}")]
    [ProducesResponseType(typeof(Response<CampusPinReviewDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetCampusPin(string pinRef, CancellationToken cancellationToken)
    {
        var row = await _desk.GetCampusPinAsync(User, pinRef, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(row));
    }

    /// <summary>
    /// The campus a registration created, and its trail.
    /// 🔒 MODERATION.CAMPUS_PIN.
    /// </summary>
    /// <remarks>
    /// 🔴 TWO DATABASES, PAIRED IN THE SERVICE. jp_mdm says what request this
    /// is; jp_app says what campus it produced, matched on
    /// t_app_schools.SourceRequestUid. Nothing joins them (2.2).
    ///
    /// ⚠️ IT RESOLVES TO THE HEAD OFFICE — the campus a registration creates,
    /// which 003 calls "the branch a school's own address belongs to". A school
    /// that has since added campuses has them on the list, not here.
    ///
    /// ⚠️ A request with no campus, and a request that does not exist, both
    /// answer with a null payload rather than different errors. The client has
    /// nothing to show either way, and distinguishing them would tell a prober
    /// which request ids are real.
    /// </remarks>
    [HttpGet("campus-pins/by-request/{requestId:long}")]
    [ProducesResponseType(typeof(Response<CampusPinReviewDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetCampusPinByRequest(
        long requestId, CancellationToken cancellationToken)
    {
        var row = await _desk.GetCampusPinByRequestAsync(User, requestId, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(row));
    }

    /// <summary>Move a campus pin, with a reason. 🔒 MODERATION.CAMPUS_PIN.</summary>
    /// <remarks>
    /// 🔴 A SEPARATE ACT FROM CLEARING, not the same endpoint called with the
    /// old coordinates. Posting the unchanged pin back through here is REFUSED
    /// by name: it would write a correction that corrected nothing, and the
    /// trail would then read "corrected by X" about somebody who deliberately
    /// did not move it.
    ///
    /// 🔴 THE PREVIOUS PIN IS RECORDED. The school chose it, and an append-only
    /// log row is what makes this reversible and what the school is shown.
    /// </remarks>
    [HttpPost("campus-pins/{pinRef}/correct")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> CorrectCampusPin(
        string pinRef, [FromBody] CorrectCampusPinRequest request, CancellationToken cancellationToken)
    {
        var message = await _desk.CorrectCampusPinAsync(User, pinRef, request, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success<object?>(null, message));
    }

    /// <summary>
    /// Record that a campus pin's distance from its stated address is correct.
    /// 🔒 MODERATION.CAMPUS_PIN.
    /// </summary>
    /// <remarks>
    /// 🔴 THIS MOVES NOTHING. Not the coordinates, not RowVersion, not
    /// ModifiedOn — 028's build guard asserts the procedure writes nothing at
    /// all on the campus. It writes one trail row saying somebody judged the
    /// distance acceptable, and the campus stops needing review because that
    /// verdict is derived from the trail.
    ///
    /// ⚠️ THE JUDGEMENT LAPSES IF THE SCHOOL MOVES THE PIN. It is recorded
    /// against the exact pin that was judged, so there is no stale flag and no
    /// sweep to forget.
    /// </remarks>
    [HttpPost("campus-pins/{pinRef}/clear")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> ClearCampusPin(
        string pinRef, [FromBody] ClearCampusPinRequest request, CancellationToken cancellationToken)
    {
        var message = await _desk.ClearCampusPinAsync(User, pinRef, request, cancellationToken)
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
