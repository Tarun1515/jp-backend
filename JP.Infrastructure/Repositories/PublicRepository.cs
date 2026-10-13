using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Domain.Public;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

/// <summary>A listing row, plus the window's total.</summary>
internal sealed class PublicJobRow
{
    public Guid JobUid { get; set; }
    public string JobTitle { get; set; } = string.Empty;
    public int? SubjectId { get; set; }
    public string? SubjectName { get; set; }
    public int? DesignationId { get; set; }
    public string? DesignationName { get; set; }
    public int? EmploymentTypeId { get; set; }
    public string? EmploymentTypeName { get; set; }
    public int? NoOfVacancies { get; set; }
    public int? MinExperienceMonths { get; set; }
    public int? MaxExperienceMonths { get; set; }
    public decimal? SalaryMin { get; set; }
    public decimal? SalaryMax { get; set; }
    public bool IsSalaryNegotiable { get; set; }
    public int? CityId { get; set; }
    public string? CityName { get; set; }
    public int? StateId { get; set; }
    public string? StateName { get; set; }
    public DateTime? LastDateToApply { get; set; }
    public DateTime? PublishedOn { get; set; }
    public Guid SchoolUid { get; set; }
    public string SchoolName { get; set; } = string.Empty;
    public string? SchoolLogoPath { get; set; }
    public bool IsSchoolVerified { get; set; }
    public long TotalRecords { get; set; }
}

internal sealed class PublicJobDetailRow
{
    public Guid JobUid { get; set; }
    public string JobTitle { get; set; } = string.Empty;
    public string? JobDescription { get; set; }
    public int? SubjectId { get; set; }
    public string? SubjectName { get; set; }
    public int? DesignationId { get; set; }
    public string? DesignationName { get; set; }
    public int? QualificationId { get; set; }
    public string? QualificationName { get; set; }
    public int? EmploymentTypeId { get; set; }
    public string? EmploymentTypeName { get; set; }
    public int? NoOfVacancies { get; set; }
    public int? MinExperienceMonths { get; set; }
    public int? MaxExperienceMonths { get; set; }
    public decimal? SalaryMin { get; set; }
    public decimal? SalaryMax { get; set; }
    public bool IsSalaryNegotiable { get; set; }
    public int? CityId { get; set; }
    public string? CityName { get; set; }
    public int? StateId { get; set; }
    public string? StateName { get; set; }
    public DateTime? LastDateToApply { get; set; }
    public DateTime? ExpectedJoiningDate { get; set; }
    public DateTime? PublishedOn { get; set; }
    public Guid SchoolUid { get; set; }
    public string SchoolName { get; set; } = string.Empty;
    public string? SchoolLogoPath { get; set; }
    public bool IsSchoolVerified { get; set; }
    public string? AboutSchool { get; set; }
    public string? Website { get; set; }
    public short? EstablishedYear { get; set; }
    public int? SchoolTypeId { get; set; }
    public string? SchoolTypeName { get; set; }
    public int? BoardId { get; set; }
    public string? BoardName { get; set; }
    public string? BranchName { get; set; }
    public string? BranchCityName { get; set; }
}

internal sealed class PublicFilterRow
{
    public int Id { get; set; }
    public string Name { get; set; } = string.Empty;
    public int JobCount { get; set; }
}

internal interface IPublicRepository
{
    Task<IReadOnlyList<PublicJobRow>> SearchJobsAsync(
        string? search, int? subjectId, int? cityId, int? stateId, int? classLevelId,
        int pageNumber, int pageSize, CancellationToken cancellationToken);

    /// <summary>
    /// One job, or NULL. "Not public" and "does not exist" are the same answer.
    /// </summary>
    Task<(PublicJobDetailRow? Job, IReadOnlyList<PublicClassLevelDto> ClassLevels)>
        GetJobAsync(Guid jobUid, CancellationToken cancellationToken);

    Task<PublicJobFiltersDto> GetFiltersAsync(CancellationToken cancellationToken);

    Task<IReadOnlyList<PublicFaqDto>> GetFaqsAsync(CancellationToken cancellationToken);

    Task<IReadOnlyList<PublicContentBlockDto>> GetContentBlocksAsync(CancellationToken cancellationToken);

    Task SubmitEnquiryAsync(
        string name, string email, string? mobile, string subject, string message,
        CancellationToken cancellationToken);

    /// <summary>
    /// 🔴 The ONLY write on the public path, and it is not on the read path —
    /// JobViewCounter batches uids and calls this from a background service
    /// (2.81). A per-request UPDATE would make every public read a write.
    /// </summary>
    Task<int> IncrementJobViewsAsync(
        IReadOnlyDictionary<Guid, int> views, CancellationToken cancellationToken);
}

/// <summary>
/// The PUBLIC surface's data access. Phase 7A.
/// </summary>
/// <remarks>
/// <para>
/// 🔒 NOTHING HERE TAKES A CALLER. No UserUid, no OrganizationUid, no
/// ClaimsPrincipal — not as a parameter and not from an accessor. There is no
/// identity on these requests (2.81), so there is nothing to scope BY, and the
/// scoping lives entirely in each procedure's WHERE clause.
/// </para>
/// <para>
/// 🔒 And nothing here reads a teacher, an application, a subscription or the
/// ledger. 024's dependency guard asserts that against what the server
/// compiled; the 2.56 grep asserts it against these files.
/// </para>
/// </remarks>
internal sealed class PublicRepository : BaseRepository, IPublicRepository
{
    public PublicRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<PublicRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.App;

    public Task<IReadOnlyList<PublicJobRow>> SearchJobsAsync(
        string? search, int? subjectId, int? cityId, int? stateId, int? classLevelId,
        int pageNumber, int pageSize, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@Search", search, DbType.String, size: 150);
        p.Add("@SubjectId", subjectId, DbType.Int32);
        p.Add("@CityId", cityId, DbType.Int32);
        p.Add("@StateId", stateId, DbType.Int32);
        p.Add("@ClassLevelId", classLevelId, DbType.Int32);
        p.Add("@PageNumber", pageNumber, DbType.Int32);
        p.Add("@PageSize", pageSize, DbType.Int32);

        return QueryAsync<PublicJobRow>("USP_SearchPublicJobs", p, cancellationToken);
    }

    public Task<(PublicJobDetailRow?, IReadOnlyList<PublicClassLevelDto>)> GetJobAsync(
        Guid jobUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@JobUid", jobUid, DbType.Guid);

        return QueryMultipleAsync<(PublicJobDetailRow?, IReadOnlyList<PublicClassLevelDto>)>(
            "USP_GetPublicJobByUid",
            async grid =>
            {
                var job = (await grid.ReadAsync<PublicJobDetailRow>().ConfigureAwait(false))
                    .FirstOrDefault();

                /*
                  ⚠️ The second result set is read even when the first is empty.
                  Dapper's GridReader must be consumed in order, and leaving a
                  set unread on a pooled connection is how the NEXT query on
                  that connection gets somebody else's rows.
                */
                var levels = (await grid.ReadAsync<PublicClassLevelDto>().ConfigureAwait(false))
                    .ToList();

                return (job, (IReadOnlyList<PublicClassLevelDto>)levels);
            },
            p,
            cancellationToken);
    }

    public Task<PublicJobFiltersDto> GetFiltersAsync(CancellationToken cancellationToken) =>
        QueryMultipleAsync<PublicJobFiltersDto>(
            "USP_GetPublicJobFilters",
            async grid =>
            {
                var subjects = (await grid.ReadAsync<PublicFilterRow>().ConfigureAwait(false)).ToList();
                var cities = (await grid.ReadAsync<PublicFilterRow>().ConfigureAwait(false)).ToList();
                var states = (await grid.ReadAsync<PublicFilterRow>().ConfigureAwait(false)).ToList();
                var levels = (await grid.ReadAsync<PublicFilterRow>().ConfigureAwait(false)).ToList();

                return new PublicJobFiltersDto
                {
                    Subjects = subjects.Select(Map).ToList(),
                    Cities = cities.Select(Map).ToList(),
                    States = states.Select(Map).ToList(),
                    ClassLevels = levels.Select(Map).ToList(),
                };
            },
            parameters: null,
            cancellationToken);

    public Task<IReadOnlyList<PublicFaqDto>> GetFaqsAsync(CancellationToken cancellationToken) =>
        QueryAsync<PublicFaqDto>("USP_GetPublicFaqs", parameters: null, cancellationToken);

    public Task<IReadOnlyList<PublicContentBlockDto>> GetContentBlocksAsync(
        CancellationToken cancellationToken) =>
        QueryAsync<PublicContentBlockDto>(
            "USP_GetPublicContentBlocks", parameters: null, cancellationToken);

    public async Task SubmitEnquiryAsync(
        string name, string email, string? mobile, string subject, string message,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@Name", name, DbType.String, size: 100);
        p.Add("@Email", email, DbType.String, size: 256);
        p.Add("@Mobile", mobile, DbType.AnsiString, size: 15);
        p.Add("@Subject", subject, DbType.String, size: 200);
        p.Add("@Message", message, DbType.String, size: 2000);

        await QuerySingleAsync<ProcResult>("USP_SubmitContactEnquiry", p, cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task<int> IncrementJobViewsAsync(
        IReadOnlyDictionary<Guid, int> views, CancellationToken cancellationToken)
    {
        if (views.Count == 0) return 0;

        /*
          🔴 A TABLE-VALUED PARAMETER, because the caller batches.

          A hot job viewed two hundred times in one flush window is ONE row
          here with +200 — not two hundred updates queueing for its page latch.
          The type is dbo.JobViewBatch, created in 024.
        */
        var table = new System.Data.DataTable();
        table.Columns.Add("JobUid", typeof(Guid));
        table.Columns.Add("ViewCount", typeof(int));

        foreach (var (jobUid, count) in views)
        {
            table.Rows.Add(jobUid, count);
        }

        var p = new DynamicParameters();
        p.Add("@Views", table.AsTableValuedParameter("dbo.JobViewBatch"));

        var row = await QuerySingleAsync<JobsUpdatedRow>(
            "USP_IncrementJobViews", p, cancellationToken).ConfigureAwait(false);

        return row.JobsUpdated;
    }

    private static PublicFilterOptionDto Map(PublicFilterRow row) => new()
    {
        Id = row.Id,
        Name = row.Name,
        JobCount = row.JobCount,
    };

    private sealed class JobsUpdatedRow
    {
        public int JobsUpdated { get; set; }
    }
}
