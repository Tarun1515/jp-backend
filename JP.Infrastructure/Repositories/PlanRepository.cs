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
}
