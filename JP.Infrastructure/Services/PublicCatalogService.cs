using JP.Core.Common;
using JP.Core.Exceptions;
using JP.Domain.Common;
using JP.Domain.Public;
using JP.Infrastructure.Repositories;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Services;

/// <summary>
/// The PUBLIC surface. Phase 7A.
/// </summary>
/// <remarks>
/// <para>
/// 🔒 NO METHOD HERE TAKES A ClaimsPrincipal, AND THAT IS THE DESIGN.
/// </para>
/// <para>
/// Every other service in this product starts from a caller and scopes to it
/// (2.39). These requests carry no identity (2.81). The authentication
/// middleware still runs globally, so a request that happens to send a valid
/// Bearer token will have it parsed — but nothing on this path reads the
/// result, which is why no method accepts a principal and no field holds an
/// accessor. The verification proves it over the wire: the same request with
/// and without a token returns byte-identical JSON.
/// </para>
/// <para>
/// 🔒 Nothing here reads a teacher, an application, a subscription or the
/// ledger, and no response carries a plan, a quota or an entitlement. Public
/// pages show no entitlements, so no cache can ever serve one (2.81).
/// </para>
/// </remarks>
public interface IPublicCatalogService
{
    Task<PagedResult<PublicJobCardDto>> SearchJobsAsync(
        string? search, int? subjectId, int? cityId, int? stateId, int? classLevelId,
        int pageNumber, int pageSize, CancellationToken cancellationToken);

    /// <summary>
    /// One job. Throws <see cref="NotFoundException"/> when it is not public —
    /// which is the same answer a job that never existed gives.
    /// </summary>
    Task<PublicJobDetailDto> GetJobAsync(Guid jobUid, CancellationToken cancellationToken);

    Task<PublicJobFiltersDto> GetFiltersAsync(CancellationToken cancellationToken);

    Task<IReadOnlyList<PublicFaqDto>> GetFaqsAsync(CancellationToken cancellationToken);

    Task<IReadOnlyList<PublicContentBlockDto>> GetContentBlocksAsync(CancellationToken cancellationToken);

    /// <summary>
    /// Records a contact enquiry — or silently does not, when the honeypot is
    /// filled. The caller cannot tell the difference, deliberately.
    /// </summary>
    Task SubmitEnquiryAsync(ContactEnquiryRequest request, CancellationToken cancellationToken);
}

internal sealed class PublicCatalogService : IPublicCatalogService
{
    private readonly IPublicRepository _repository;
    private readonly IJobViewCounter _views;
    private readonly ILogger<PublicCatalogService> _logger;

    public PublicCatalogService(
        IPublicRepository repository,
        IJobViewCounter views,
        ILogger<PublicCatalogService> logger)
    {
        _repository = repository;
        _views = views;
        _logger = logger;
    }

    public async Task<PagedResult<PublicJobCardDto>> SearchJobsAsync(
        string? search, int? subjectId, int? cityId, int? stateId, int? classLevelId,
        int pageNumber, int pageSize, CancellationToken cancellationToken)
    {
        var rows = await _repository.SearchJobsAsync(
            string.IsNullOrWhiteSpace(search) ? null : search.Trim(),
            subjectId, cityId, stateId, classLevelId,
            pageNumber, pageSize, cancellationToken).ConfigureAwait(false);

        return new PagedResult<PublicJobCardDto>
        {
            Items = rows.Select(Map).ToList(),
            TotalRecords = rows.Count > 0 ? rows[0].TotalRecords : 0,
        };
    }

    public async Task<PublicJobDetailDto> GetJobAsync(Guid jobUid, CancellationToken cancellationToken)
    {
        var (row, levels) = await _repository.GetJobAsync(jobUid, cancellationToken)
            .ConfigureAwait(false);

        /*
          🔴 THE 404, AND THE PROCEDURE ALREADY DECIDED IT.

          A draft, an expired, a closed, a soft-deleted or a moderation-pulled
          job returns zero rows from USP_GetPublicJobByUid — the WHERE clause
          is the wall (024). This turns "no rows" into the HTTP answer and
          makes no judgement of its own: there is deliberately no status check
          here to get out of step with the one in SQL.

          ⚠️ The message says nothing about WHY. "This job has expired" would
          confirm the id is real, which on an anonymous endpoint is an
          enumeration oracle — the same reasoning 2.6 applies to authenticated
          refusals.
        */
        if (row is null)
        {
            throw new NotFoundException("That job was not found.");
        }

        /*
          🔴 THE VIEW IS COUNTED HERE, AND THE READ STAYS PURE.

          2.81: the uid goes on a channel and a background service flushes a
          batched UPDATE every few seconds. This call cannot fail the request
          and cannot slow it — it is a bounded, non-blocking write to memory.
        */
        _views.Record(jobUid);

        var dto = Map(row);
        dto.ClassLevels = levels;

        return dto;
    }

    public Task<PublicJobFiltersDto> GetFiltersAsync(CancellationToken cancellationToken) =>
        _repository.GetFiltersAsync(cancellationToken);

    public Task<IReadOnlyList<PublicFaqDto>> GetFaqsAsync(CancellationToken cancellationToken) =>
        _repository.GetFaqsAsync(cancellationToken);

    public Task<IReadOnlyList<PublicContentBlockDto>> GetContentBlocksAsync(
        CancellationToken cancellationToken) =>
        _repository.GetContentBlocksAsync(cancellationToken);

    public async Task SubmitEnquiryAsync(
        ContactEnquiryRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        /*
          🔴 THE HONEYPOT, AND IT IS DECIDED HERE — NOT IN SQL.

          `Website` is a field a person never sees and a bot fills because it
          is in the markup. Filled means a bot, and the answer is a 200 with NO
          ROW: telling it "detected" teaches whoever wrote it to stop filling
          that field, and storing the attempt would mean a table that fills
          with bots and a queue an admin has to triage.

          ⚠️ It is NOT passed to the procedure. Pushing the decision down would
          invite the next reader to insert the row "for analysis", which is the
          table-full-of-bots this avoids (024's header).

          ⚠️ Logged at Information, not Warning: a filled honeypot is the
          mechanism working, not an incident. Warning-level noise is how real
          warnings stop being read.
        */
        if (!string.IsNullOrWhiteSpace(request.Website))
        {
            _logger.LogInformation(
                "Contact enquiry discarded: honeypot field was filled. Nothing was written.");

            return;
        }

        await _repository.SubmitEnquiryAsync(
            request.Name.Trim(),
            request.Email.Trim(),
            string.IsNullOrWhiteSpace(request.Mobile) ? null : request.Mobile.Trim(),
            request.Subject.Trim(),
            request.Message.Trim(),
            cancellationToken).ConfigureAwait(false);
    }

    private static PublicJobCardDto Map(PublicJobRow row) => new()
    {
        JobUid = row.JobUid,
        JobTitle = row.JobTitle,
        SubjectId = row.SubjectId,
        SubjectName = row.SubjectName,
        DesignationId = row.DesignationId,
        DesignationName = row.DesignationName,
        EmploymentTypeId = row.EmploymentTypeId,
        EmploymentTypeName = row.EmploymentTypeName,
        NoOfVacancies = row.NoOfVacancies,
        MinExperienceMonths = row.MinExperienceMonths,
        MaxExperienceMonths = row.MaxExperienceMonths,
        SalaryMin = row.SalaryMin,
        SalaryMax = row.SalaryMax,
        IsSalaryNegotiable = row.IsSalaryNegotiable,
        CityId = row.CityId,
        CityName = row.CityName,
        StateId = row.StateId,
        StateName = row.StateName,
        LastDateToApply = row.LastDateToApply,
        PublishedOn = row.PublishedOn,
        SchoolUid = row.SchoolUid,
        SchoolName = row.SchoolName,
        SchoolLogoPath = row.SchoolLogoPath,
        IsSchoolVerified = row.IsSchoolVerified,
    };

    private static PublicJobDetailDto Map(PublicJobDetailRow row) => new()
    {
        JobUid = row.JobUid,
        JobTitle = row.JobTitle,
        JobDescription = row.JobDescription,
        SubjectId = row.SubjectId,
        SubjectName = row.SubjectName,
        DesignationId = row.DesignationId,
        DesignationName = row.DesignationName,
        QualificationId = row.QualificationId,
        QualificationName = row.QualificationName,
        EmploymentTypeId = row.EmploymentTypeId,
        EmploymentTypeName = row.EmploymentTypeName,
        NoOfVacancies = row.NoOfVacancies,
        MinExperienceMonths = row.MinExperienceMonths,
        MaxExperienceMonths = row.MaxExperienceMonths,
        SalaryMin = row.SalaryMin,
        SalaryMax = row.SalaryMax,
        IsSalaryNegotiable = row.IsSalaryNegotiable,
        CityId = row.CityId,
        CityName = row.CityName,
        StateId = row.StateId,
        StateName = row.StateName,
        LastDateToApply = row.LastDateToApply,
        ExpectedJoiningDate = row.ExpectedJoiningDate,
        PublishedOn = row.PublishedOn,
        SchoolUid = row.SchoolUid,
        SchoolName = row.SchoolName,
        SchoolLogoPath = row.SchoolLogoPath,
        IsSchoolVerified = row.IsSchoolVerified,
        AboutSchool = row.AboutSchool,
        Website = row.Website,
        EstablishedYear = row.EstablishedYear,
        SchoolTypeId = row.SchoolTypeId,
        SchoolTypeName = row.SchoolTypeName,
        BoardId = row.BoardId,
        BoardName = row.BoardName,
        BranchName = row.BranchName,
        BranchCityName = row.BranchCityName,
    };
}
