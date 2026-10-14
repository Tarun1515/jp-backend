using System.Security.Claims;
using JP.Core.Constants;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Admin;
using JP.Infrastructure.Repositories;

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

    public AdminDeskService(IAdminDeskRepository desk) => _desk = desk;

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
}
