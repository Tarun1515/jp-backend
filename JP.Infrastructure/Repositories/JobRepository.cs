using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Domain.Jobs;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

/// <summary>The raw shape USP_PublishJob returns.</summary>
internal sealed class PublishRow : ProcResult
{
    public byte Consumed { get; set; }
    public byte? SourceId { get; set; }
}

/// <summary>
/// Jobs, in jp_app.
/// </summary>
/// <remarks>
/// 🔴 Every method takes <c>schoolId</c> and <c>userUid</c> and the procedures
/// join through <c>fn_VisibleBranches</c>. Neither ever comes from a request
/// body — the service resolves both from the token (2.39).
/// </remarks>
internal interface IJobRepository
{
    Task<IReadOnlyList<JobListItemDto>> GetListAsync(
        long schoolId, Guid userUid, int? statusId, long? branchId, CancellationToken cancellationToken);

    Task<JobDetailDto?> GetByIdAsync(
        long schoolId, Guid userUid, long jobId, CancellationToken cancellationToken);

    Task<ProcResult> SaveAsync(
        long schoolId, Guid userUid, SaveJobRequest request, long actorUserId,
        CancellationToken cancellationToken);

    Task<PublishRow> PublishAsync(
        long schoolId, Guid userUid, long jobId, Guid ownerUid,
        int featureId, int gatingModeId, bool hasMapping, bool isIncluded, int? quotaPerPeriod,
        int expectedPlanId, long actorUserId, CancellationToken cancellationToken);

    Task<ProcResult> CloseAsync(
        long schoolId, Guid userUid, long jobId, long actorUserId, CancellationToken cancellationToken);

    Task<SchoolJobStatsDto> GetStatsAsync(
        long schoolId, Guid userUid, CancellationToken cancellationToken);
}

internal sealed class JobRepository : BaseRepository, IJobRepository
{
    public JobRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<JobRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.App;

    public Task<IReadOnlyList<JobListItemDto>> GetListAsync(
        long schoolId, Guid userUid, int? statusId, long? branchId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@StatusId", statusId, DbType.Int32);
        p.Add("@BranchId", branchId, DbType.Int64);

        return QueryAsync<JobListItemDto>("USP_GetJobList", p, cancellationToken);
    }

    public Task<JobDetailDto?> GetByIdAsync(
        long schoolId, Guid userUid, long jobId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@JobId", jobId, DbType.Int64);

        return QueryMultipleAsync<JobDetailDto?>("USP_GetJobById", async grid =>
        {
            var job = await grid.ReadFirstOrDefaultAsync<JobDetailDto>().ConfigureAwait(false);

            if (job is null)
            {
                return null;
            }

            job.SubjectIds = (await grid.ReadAsync<int>().ConfigureAwait(false)).ToList();
            job.ClassLevelIds = (await grid.ReadAsync<int>().ConfigureAwait(false)).ToList();

            // Presentation only — the procedure is what enforces it.
            job.StructuralFieldsLocked = job.StoredStatusId == JobStatus.Active;

            return job;
        }, p, cancellationToken);
    }

    public Task<ProcResult> SaveAsync(
        long schoolId, Guid userUid, SaveJobRequest request, long actorUserId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@JobId", request.JobId, DbType.Int64);
        p.Add("@BranchId", request.BranchId, DbType.Int64);
        p.Add("@JobTitle", request.JobTitle, DbType.String, size: 200);
        p.Add("@SubjectId", request.SubjectId, DbType.Int32);
        p.Add("@DesignationId", request.DesignationId, DbType.Int32);
        p.Add("@QualificationId", request.QualificationId, DbType.Int32);
        p.Add("@EmploymentTypeId", request.EmploymentTypeId, DbType.Int32);
        p.Add("@NoOfVacancies", request.NoOfVacancies, DbType.Int32);
        p.Add("@MinExperienceMonths", request.MinExperienceMonths, DbType.Int32);
        p.Add("@MaxExperienceMonths", request.MaxExperienceMonths, DbType.Int32);
        p.Add("@SalaryMin", request.SalaryMin, DbType.Decimal);
        p.Add("@SalaryMax", request.SalaryMax, DbType.Decimal);
        p.Add("@IsSalaryNegotiable", request.IsSalaryNegotiable ? (byte)1 : (byte)0, DbType.Byte);
        p.Add("@CityId", request.CityId, DbType.Int32);
        p.Add("@StateId", request.StateId, DbType.Int32);
        p.Add("@WorkingDays", request.WorkingDays, DbType.String, size: 100);
        p.Add("@TimingFrom", request.TimingFrom, DbType.Time);
        p.Add("@TimingTo", request.TimingTo, DbType.Time);
        p.Add("@LastDateToApply", request.LastDateToApply, DbType.Date);
        p.Add("@ExpectedJoiningDate", request.ExpectedJoiningDate, DbType.Date);
        p.Add("@JobDescription", request.JobDescription, DbType.String, size: -1);
        p.Add("@SubjectIds", IdList(request.SubjectIds).AsTableValuedParameter("dbo.IntIdList"));
        p.Add("@ClassLevelIds", IdList(request.ClassLevelIds).AsTableValuedParameter("dbo.IntIdList"));
        p.Add("@RowVersion", request.RowVersion, DbType.Int32);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_SaveJob", p, cancellationToken);
    }

    public Task<PublishRow> PublishAsync(
        long schoolId, Guid userUid, long jobId, Guid ownerUid,
        int featureId, int gatingModeId, bool hasMapping, bool isIncluded, int? quotaPerPeriod,
        int expectedPlanId, long actorUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@JobId", jobId, DbType.Int64);
        p.Add("@OwnerUid", ownerUid, DbType.Guid);
        p.Add("@FeatureId", featureId, DbType.Int32);
        p.Add("@GatingModeId", (byte)gatingModeId, DbType.Byte);
        p.Add("@HasMapping", hasMapping ? (byte)1 : (byte)0, DbType.Byte);
        p.Add("@IsIncluded", isIncluded ? (byte)1 : (byte)0, DbType.Byte);
        p.Add("@QuotaPerPeriod", quotaPerPeriod, DbType.Int32);
        p.Add("@ExpectedPlanId", expectedPlanId, DbType.Int32);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<PublishRow>("USP_PublishJob", p, cancellationToken);
    }

    public Task<ProcResult> CloseAsync(
        long schoolId, Guid userUid, long jobId, long actorUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@JobId", jobId, DbType.Int64);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_CloseJob", p, cancellationToken);
    }

    public Task<SchoolJobStatsDto> GetStatsAsync(
        long schoolId, Guid userUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);

        return QueryMultipleAsync<SchoolJobStatsDto>("USP_GetSchoolJobStats", async grid =>
        {
            var stats = await grid.ReadFirstOrDefaultAsync<SchoolJobStatsDto>().ConfigureAwait(false)
                ?? new SchoolJobStatsDto();

            stats.Recent = (await grid.ReadAsync<RecentJobDto>().ConfigureAwait(false)).ToList();

            return stats;
        }, p, cancellationToken);
    }

    private static DataTable IdList(IReadOnlyList<int> ids)
    {
        var table = new DataTable();
        table.Columns.Add("Id", typeof(int));

        foreach (var id in ids.Distinct())
        {
            table.Rows.Add(id);
        }

        return table;
    }
}
