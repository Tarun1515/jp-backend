using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

internal sealed class PlanRow
{
    public int PlanId { get; set; }
    public string PlanCode { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public int UserTypeId { get; set; }
    public int? DurationDays { get; set; }
    public decimal Price { get; set; }
}

internal interface IPlanRepository
{
    Task<PlanRow?> GetDefaultPlanAsync(int userTypeId, CancellationToken cancellationToken);

    /// <summary>One plan, by the id a subscription row stores (3I).</summary>
    Task<PlanRow?> GetByIdAsync(int planId, CancellationToken cancellationToken);

    /// <summary>
    /// 🔴 SR-4. One plan, by the CODE a registration draft recorded (2.47).
    /// </summary>
    /// <remarks>
    /// <para>
    /// Registration stores the plan a school asked for as a code, because a
    /// draft outlives any surrogate id. At approval the API has to turn that
    /// into the <c>PlanId</c> <c>USP_RequestPlanChange</c> takes — and the
    /// other half of provisioning is in jp_app, which cannot see the plan
    /// catalogue (2.2). So the id is read here and PASSED, which is exactly
    /// what <see cref="GetDefaultPlanAsync"/> has always done.
    /// </para>
    /// <para>
    /// 🔴 Null is a MEANINGFUL answer, not just an absence: the code is
    /// unknown, private, or belonged to a plan that has since been withdrawn.
    /// The caller must not open a pending payment for a tier that no longer
    /// exists, and must not fail an approval over it either.
    /// </para>
    /// </remarks>
    Task<PlanRow?> GetByCodeAsync(string planCode, CancellationToken cancellationToken);
}

/// <summary>
/// Subscription plans, which live in jp_mdm.
/// </summary>
/// <remarks>
/// 🔴 The subscription itself lives in jp_app, and neither database can join to
/// the other (decision 2.2). So the API reads the plan here and passes its id
/// across to provisioning — the same shape the reconciliation already takes,
/// and the reason the subscription table stores PlanId with no foreign key.
/// </remarks>
internal sealed class PlanRepository : BaseRepository, IPlanRepository
{
    public PlanRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<PlanRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.Mdm;

    public async Task<PlanRow?> GetDefaultPlanAsync(int userTypeId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserTypeId", userTypeId, DbType.Int32);

        var rows = await QueryAsync<PlanRow>("USP_GetDefaultPlan", p, cancellationToken)
            .ConfigureAwait(false);

        return rows.Count > 0 ? rows[0] : null;
    }

    public Task<PlanRow?> GetByIdAsync(int planId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@PlanId", planId, DbType.Int32);

        return QueryFirstOrDefaultAsync<PlanRow>("USP_GetPlanById", p, cancellationToken);
    }

    public Task<PlanRow?> GetByCodeAsync(string planCode, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();

        // AnsiString, size 30 — m_mdm_plans.PlanCode is varchar(30), and
        // nvarchar here would make the lookup a conversion on every call.
        p.Add("@PlanCode", planCode, DbType.AnsiString, size: 30);

        return QueryFirstOrDefaultAsync<PlanRow>("USP_GetPlanByCode", p, cancellationToken);
    }
}
