using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Domain.Applications;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

/// <summary>The teacher behind a token, resolved once per write.</summary>
internal sealed class TeacherIdentityRow
{
    public long TeacherId { get; set; }
    public Guid TeacherUid { get; set; }
    public bool HasResume { get; set; }
}

/// <summary>What <c>USP_ToggleSavedJob</c> returns.</summary>
internal sealed class ToggleSavedRow : ProcResult
{
    public byte IsSaved { get; set; }
}

/// <summary>
/// Applications, saved jobs, and the teacher's view of the job market — jp_app.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 EVERY SCHOOL-SIDE METHOD TAKES <c>schoolId</c> AND <c>userUid</c>, and the
/// procedures join through <c>fn_VisibleBranches</c>. Neither ever comes from a
/// request body — the service resolves both from the token (2.39).
/// </para>
/// <para>
/// 🔴 EVERY TEACHER-SIDE READ TAKES <c>userUid</c> AND NOTHING THAT IDENTIFIES A
/// TEACHER. The procedure resolves the teacher itself, so "somebody else's
/// applications" cannot be expressed. The two WRITES take a teacherId, because
/// an application is a row about a person rather than about a login — and that
/// id comes from <see cref="ResolveTeacherAsync"/>, which takes a token uid.
/// </para>
/// <para>
/// ⚠️ THERE IS NO CONSUME CALL IN THIS FILE, AND THERE MUST NEVER BE ONE.
/// Applying is FREE; the consuming action is the school's publish (2.64).
/// </para>
/// </remarks>
internal interface IApplicationRepository
{
    /// <summary>
    /// The teacher a token belongs to.
    /// </summary>
    /// <remarks>
    /// The mirror of <c>ISchoolProfileService.ResolveSchoolIdAsync</c>. Returns
    /// null for an account with no profile, and for a SUSPENDED one — an
    /// account that cannot be browsed must not be able to apply either.
    /// </remarks>
    Task<TeacherIdentityRow?> ResolveTeacherAsync(Guid userUid, CancellationToken cancellationToken);

    // ---- school side -------------------------------------------------------

    Task<IReadOnlyList<ApplicantListItemDto>> GetApplicantListAsync(
        long schoolId, Guid userUid, long? jobId, int? statusId, long? branchId,
        CancellationToken cancellationToken);

    Task<ApplicantDetailDto?> GetApplicantByIdAsync(
        long schoolId, Guid userUid, long applicationId, CancellationToken cancellationToken);

    Task<string?> GetResumeSnapshotPathAsync(
        long schoolId, Guid userUid, long applicationId, CancellationToken cancellationToken);

    Task<ProcResult> SetStatusAsync(
        long schoolId, Guid userUid, long applicationId, int toStatusId, string? remarks,
        long actorUserId, CancellationToken cancellationToken);

    Task<ProcResult> MarkViewedAsync(
        long schoolId, Guid userUid, long applicationId, long actorUserId,
        CancellationToken cancellationToken);

    Task<SchoolApplicantStatsDto> GetSchoolStatsAsync(
        long schoolId, Guid userUid, CancellationToken cancellationToken);

    // ---- teacher side ------------------------------------------------------

    Task<(IReadOnlyList<JobBrowseItemDto> Rows, long Total)> BrowseJobsAsync(
        Guid? userUid, JobBrowseFilter filter, CancellationToken cancellationToken);

    Task<JobForTeacherDto?> GetJobForTeacherAsync(
        long jobId, Guid? userUid, CancellationToken cancellationToken);

    Task<ProcResult> ApplyAsync(
        long teacherId, long jobId, string? coverNote, long actorUserId,
        CancellationToken cancellationToken);

    Task<ToggleSavedRow> ToggleSavedAsync(
        long teacherId, long jobId, long actorUserId, CancellationToken cancellationToken);

    Task<IReadOnlyList<MyApplicationListItemDto>> GetMyApplicationsAsync(
        Guid userUid, int? statusId, CancellationToken cancellationToken);

    Task<MyApplicationDetailDto?> GetMyApplicationByIdAsync(
        Guid userUid, long applicationId, CancellationToken cancellationToken);

    Task<IReadOnlyList<SavedJobDto>> GetMySavedJobsAsync(Guid userUid, CancellationToken cancellationToken);

    Task<TeacherApplicationStatsDto> GetTeacherStatsAsync(Guid userUid, CancellationToken cancellationToken);
}

internal sealed class ApplicationRepository : BaseRepository, IApplicationRepository
{
    public ApplicationRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<ApplicationRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.App;

    public Task<TeacherIdentityRow?> ResolveTeacherAsync(Guid userUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);

        return QueryFirstOrDefaultAsync<TeacherIdentityRow>(
            "USP_GetTeacherIdForUser", p, cancellationToken);
    }

    // -----------------------------------------------------------------------
    // SCHOOL SIDE
    // -----------------------------------------------------------------------

    public Task<IReadOnlyList<ApplicantListItemDto>> GetApplicantListAsync(
        long schoolId, Guid userUid, long? jobId, int? statusId, long? branchId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@JobId", jobId, DbType.Int64);
        p.Add("@StatusId", statusId, DbType.Int32);
        p.Add("@BranchId", branchId, DbType.Int64);

        return QueryAsync<ApplicantListItemDto>("USP_GetApplicantList", p, cancellationToken);
    }

    public Task<ApplicantDetailDto?> GetApplicantByIdAsync(
        long schoolId, Guid userUid, long applicationId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@ApplicationId", applicationId, DbType.Int64);

        return QueryMultipleAsync<ApplicantDetailDto?>("USP_GetApplicantById", async grid =>
        {
            var detail = await grid.ReadFirstOrDefaultAsync<ApplicantDetailDto>().ConfigureAwait(false);

            /*
              ⚠️ EVERY SET IS READ EVEN WHEN THE DETAIL IS NULL, because the
              procedure always emits all three. An out-of-scope application
              produces three empty sets rather than none — which is what keeps
              a 404 a 404 instead of a grid-shape exception.

              ⚠️ And they are read IN ORDER, unconditionally. Returning early
              on a null detail would leave unread grids on the reader.
            */
            var history = (await grid.ReadAsync<ApplicationHistoryDto>().ConfigureAwait(false)).AsList();
            var transitions = (await grid.ReadAsync<AllowedTransitionDto>().ConfigureAwait(false)).AsList();

            if (detail is null)
            {
                return null;
            }

            detail.History = history;
            detail.AllowedTransitions = transitions;

            return detail;
        }, p, cancellationToken);
    }

    public Task<string?> GetResumeSnapshotPathAsync(
        long schoolId, Guid userUid, long applicationId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@ApplicationId", applicationId, DbType.Int64);

        return QueryFirstOrDefaultAsync<string>(
            "USP_GetApplicantResumeSnapshot", p, cancellationToken);
    }

    public Task<ProcResult> SetStatusAsync(
        long schoolId, Guid userUid, long applicationId, int toStatusId, string? remarks,
        long actorUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@ApplicationId", applicationId, DbType.Int64);
        p.Add("@ToStatusId", toStatusId, DbType.Int32);
        p.Add("@Remarks", remarks, DbType.String, size: 1000);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_SetApplicationStatus", p, cancellationToken);
    }

    public Task<ProcResult> MarkViewedAsync(
        long schoolId, Guid userUid, long applicationId, long actorUserId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@ApplicationId", applicationId, DbType.Int64);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_MarkApplicationViewed", p, cancellationToken);
    }

    public Task<SchoolApplicantStatsDto> GetSchoolStatsAsync(
        long schoolId, Guid userUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);

        return QueryMultipleAsync<SchoolApplicantStatsDto>("USP_GetSchoolApplicantStats", async grid =>
        {
            var stats = await grid.ReadFirstOrDefaultAsync<SchoolApplicantStatsDto>().ConfigureAwait(false)
                ?? new SchoolApplicantStatsDto();

            stats.Recent = (await grid.ReadAsync<RecentApplicantDto>().ConfigureAwait(false)).ToList();

            return stats;
        }, p, cancellationToken);
    }

    // -----------------------------------------------------------------------
    // TEACHER SIDE
    // -----------------------------------------------------------------------

    public Task<(IReadOnlyList<JobBrowseItemDto> Rows, long Total)> BrowseJobsAsync(
        Guid? userUid, JobBrowseFilter filter, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(filter);

        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@Search", filter.Search, DbType.String, size: 150);
        p.Add("@SubjectId", filter.SubjectId, DbType.Int32);
        p.Add("@DesignationId", filter.DesignationId, DbType.Int32);
        p.Add("@EmploymentTypeId", filter.EmploymentTypeId, DbType.Int32);
        p.Add("@CityId", filter.CityId, DbType.Int32);
        p.Add("@StateId", filter.StateId, DbType.Int32);
        p.Add("@MinSalary", filter.MinSalary, DbType.Decimal);
        p.Add("@PageNumber", filter.PageNumber, DbType.Int32);
        p.Add("@PageSize", filter.PageSize, DbType.Int32);

        return QueryMultipleAsync<(IReadOnlyList<JobBrowseItemDto>, long)>(
            "USP_BrowseJobs",
            async grid =>
            {
                var rows = (await grid.ReadAsync<JobBrowseItemDto>().ConfigureAwait(false)).AsList();
                var total = await grid.ReadSingleAsync<long>().ConfigureAwait(false);

                return (rows, total);
            },
            p, cancellationToken);
    }

    public Task<JobForTeacherDto?> GetJobForTeacherAsync(
        long jobId, Guid? userUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@JobId", jobId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);

        return QueryMultipleAsync<JobForTeacherDto?>("USP_GetJobForTeacher", async grid =>
        {
            var job = await grid.ReadFirstOrDefaultAsync<JobForTeacherDto>().ConfigureAwait(false);

            // Both sets are always emitted; read them whatever the first said.
            var subjects = (await grid.ReadAsync<int>().ConfigureAwait(false)).AsList();
            var levels = (await grid.ReadAsync<int>().ConfigureAwait(false)).AsList();

            if (job is null)
            {
                return null;
            }

            job.SubjectIds = subjects;
            job.ClassLevelIds = levels;

            return job;
        }, p, cancellationToken);
    }

    public Task<ProcResult> ApplyAsync(
        long teacherId, long jobId, string? coverNote, long actorUserId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@TeacherId", teacherId, DbType.Int64);
        p.Add("@JobId", jobId, DbType.Int64);
        p.Add("@CoverNote", coverNote, DbType.String, size: 2000);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_ApplyToJob", p, cancellationToken);
    }

    public Task<ToggleSavedRow> ToggleSavedAsync(
        long teacherId, long jobId, long actorUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@TeacherId", teacherId, DbType.Int64);
        p.Add("@JobId", jobId, DbType.Int64);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ToggleSavedRow>("USP_ToggleSavedJob", p, cancellationToken);
    }

    public Task<IReadOnlyList<MyApplicationListItemDto>> GetMyApplicationsAsync(
        Guid userUid, int? statusId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@StatusId", statusId, DbType.Int32);

        return QueryAsync<MyApplicationListItemDto>("USP_GetMyApplications", p, cancellationToken);
    }

    public Task<MyApplicationDetailDto?> GetMyApplicationByIdAsync(
        Guid userUid, long applicationId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@ApplicationId", applicationId, DbType.Int64);

        return QueryMultipleAsync<MyApplicationDetailDto?>("USP_GetMyApplicationById", async grid =>
        {
            var detail = await grid.ReadFirstOrDefaultAsync<MyApplicationDetailDto>().ConfigureAwait(false);
            var history = (await grid.ReadAsync<MyApplicationStepDto>().ConfigureAwait(false)).AsList();

            if (detail is null)
            {
                return null;
            }

            detail.History = history;

            return detail;
        }, p, cancellationToken);
    }

    public Task<IReadOnlyList<SavedJobDto>> GetMySavedJobsAsync(
        Guid userUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);

        return QueryAsync<SavedJobDto>("USP_GetMySavedJobs", p, cancellationToken);
    }

    public Task<TeacherApplicationStatsDto> GetTeacherStatsAsync(
        Guid userUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);

        return QueryMultipleAsync<TeacherApplicationStatsDto>("USP_GetTeacherApplicationStats", async grid =>
        {
            var stats = await grid.ReadFirstOrDefaultAsync<TeacherApplicationStatsDto>().ConfigureAwait(false)
                ?? new TeacherApplicationStatsDto();

            stats.Recent = (await grid.ReadAsync<RecentMyApplicationDto>().ConfigureAwait(false)).ToList();

            return stats;
        }, p, cancellationToken);
    }
}
