using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Domain.Admin;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

/*==============================================================================
  The admin operations desk's data access. Phase 7B.

  ----------------------------------------------------------------------------
  🔒 THE REPORTER'S UID CROSSES THIS BOUNDARY EXACTLY ONCE
  ----------------------------------------------------------------------------
  ReportDto carries ReportedByUserUid, and SearchReportsAsync is the only
  method here that returns it. Nothing in this file reads it into any other
  shape, and 025 carries a build guard naming the only procedures allowed to
  project the column — so a new read that wanted it would fail the build before
  it could reach a school-facing endpoint.

  ----------------------------------------------------------------------------
  ⚠️ EVERY WRITE RETURNS ProcResult AND THE SERVICE DECIDES WHAT TO THROW
  ----------------------------------------------------------------------------
  The procedures report refusals as Status 0 with a Code (2.21), and
  EnsureSuccess maps the code to the right exception. This file never branches
  on a message.
==============================================================================*/

/// <summary>A featured window, before the service splits it by type.</summary>
internal sealed class FeaturedWindowRow
{
    public long FeaturedId { get; set; }
    public string FeaturedType { get; set; } = string.Empty;
    public Guid EntityUid { get; set; }
    public string EntityName { get; set; } = string.Empty;
    public string? OwnerName { get; set; }
    public DateTime FromDate { get; set; }
    public DateTime ToDate { get; set; }
    public int DisplayOrder { get; set; }

    /// <summary>
    /// ⚠️ tinyint on the wire, bool in the DTO. 2.61's sibling problem: Dapper
    /// maps tinyint to bool happily, but only if the property IS a bool — and
    /// a row type that mirrors the column type makes the conversion explicit
    /// at the one place that knows both.
    /// </summary>
    public byte IsLiveToday { get; set; }

    public string? EntityStatusName { get; set; }
}

internal interface IAdminDeskRepository
{
    // ---- moderation --------------------------------------------------------

    Task<ProcResult> PullJobAsync(
        Guid jobUid, string remarks, long actorUserId, CancellationToken cancellationToken);

    Task<ProcResult> RestoreJobAsync(
        Guid jobUid, string remarks, long actorUserId, CancellationToken cancellationToken);

    Task<(IReadOnlyList<ModeratableJobDto> Rows, int Total)> SearchJobsForModerationAsync(
        int? statusId, string? searchText, Guid? jobUid, bool reportedOnly,
        int pageNumber, int pageSize, CancellationToken cancellationToken);

    /// <summary>
    /// A job's moderation history. Pass <paramref name="organizationUid"/> for a
    /// SCHOOL caller and null for an admin.
    /// </summary>
    /// <remarks>
    /// 🔒 The scoping happens inside the procedure, so a school asking about
    /// somebody else's job gets zero rows rather than a different answer from
    /// a C# check that might disagree with it.
    /// </remarks>
    Task<IReadOnlyList<JobModerationEntryDto>> GetJobModerationHistoryAsync(
        Guid jobUid, Guid? organizationUid, CancellationToken cancellationToken);

    // ---- reports -----------------------------------------------------------

    Task<SubmitReportResult> SubmitReportAsync(
        SubmitReportRequest request, Guid reporterUserUid, CancellationToken cancellationToken);

    /// <summary>
    /// 🔒 THE ONLY METHOD HERE THAT RETURNS THE REPORTER. Admin callers only —
    /// the service gates it on MODERATION.REPORT.
    /// </summary>
    Task<(IReadOnlyList<ReportDto> Rows, int Total)> SearchReportsAsync(
        int? statusId, string? entityType, int pageNumber, int pageSize,
        CancellationToken cancellationToken);

    Task<ProcResult> UpdateReportStatusAsync(
        Guid reportUid, int statusId, string? adminRemarks, long actorUserId,
        CancellationToken cancellationToken);

    // ---- featured ----------------------------------------------------------

    Task<ProcResult> SaveFeaturedAsync(
        SaveFeaturedRequest request, long actorUserId, CancellationToken cancellationToken);

    Task<IReadOnlyList<FeaturedWindowDto>> ListFeaturedAsync(CancellationToken cancellationToken);

    Task<ProcResult> RemoveFeaturedAsync(
        string featuredType, long featuredId, long actorUserId, CancellationToken cancellationToken);

    // ---- the site's copy ---------------------------------------------------

    Task<IReadOnlyList<AdminFaqDto>> ListFaqsAsync(CancellationToken cancellationToken);

    Task<ProcResult> SaveFaqAsync(
        SaveFaqRequest request, long actorUserId, CancellationToken cancellationToken);

    Task<ProcResult> DeleteFaqAsync(
        int faqId, long actorUserId, CancellationToken cancellationToken);

    Task<IReadOnlyList<AdminContentBlockDto>> ListContentBlocksAsync(CancellationToken cancellationToken);

    Task<ProcResult> SaveContentBlockAsync(
        SaveContentBlockRequest request, long actorUserId, CancellationToken cancellationToken);

    // ---- enquiries ---------------------------------------------------------

    Task<(IReadOnlyList<EnquiryDto> Rows, int Total)> SearchEnquiriesAsync(
        bool? isResolved, int pageNumber, int pageSize, CancellationToken cancellationToken);

    Task<ProcResult> ResolveEnquiryAsync(
        long enquiryId, string remarks, long actorUserId, CancellationToken cancellationToken);
}

/// <summary>What USP_SubmitReport answers with.</summary>
internal sealed class SubmitReportResult : ProcResult
{
    /// <summary>
    /// ⚠️ Set on the IDEMPOTENT path too, and that is the point: a second
    /// report returns the FIRST one's uid with Status 1 and
    /// Code = ALREADY_REPORTED, so the caller can tell them it is in hand
    /// without the request having failed (2.48).
    /// </summary>
    public Guid? ReportUid { get; set; }
}

internal sealed class AdminDeskRepository : BaseRepository, IAdminDeskRepository
{
    public AdminDeskRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<AdminDeskRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.App;

    // ---- moderation --------------------------------------------------------

    public Task<ProcResult> PullJobAsync(
        Guid jobUid, string remarks, long actorUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@JobUid", jobUid, DbType.Guid);
        p.Add("@Remarks", remarks, DbType.String);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_PullJob", p, cancellationToken);
    }

    public Task<ProcResult> RestoreJobAsync(
        Guid jobUid, string remarks, long actorUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@JobUid", jobUid, DbType.Guid);
        p.Add("@Remarks", remarks, DbType.String);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_RestoreJob", p, cancellationToken);
    }

    public Task<(IReadOnlyList<ModeratableJobDto> Rows, int Total)> SearchJobsForModerationAsync(
        int? statusId, string? searchText, Guid? jobUid, bool reportedOnly,
        int pageNumber, int pageSize, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@StatusId", statusId, DbType.Int32);
        p.Add("@SearchText", searchText, DbType.String);
        p.Add("@JobUid", jobUid, DbType.Guid);
        p.Add("@ReportedOnly", reportedOnly, DbType.Boolean);
        p.Add("@PageNumber", pageNumber, DbType.Int32);
        p.Add("@PageSize", pageSize, DbType.Int32);

        return QueryMultipleAsync<(IReadOnlyList<ModeratableJobDto>, int)>(
            "USP_SearchJobsForModeration",
            async grid =>
            {
                var rows = (await grid.ReadAsync<ModeratableJobDto>().ConfigureAwait(false)).AsList();
                var total = await grid.ReadFirstOrDefaultAsync<int>().ConfigureAwait(false);

                return (rows, total);
            },
            p,
            cancellationToken);
    }

    public Task<IReadOnlyList<JobModerationEntryDto>> GetJobModerationHistoryAsync(
        Guid jobUid, Guid? organizationUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@JobUid", jobUid, DbType.Guid);
        p.Add("@OrganizationUid", organizationUid, DbType.Guid);

        return QueryAsync<JobModerationEntryDto>("USP_GetJobModerationHistory", p, cancellationToken);
    }

    // ---- reports -----------------------------------------------------------

    public Task<SubmitReportResult> SubmitReportAsync(
        SubmitReportRequest request, Guid reporterUserUid, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var p = new DynamicParameters();
        p.Add("@ReasonId", request.ReasonId, DbType.Int32);
        p.Add("@EntityType", request.EntityType, DbType.String);
        p.Add("@EntityUid", request.EntityUid, DbType.Guid);
        p.Add("@Description", request.Description, DbType.String);
        p.Add("@ReporterUserUid", reporterUserUid, DbType.Guid);

        return QuerySingleAsync<SubmitReportResult>("USP_SubmitReport", p, cancellationToken);
    }

    public Task<(IReadOnlyList<ReportDto> Rows, int Total)> SearchReportsAsync(
        int? statusId, string? entityType, int pageNumber, int pageSize,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@StatusId", statusId, DbType.Int32);
        p.Add("@EntityType", entityType, DbType.String);
        p.Add("@PageNumber", pageNumber, DbType.Int32);
        p.Add("@PageSize", pageSize, DbType.Int32);

        return QueryMultipleAsync<(IReadOnlyList<ReportDto>, int)>(
            "USP_SearchReports",
            async grid =>
            {
                var rows = (await grid.ReadAsync<ReportDto>().ConfigureAwait(false)).AsList();
                var total = await grid.ReadFirstOrDefaultAsync<int>().ConfigureAwait(false);

                return (rows, total);
            },
            p,
            cancellationToken);
    }

    public Task<ProcResult> UpdateReportStatusAsync(
        Guid reportUid, int statusId, string? adminRemarks, long actorUserId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@ReportUid", reportUid, DbType.Guid);
        p.Add("@NewStatusId", statusId, DbType.Int32);
        p.Add("@AdminRemarks", adminRemarks, DbType.String);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_UpdateReportStatus", p, cancellationToken);
    }

    // ---- featured ----------------------------------------------------------

    public Task<ProcResult> SaveFeaturedAsync(
        SaveFeaturedRequest request, long actorUserId, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var p = new DynamicParameters();
        p.Add("@FromDate", request.FromDate.Date, DbType.Date);
        p.Add("@ToDate", request.ToDate.Date, DbType.Date);
        p.Add("@DisplayOrder", request.DisplayOrder, DbType.Int32);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        /*
          ⚠️ TWO PROCEDURES, ONE REQUEST SHAPE. The alternative was one
          procedure with a type parameter and two nullable uids, which is the
          shape 7B-0 rejected for the job-by-uid read: two nullable Guids side
          by side, and a call site that transposes them compiles.
        */
        if (string.Equals(request.FeaturedType, "SCHOOL", StringComparison.OrdinalIgnoreCase))
        {
            p.Add("@SchoolUid", request.EntityUid, DbType.Guid);

            return QuerySingleAsync<ProcResult>("USP_SaveFeaturedSchool", p, cancellationToken);
        }

        p.Add("@JobUid", request.EntityUid, DbType.Guid);

        return QuerySingleAsync<ProcResult>("USP_SaveFeaturedJob", p, cancellationToken);
    }

    public Task<IReadOnlyList<FeaturedWindowDto>> ListFeaturedAsync(CancellationToken cancellationToken)
    {
        return QueryMultipleAsync<IReadOnlyList<FeaturedWindowDto>>(
            "USP_ListFeatured",
            async grid =>
            {
                /*
                  ⚠️ Two result sets — jobs then schools — concatenated here.
                  The procedure keeps them apart because the two tables differ;
                  the admin screen shows one list, so the joining happens once,
                  here, rather than in the screen.
                */
                var jobs = (await grid.ReadAsync<FeaturedWindowRow>().ConfigureAwait(false)).AsList();
                var schools = (await grid.ReadAsync<FeaturedWindowRow>().ConfigureAwait(false)).AsList();

                return jobs.Concat(schools).Select(Map).ToList();
            },
            parameters: null,
            cancellationToken);
    }

    public Task<ProcResult> RemoveFeaturedAsync(
        string featuredType, long featuredId, long actorUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@FeaturedType", featuredType, DbType.String);
        p.Add("@FeaturedId", featuredId, DbType.Int64);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_RemoveFeatured", p, cancellationToken);
    }

    // ---- the site's copy ---------------------------------------------------

    public Task<IReadOnlyList<AdminFaqDto>> ListFaqsAsync(CancellationToken cancellationToken) =>
        QueryAsync<AdminFaqDto>("USP_ListFaqsForAdmin", parameters: null, cancellationToken);

    public Task<ProcResult> SaveFaqAsync(
        SaveFaqRequest request, long actorUserId, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var p = new DynamicParameters();
        p.Add("@FaqId", request.FaqId, DbType.Int32);
        p.Add("@Category", request.Category, DbType.String);
        p.Add("@Question", request.Question, DbType.String);
        p.Add("@Answer", request.Answer, DbType.String);
        p.Add("@DisplayOrder", request.DisplayOrder, DbType.Int32);
        p.Add("@IsActive", request.IsActive ? (byte)1 : (byte)0, DbType.Byte);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_SaveFaq", p, cancellationToken);
    }

    public Task<ProcResult> DeleteFaqAsync(
        int faqId, long actorUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@FaqId", faqId, DbType.Int32);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_DeleteFaq", p, cancellationToken);
    }

    public Task<IReadOnlyList<AdminContentBlockDto>> ListContentBlocksAsync(CancellationToken cancellationToken) =>
        QueryAsync<AdminContentBlockDto>("USP_ListContentBlocksForAdmin", parameters: null, cancellationToken);

    public Task<ProcResult> SaveContentBlockAsync(
        SaveContentBlockRequest request, long actorUserId, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var p = new DynamicParameters();
        p.Add("@BlockKey", request.BlockKey, DbType.String);
        p.Add("@BlockTitle", request.BlockTitle, DbType.String);
        p.Add("@BlockContent", request.BlockContent, DbType.String);
        p.Add("@ImagePath", request.ImagePath, DbType.String);
        p.Add("@DisplayOrder", request.DisplayOrder, DbType.Int32);
        p.Add("@IsActive", request.IsActive ? (byte)1 : (byte)0, DbType.Byte);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_SaveContentBlock", p, cancellationToken);
    }

    // ---- enquiries ---------------------------------------------------------

    public Task<(IReadOnlyList<EnquiryDto> Rows, int Total)> SearchEnquiriesAsync(
        bool? isResolved, int pageNumber, int pageSize, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@IsResolved", isResolved is null ? null : (isResolved.Value ? (byte)1 : (byte)0), DbType.Byte);
        p.Add("@PageNumber", pageNumber, DbType.Int32);
        p.Add("@PageSize", pageSize, DbType.Int32);

        return QueryMultipleAsync<(IReadOnlyList<EnquiryDto>, int)>(
            "USP_SearchEnquiries",
            async grid =>
            {
                var rows = (await grid.ReadAsync<EnquiryDto>().ConfigureAwait(false)).AsList();
                var total = await grid.ReadFirstOrDefaultAsync<int>().ConfigureAwait(false);

                return (rows, total);
            },
            p,
            cancellationToken);
    }

    public Task<ProcResult> ResolveEnquiryAsync(
        long enquiryId, string remarks, long actorUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@EnquiryId", enquiryId, DbType.Int64);
        p.Add("@Remarks", remarks, DbType.String);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_ResolveEnquiry", p, cancellationToken);
    }

    private static FeaturedWindowDto Map(FeaturedWindowRow row) => new()
    {
        FeaturedId = row.FeaturedId,
        FeaturedType = row.FeaturedType,
        EntityUid = row.EntityUid,
        EntityName = row.EntityName,
        OwnerName = row.OwnerName,
        FromDate = row.FromDate,
        ToDate = row.ToDate,
        DisplayOrder = row.DisplayOrder,
        IsLiveToday = row.IsLiveToday == 1,
        EntityStatusName = row.EntityStatusName,
    };
}
