using System.Security.Claims;
using JP.Core.Constants;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Admin;
using JP.Infrastructure.Address;
using JP.Infrastructure.Repositories;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Services;

/*==============================================================================
  The admin operations desk. Phase 7B.

  ----------------------------------------------------------------------------
  🔒 FOUR PERMISSIONS, AND THE THREE ADMIN ROLES ARE GENUINELY DIFFERENT
  ----------------------------------------------------------------------------
      MODERATION.JOB      pull and restore         SUPER_ADMIN, MODERATION_ADMIN
      MODERATION.REPORT   the reports queue        SUPER_ADMIN, MODERATION_ADMIN
      ENQUIRY.MANAGE      the contact queue        SUPER_ADMIN, MODERATION_ADMIN
      CMS.MANAGE          FAQ, blocks, featured    SUPER_ADMIN

  🔴 VERIFICATION_ADMIN HOLDS NONE OF THEM, so a verifier calling any of these
  gets 403 — and that is the cross-check 7B's verification forces with devtools
  rather than trusting this list. jp_sso 008 asserts the closed sets at build
  time; this file is where the refusal happens at run time.

  ⚠️ EVERY GATE READS THE PERMISSION, NEVER THE ROLE. The seed is the authority
  on who holds what (AppConstants.PermissionCodes' own comment), and a role
  check here would be a second answer to a question the database already
  answers — the two drift, and the lenient one wins.

  ----------------------------------------------------------------------------
  🔴 REPORTING IS NOT AN ADMIN ACT
  ----------------------------------------------------------------------------
  SubmitReportAsync is gated on nothing but being signed in. A teacher reports
  a job; a school reports a profile. The reporter comes from the token (2.39),
  so "report this as somebody else" cannot be expressed.
==============================================================================*/

public interface IAdminDeskService
{
    Task<string> PullJobAsync(
        ClaimsPrincipal caller, Guid jobUid, JobModerationRequest request, CancellationToken cancellationToken);

    Task<string> RestoreJobAsync(
        ClaimsPrincipal caller, Guid jobUid, JobModerationRequest request, CancellationToken cancellationToken);

    Task<(IReadOnlyList<ModeratableJobDto> Rows, int Total)> SearchJobsForModerationAsync(
        ClaimsPrincipal caller, int? statusId, string? searchText, Guid? jobUid,
        bool reportedOnly, int pageNumber, int pageSize, CancellationToken cancellationToken);

    Task<IReadOnlyList<JobModerationEntryDto>> GetModerationHistoryForAdminAsync(
        ClaimsPrincipal caller, Guid jobUid, CancellationToken cancellationToken);

    Task<IReadOnlyList<JobModerationEntryDto>> GetModerationHistoryForSchoolAsync(
        ClaimsPrincipal caller, Guid jobUid, CancellationToken cancellationToken);

    Task<SubmitReportOutcome> SubmitReportAsync(
        ClaimsPrincipal caller, SubmitReportRequest request, CancellationToken cancellationToken);

    Task<(IReadOnlyList<ReportDto> Rows, int Total)> SearchReportsAsync(
        ClaimsPrincipal caller, int? statusId, string? entityType, int pageNumber, int pageSize,
        CancellationToken cancellationToken);

    Task<string> UpdateReportStatusAsync(
        ClaimsPrincipal caller, Guid reportUid, UpdateReportStatusRequest request,
        CancellationToken cancellationToken);

    Task<string> SaveFeaturedAsync(
        ClaimsPrincipal caller, SaveFeaturedRequest request, CancellationToken cancellationToken);

    Task<IReadOnlyList<FeaturedWindowDto>> ListFeaturedAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<string> RemoveFeaturedAsync(
        ClaimsPrincipal caller, string featuredType, long featuredId, CancellationToken cancellationToken);

    Task<IReadOnlyList<AdminFaqDto>> ListFaqsAsync(ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<string> SaveFaqAsync(ClaimsPrincipal caller, SaveFaqRequest request, CancellationToken cancellationToken);

    Task<string> DeleteFaqAsync(ClaimsPrincipal caller, int faqId, CancellationToken cancellationToken);

    Task<IReadOnlyList<AdminContentBlockDto>> ListContentBlocksAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<string> SaveContentBlockAsync(
        ClaimsPrincipal caller, SaveContentBlockRequest request, CancellationToken cancellationToken);

    Task<(IReadOnlyList<EnquiryDto> Rows, int Total)> SearchEnquiriesAsync(
        ClaimsPrincipal caller, bool? isResolved, int pageNumber, int pageSize,
        CancellationToken cancellationToken);

    Task<string> ResolveEnquiryAsync(
        ClaimsPrincipal caller, long enquiryId, ResolveEnquiryRequest request,
        CancellationToken cancellationToken);

    // ---- campus pins (SR-2) ------------------------------------------------

    /// <summary>The campus-pin desk. 🔒 MODERATION.CAMPUS_PIN.</summary>
    Task<(IReadOnlyList<CampusPinReviewDto> Rows, int Total)> SearchCampusPinsAsync(
        ClaimsPrincipal caller, bool needsReviewOnly, bool includeCleared, string? search,
        int pageNumber, int pageSize, CancellationToken cancellationToken);

    /// <summary>One campus's pin and its trail, by the opaque reference.</summary>
    Task<CampusPinReviewDto?> GetCampusPinAsync(
        ClaimsPrincipal caller, string pinRef, CancellationToken cancellationToken);

    /// <summary>
    /// The campus a registration created, and its trail.
    /// </summary>
    /// <remarks>
    /// 🔴 TWO READS IN TWO DATABASES, PAIRED HERE. jp_mdm answers what request
    /// this is; jp_app answers what campus it produced. Nothing joins them
    /// (2.2) — the same shape the analytics screen uses.
    /// </remarks>
    Task<CampusPinReviewDto?> GetCampusPinByRequestAsync(
        ClaimsPrincipal caller, long requestId, CancellationToken cancellationToken);

    Task<string> CorrectCampusPinAsync(
        ClaimsPrincipal caller, string pinRef, CorrectCampusPinRequest request,
        CancellationToken cancellationToken);

    Task<string> ClearCampusPinAsync(
        ClaimsPrincipal caller, string pinRef, ClearCampusPinRequest request,
        CancellationToken cancellationToken);
}

/// <summary>
/// What submitting a report answered with.
/// </summary>
/// <remarks>
/// ⚠️ <c>AlreadyReported</c> IS A SUCCESS. A second report on the same thing by
/// the same person returns the first one's uid (2.48) — the caller tells them
/// it is in hand, and nothing failed. An error here would invite somebody to
/// retry with a different reason to get it through.
/// </remarks>
public sealed class SubmitReportOutcome
{
    public Guid? ReportUid { get; set; }

    public bool AlreadyReported { get; set; }

    public string Message { get; set; } = string.Empty;
}

internal sealed class AdminDeskService : IAdminDeskService
{
    private readonly IAdminDeskRepository _desk;

    /*
      SR-2. jp_mdm, for ONE purpose: turning the bigint RequestId the admin
      route carries into the RequestUid jp_app stores on t_app_schools.

      🔴 NOT A JOIN, AND IT CANNOT BE (2.2). The two databases answer two
      questions and this class pairs the answers, which is the same thing
      AdminAnalyticsService does across three of them. The alternative — a
      SourceRequestUid lookup written as a cross-database join inside the jp_app
      procedure — is the thing the decision forbids.
    */
    private readonly IApprovalRepository _approvals;

    /*
      SR-2. The review threshold, from configuration.

      ⚠️ IOptions, NOT IOptionsMonitor. The value is read per call, so a change
      to appsettings.json is picked up by the configuration provider's own
      reload on the next request — there is nothing cached here to go stale, and
      a monitor would imply a change notification nothing subscribes to.
    */
    private readonly IOptions<CampusPinReviewOptions> _pinReview;

    public AdminDeskService(
        IAdminDeskRepository desk,
        IApprovalRepository approvals,
        IOptions<CampusPinReviewOptions> pinReview)
    {
        _desk = desk;
        _approvals = approvals;
        _pinReview = pinReview;
    }

    // ---- moderation --------------------------------------------------------

    public async Task<string> PullJobAsync(
        ClaimsPrincipal caller, Guid jobUid, JobModerationRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        EnsureCanModerateJobs(caller);

        var result = (await _desk
            .PullJobAsync(jobUid, request.Remarks, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();

        return result.Message;
    }

    public async Task<string> RestoreJobAsync(
        ClaimsPrincipal caller, Guid jobUid, JobModerationRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        EnsureCanModerateJobs(caller);

        var result = (await _desk
            .RestoreJobAsync(jobUid, request.Remarks, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();

        return result.Message;
    }

    /// <summary>The queue the moderation screen opens on. 🔒 MODERATION.JOB.</summary>
    /// <remarks>
    /// 🔴 THE SAME GATE AS PULLING, deliberately. Browsing every advert on the
    /// platform — including the pulled ones and what was said about them — is
    /// not a weaker act than pulling one; it is the reading half of the same
    /// job. A verifier who may approve a school still has no business here,
    /// and 7B's verification forces that negative.
    /// </remarks>
    public Task<(IReadOnlyList<ModeratableJobDto> Rows, int Total)> SearchJobsForModerationAsync(
        ClaimsPrincipal caller, int? statusId, string? searchText, Guid? jobUid,
        bool reportedOnly, int pageNumber, int pageSize, CancellationToken cancellationToken)
    {
        EnsureCanModerateJobs(caller);

        return _desk.SearchJobsForModerationAsync(
            statusId, searchText, jobUid, reportedOnly, pageNumber, pageSize, cancellationToken);
    }

    public Task<IReadOnlyList<JobModerationEntryDto>> GetModerationHistoryForAdminAsync(
        ClaimsPrincipal caller, Guid jobUid, CancellationToken cancellationToken)
    {
        EnsureCanModerateJobs(caller);

        /* 🔒 Null organisation — an admin may read any job's history. */
        return _desk.GetJobModerationHistoryAsync(jobUid, organizationUid: null, cancellationToken);
    }

    /// <summary>
    /// The school's own copy. 2.62's "not allowed, stated".
    /// </summary>
    /// <remarks>
    /// 🔒 SCOPED BY THE CALLER'S OWN ORGANISATION, taken from the token (2.39).
    /// A school asking about somebody else's job gets an empty list, which the
    /// controller returns as-is — the same answer a job that never existed
    /// gives, because 2.6 says NOT_FOUND and never FORBIDDEN.
    ///
    /// ⚠️ No permission check beyond being a school user. The remarks were
    /// written to be shown to this school, and a school member who can see the
    /// job can see why it is down — withholding that from an HR while showing
    /// it to the owner would leave the HR looking at a job that has silently
    /// stopped working.
    /// </remarks>
    public Task<IReadOnlyList<JobModerationEntryDto>> GetModerationHistoryForSchoolAsync(
        ClaimsPrincipal caller, Guid jobUid, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        var organizationUid = caller.GetOrganizationUid()
            ?? throw new ForbiddenException("Only a school account can read a job's moderation history here.");

        return _desk.GetJobModerationHistoryAsync(jobUid, organizationUid, cancellationToken);
    }

    // ---- reports -----------------------------------------------------------

    public async Task<SubmitReportOutcome> SubmitReportAsync(
        ClaimsPrincipal caller, SubmitReportRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);
        ArgumentNullException.ThrowIfNull(request);

        /*
          🔴 NO PERMISSION. Reporting is not an admin act — a teacher reports a
          job, a school reports a profile. The reporter comes from the token,
          so reporting AS somebody else cannot be expressed (2.39).
        */
        var result = await _desk
            .SubmitReportAsync(request, caller.GetUserUid(), cancellationToken)
            .ConfigureAwait(false);

        /*
          ⚠️ EnsureSuccess is NOT used here, because ALREADY_REPORTED arrives
          with Status 1 and a Code — a success that wants reporting as one.
        */
        if (!result.Succeeded)
        {
            throw ProcResultExtensions.ToException(result.Code, result.Message);
        }

        return new SubmitReportOutcome
        {
            ReportUid = result.ReportUid,
            AlreadyReported = string.Equals(result.Code, "ALREADY_REPORTED", StringComparison.Ordinal),
            Message = result.Message,
        };
    }

    public Task<(IReadOnlyList<ReportDto> Rows, int Total)> SearchReportsAsync(
        ClaimsPrincipal caller, int? statusId, string? entityType, int pageNumber, int pageSize,
        CancellationToken cancellationToken)
    {
        /*
          🔒 THE ONLY ROUTE THAT RETURNS A REPORTER'S UID, and it is gated on
          MODERATION.REPORT — which no school or teacher role holds (jp_sso
          008's guard asserts that). 7B's verification reads the raw bytes of
          every response a school or teacher CAN fetch and fails on the field
          name appearing in any of them.
        */
        EnsureCanHandleReports(caller);

        return _desk.SearchReportsAsync(statusId, entityType, pageNumber, pageSize, cancellationToken);
    }

    public async Task<string> UpdateReportStatusAsync(
        ClaimsPrincipal caller, Guid reportUid, UpdateReportStatusRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        EnsureCanHandleReports(caller);

        var result = (await _desk
            .UpdateReportStatusAsync(reportUid, request.StatusId, request.AdminRemarks,
                                     caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();

        return result.Message;
    }

    // ---- featured ----------------------------------------------------------

    public async Task<string> SaveFeaturedAsync(
        ClaimsPrincipal caller, SaveFeaturedRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        EnsureCanManageContent(caller);

        var result = (await _desk
            .SaveFeaturedAsync(request, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();

        return result.Message;
    }

    public Task<IReadOnlyList<FeaturedWindowDto>> ListFeaturedAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        EnsureCanManageContent(caller);

        return _desk.ListFeaturedAsync(cancellationToken);
    }

    public async Task<string> RemoveFeaturedAsync(
        ClaimsPrincipal caller, string featuredType, long featuredId, CancellationToken cancellationToken)
    {
        EnsureCanManageContent(caller);

        var result = (await _desk
            .RemoveFeaturedAsync(featuredType, featuredId, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();

        return result.Message;
    }

    // ---- the site's copy ---------------------------------------------------

    public Task<IReadOnlyList<AdminFaqDto>> ListFaqsAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        EnsureCanManageContent(caller);

        return _desk.ListFaqsAsync(cancellationToken);
    }

    public async Task<string> SaveFaqAsync(
        ClaimsPrincipal caller, SaveFaqRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        EnsureCanManageContent(caller);

        var result = (await _desk
            .SaveFaqAsync(request, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();

        return result.Message;
    }

    public async Task<string> DeleteFaqAsync(
        ClaimsPrincipal caller, int faqId, CancellationToken cancellationToken)
    {
        EnsureCanManageContent(caller);

        var result = (await _desk
            .DeleteFaqAsync(faqId, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();

        return result.Message;
    }

    public Task<IReadOnlyList<AdminContentBlockDto>> ListContentBlocksAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        EnsureCanManageContent(caller);

        return _desk.ListContentBlocksAsync(cancellationToken);
    }

    public async Task<string> SaveContentBlockAsync(
        ClaimsPrincipal caller, SaveContentBlockRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        EnsureCanManageContent(caller);

        var result = (await _desk
            .SaveContentBlockAsync(request, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();

        return result.Message;
    }

    // ---- enquiries ---------------------------------------------------------

    public Task<(IReadOnlyList<EnquiryDto> Rows, int Total)> SearchEnquiriesAsync(
        ClaimsPrincipal caller, bool? isResolved, int pageNumber, int pageSize,
        CancellationToken cancellationToken)
    {
        EnsureCanHandleEnquiries(caller);

        return _desk.SearchEnquiriesAsync(isResolved, pageNumber, pageSize, cancellationToken);
    }

    public async Task<string> ResolveEnquiryAsync(
        ClaimsPrincipal caller, long enquiryId, ResolveEnquiryRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        EnsureCanHandleEnquiries(caller);

        var result = (await _desk
            .ResolveEnquiryAsync(enquiryId, request.Remarks, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();

        return result.Message;
    }

    // ---- the gates ---------------------------------------------------------

    /*
      ⚠️ FOUR SEPARATE METHODS RATHER THAN ONE TAKING A PERMISSION CODE.

      One helper would read `Ensure(caller, PermissionCodes.CmsManage)` at every
      call site and the refusal message would have to be generic. These say what
      the caller was trying to do, which is the only part of a 403 a person can
      act on.
    */

    /// <summary>
    /// 🔒 MODERATION.JOB — SUPER_ADMIN and MODERATION_ADMIN. Not
    /// VERIFICATION_ADMIN: verification settles whether a school is real, once;
    /// moderation polices what it posts afterwards.
    /// </summary>
    private static void EnsureCanModerateJobs(ClaimsPrincipal caller)
    {
        ArgumentNullException.ThrowIfNull(caller);

        if (!caller.HasPermission(AppConstants.PermissionCodes.ModerationJob))
        {
            throw new ForbiddenException("You do not have permission to moderate job postings.");
        }
    }

    /// <summary>🔒 MODERATION.REPORT — and this is the reporter-identity gate.</summary>
    private static void EnsureCanHandleReports(ClaimsPrincipal caller)
    {
        ArgumentNullException.ThrowIfNull(caller);

        if (!caller.HasPermission(AppConstants.PermissionCodes.ModerationReport))
        {
            throw new ForbiddenException("You do not have permission to handle reports.");
        }
    }

    /// <summary>🔒 ENQUIRY.MANAGE — answering the contact form is not moderating.</summary>
    private static void EnsureCanHandleEnquiries(ClaimsPrincipal caller)
    {
        ArgumentNullException.ThrowIfNull(caller);

        if (!caller.HasPermission(AppConstants.PermissionCodes.EnquiryManage))
        {
            throw new ForbiddenException("You do not have permission to answer contact enquiries.");
        }
    }

    /// <summary>
    /// 🔒 CMS.MANAGE — SUPER_ADMIN alone. Covers the FAQ, the content blocks
    /// AND featured placement: all three decide what the public site shows.
    /// </summary>
    private static void EnsureCanManageContent(ClaimsPrincipal caller)
    {
        ArgumentNullException.ThrowIfNull(caller);

        if (!caller.HasPermission(AppConstants.PermissionCodes.CmsManage))
        {
            throw new ForbiddenException("You do not have permission to manage website content.");
        }
    }

    // ---- campus pins (SR-2) ------------------------------------------------

    public async Task<(IReadOnlyList<CampusPinReviewDto> Rows, int Total)> SearchCampusPinsAsync(
        ClaimsPrincipal caller, bool needsReviewOnly, bool includeCleared, string? search,
        int pageNumber, int pageSize, CancellationToken cancellationToken)
    {
        EnsureCanManageCampusPins(caller);

        var result = await _desk
            .SearchCampusPinsAsync(
                _pinReview.Value.MaxDistanceKm,
                branchUid: null,
                sourceRequestUid: null,
                needsReviewOnly,
                includeCleared,
                search,
                pageNumber,
                pageSize,
                /*
                  🔴 NO TRAIL ON THE LIST. Twenty trails for a page nobody has
                  opened is twenty queries nobody asked for. The screens read an
                  empty array beside a non-null LastActionOn as "not loaded".
                */
                includeTrail: false,
                cancellationToken)
            .ConfigureAwait(false);

        return (result.Rows, result.Total);
    }

    public async Task<CampusPinReviewDto?> GetCampusPinAsync(
        ClaimsPrincipal caller, string pinRef, CancellationToken cancellationToken)
    {
        EnsureCanManageCampusPins(caller);

        var branchUid = ParsePinRef(pinRef);

        var result = await ReadOneCampusPinAsync(
                branchUid: branchUid, sourceRequestUid: null, cancellationToken)
            .ConfigureAwait(false);

        return result;
    }

    public async Task<CampusPinReviewDto?> GetCampusPinByRequestAsync(
        ClaimsPrincipal caller, long requestId, CancellationToken cancellationToken)
    {
        EnsureCanManageCampusPins(caller);

        /*
          🔴 STEP ONE, IN jp_mdm: what request is this? The admin route carries
          the bigint RequestId the approval queue uses; jp_app stores
          t_app_schools.SourceRequestUid, which is the request's UID. Nothing
          may join the two (2.2), so the pairing happens here.

          ⚠️ A REQUEST THAT DOES NOT EXIST IS null, NOT AN ERROR. The contract
          is CampusPinReview | null, and "there is no campus for that request"
          and "there is no such request" are the same answer from the client's
          point of view — it has nothing to show either way, and distinguishing
          them would tell a prober which request ids are real.
        */
        var detail = await _approvals.GetByIdAsync(requestId, cancellationToken).ConfigureAwait(false);

        if (detail is null)
        {
            return null;
        }

        /* Step two, in jp_app: what campus did it produce? */
        var row = await ReadOneCampusPinAsync(
                branchUid: null, sourceRequestUid: detail.Header.RequestUid, cancellationToken)
            .ConfigureAwait(false);

        if (row is not null)
        {
            /*
              🔴 THE ONE PATH THAT CAN FILL THIS IN HONESTLY. jp_app does not
              hold the bigint id and resolving it per row on the list would be a
              cross-database lookup per row for a number the list does not show
              (CampusPinReviewDto.RequestId says the same from the other side).
              Here it is simply the id we were asked about.
            */
            row.RequestId = requestId;
        }

        return row;
    }

    public async Task<string> CorrectCampusPinAsync(
        ClaimsPrincipal caller, string pinRef, CorrectCampusPinRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        EnsureCanManageCampusPins(caller);

        var branchUid = ParsePinRef(pinRef);

        /*
          ⚠️ NOT VALIDATED HERE BEYOND THE REFERENCE. The coordinate range, the
          empty remark, the unchanged pin and the missing campus are all refused
          by the procedure with a named code (2.21), and EnsureSuccess maps each
          one to the right exception. A second copy of those rules in C# would
          be a second answer to the same question — and the procedure's is the
          one that also protects a hand-run EXEC.
        */
        var result = (await _desk
            .CorrectCampusPinAsync(
                branchUid, request.Latitude, request.Longitude, request.Remarks,
                caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();

        return result.Message;
    }

    public async Task<string> ClearCampusPinAsync(
        ClaimsPrincipal caller, string pinRef, ClearCampusPinRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        EnsureCanManageCampusPins(caller);

        var branchUid = ParsePinRef(pinRef);

        var result = (await _desk
            .ClearCampusPinAsync(branchUid, request.Remarks, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false)).EnsureSuccess();

        return result.Message;
    }

    /// <summary>
    /// 🔒 MODERATION.CAMPUS_PIN — SUPER_ADMIN and MODERATION_ADMIN.
    /// </summary>
    /// <remarks>
    /// 🔴 THE SAME GATE FOR READING AND FOR ACTING, deliberately, and 025's
    /// argument applies unchanged: browsing every campus on the platform with
    /// its coordinates and its correction history is not a weaker act than
    /// correcting one — it is the reading half of the same job.
    ///
    /// ⚠️ NOT VERIFICATION.SCHOOL, which was the first choice, and NOT
    /// MODERATION.REPORT. AppConstants.PermissionCodes.ModerationCampusPin and
    /// jp_sso/03_seed/009 both carry the argument; the short version is that a
    /// verification is settled once before a school's first job, and a campus
    /// pin is corrected years later about a campus that did not exist then.
    /// </remarks>
    private static void EnsureCanManageCampusPins(ClaimsPrincipal caller)
    {
        ArgumentNullException.ThrowIfNull(caller);

        if (!caller.HasPermission(AppConstants.PermissionCodes.ModerationCampusPin))
        {
            throw new ForbiddenException("You do not have permission to correct campus map pins.");
        }
    }

    /// <summary>
    /// Turns the opaque <c>pinRef</c> back into the identity the server put in
    /// it.
    /// </summary>
    /// <remarks>
    /// 🔴 AN UNPARSEABLE REFERENCE IS NOT_FOUND, NEVER A 400. The format is the
    /// server's business (the contract says so), so "that is not a valid pinRef"
    /// would be the API publishing the format in an error message and telling a
    /// prober when they had guessed the shape right. 2.6's rule: not found, and
    /// never anything more specific.
    ///
    /// ⚠️ THE ONE PLACE THAT KNOWS THE FORMAT. When the desk gains
    /// registration-sourced rows and the reference becomes a discriminated
    /// string, this method changes and nothing else does — not the controller,
    /// not the client.
    /// </remarks>
    private static Guid ParsePinRef(string pinRef)
    {
        if (!Guid.TryParse(pinRef, out var branchUid) || branchUid == Guid.Empty)
        {
            throw new NotFoundException("That campus was not found.");
        }

        return branchUid;
    }

    /// <summary>
    /// A single campus-pin row with its trail attached, or null.
    /// </summary>
    /// <remarks>
    /// ⚠️ includeCleared IS TRUE AND needsReviewOnly IS FALSE on both single
    /// reads. A detail panel asked for a specific campus must answer about that
    /// campus — filtering it out because it is cleared, or because its pin is
    /// fine, would return null for a row the admin is looking at.
    /// </remarks>
    private async Task<CampusPinReviewDto?> ReadOneCampusPinAsync(
        Guid? branchUid, Guid? sourceRequestUid, CancellationToken cancellationToken)
    {
        var result = await _desk
            .SearchCampusPinsAsync(
                _pinReview.Value.MaxDistanceKm,
                branchUid,
                sourceRequestUid,
                needsReviewOnly: false,
                includeCleared: true,
                search: null,
                pageNumber: 1,
                pageSize: 1,
                includeTrail: true,
                cancellationToken)
            .ConfigureAwait(false);

        return result.Rows.Count == 0 ? null : result.Rows[0];
    }
}
