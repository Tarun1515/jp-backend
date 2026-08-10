using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Domain.Approvals;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

internal sealed class ProvisionResult : ProcResult
{
    public Guid? SchoolUid { get; set; }
}

internal interface IProvisioningRepository
{
    Task<ProvisionResult> ProvisionSchoolAsync(
        Guid sourceRequestUid,
        Guid organizationUid,
        SchoolRegistrationDetailDto detail,
        int planId,
        long actionByUserId,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<OrphanedApprovalRow>> FindOrphanedAsync(
        IReadOnlyList<(Guid RequestUid, string RequestNo, Guid? OrganizationUid, DateTime CompletedOn)> completed,
        CancellationToken cancellationToken);
}

/// <summary>
/// The jp_app half of the post-approval work.
/// </summary>
/// <remarks>
/// Separate from <see cref="ApprovalRepository"/> because it targets a
/// different database. Two repositories, two connections, two commits — which
/// is exactly the shape decision 2.2 requires and the reason the orchestrator
/// has to handle partial failure itself.
/// </remarks>
internal sealed class ProvisioningRepository : BaseRepository, IProvisioningRepository
{
    public ProvisioningRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<ProvisioningRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.App;

    /// <summary>
    /// Creates the school an approved registration earned — and, in the same
    /// transaction, its head-office branch and its subscription.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Idempotent on <paramref name="sourceRequestUid"/>: called twice, the
    /// second call returns the row the first created with
    /// Code = ALREADY_PROVISIONED and Status = 1. That is what makes a retry
    /// after a partial cross-database failure safe.
    /// </para>
    /// <para>
    /// 🔴 THREE INSERTS, ONE GUARD. The branch and the subscription are inside
    /// the same idempotency check as the school, not beside it — outside it, a
    /// retry would skip the school it found and then create a SECOND head
    /// office and a SECOND subscription, with nothing complaining at the time.
    /// </para>
    /// </remarks>
    public Task<ProvisionResult> ProvisionSchoolAsync(
        Guid sourceRequestUid,
        Guid organizationUid,
        SchoolRegistrationDetailDto detail,
        int planId,
        long actionByUserId,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(detail);

        var p = new DynamicParameters();
        p.Add("@SourceRequestUid", sourceRequestUid, DbType.Guid);
        p.Add("@OrganizationUid", organizationUid, DbType.Guid);
        p.Add("@SchoolName", detail.SchoolName, DbType.String, size: 200);
        p.Add("@SchoolTypeId", detail.SchoolTypeId, DbType.Int32);
        p.Add("@BoardId", detail.BoardId, DbType.Int32);
        p.Add("@AffiliationNumber", detail.AffiliationNumber, DbType.AnsiString, size: 50);
        p.Add("@RegistrationNo", detail.RegistrationNo, DbType.AnsiString, size: 50);
        p.Add("@PanNumber", detail.PanNumber, DbType.AnsiString, size: 10);
        p.Add("@LogoPath", detail.LogoPath, DbType.String, size: 500);
        p.Add("@GroupType", detail.GroupType, DbType.Byte);
        p.Add("@EstablishedYear", detail.EstablishedYear, DbType.Int16);
        p.Add("@AboutSchool", detail.AboutSchool, DbType.String, size: -1);
        p.Add("@Website", detail.Website, DbType.String, size: 255);
        p.Add("@ContactEmail", detail.ContactEmail, DbType.String, size: 150);
        p.Add("@ContactMobile", detail.ContactMobile, DbType.AnsiString, size: 15);
        p.Add("@PrincipalName", detail.PrincipalName, DbType.String, size: 150);
        p.Add("@HrContactName", detail.HrContactName, DbType.String, size: 150);
        p.Add("@HrContactMobile", detail.HrContactMobile, DbType.AnsiString, size: 15);
        p.Add("@AddressLine1", detail.AddressLine1, DbType.String, size: 250);
        p.Add("@AddressLine2", detail.AddressLine2, DbType.String, size: 250);
        p.Add("@CityId", detail.CityId, DbType.Int32);
        p.Add("@DistrictId", detail.DistrictId, DbType.Int32);
        p.Add("@StateId", detail.StateId, DbType.Int32);
        p.Add("@Pincode", detail.Pincode, DbType.AnsiString, size: 10);
        // 🔴 Not optional. The procedure refuses a NULL plan, because a
        // school provisioned without one is the "no subscription" state the
        // whole design exists to prevent.
        p.Add("@PlanId", planId, DbType.Int32);

        p.Add("@VerifiedByUserId", actionByUserId, DbType.Int64);

        return QuerySingleAsync<ProvisionResult>("USP_ProvisionSchoolFromApproval", p, cancellationToken);
    }

    /// <summary>
    /// Which of these completed approvals never produced a school.
    /// </summary>
    /// <remarks>
    /// 🔴 The reconciliation query, and the reason it takes a list rather than
    /// doing its own join: jp_mdm holds the approvals and jp_app holds the
    /// schools, and joining across the two is exactly what decision 2.2
    /// forbids. The caller reads the completed approvals from jp_mdm and passes
    /// them in.
    /// </remarks>
    public Task<IReadOnlyList<OrphanedApprovalRow>> FindOrphanedAsync(
        IReadOnlyList<(Guid RequestUid, string RequestNo, Guid? OrganizationUid, DateTime CompletedOn)> completed,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(completed);

        var table = new System.Data.DataTable();
        table.Columns.Add("RequestUid", typeof(Guid));
        table.Columns.Add("RequestNo", typeof(string));
        table.Columns.Add("OrganizationUid", typeof(Guid));
        table.Columns.Add("CompletedOn", typeof(DateTime));

        foreach (var c in completed)
        {
            table.Rows.Add(
                c.RequestUid,
                c.RequestNo,
                (object?)c.OrganizationUid ?? DBNull.Value,
                c.CompletedOn);
        }

        var p = new DynamicParameters();
        p.Add("@Completed", table.AsTableValuedParameter("dbo.CompletedApprovalList"));

        return QueryAsync<OrphanedApprovalRow>("USP_FindOrphanedApprovals", p, cancellationToken);
    }
}
