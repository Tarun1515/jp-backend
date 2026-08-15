using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

/// <summary>
/// One subscription row, before the plan is joined onto it.
/// </summary>
/// <remarks>
/// 🔴 <c>IsActive</c> arrives through an ALIAS in the procedure
/// (<c>Is_Active AS IsActive</c>) and cannot work without one — Dapper does not
/// strip underscores, and the failure is silent: the property simply stays
/// false (decision 2.61, incident G25).
/// </remarks>
internal sealed class SubscriptionRow
{
    public long SubscriptionId { get; set; }
    public Guid SubscriptionUid { get; set; }
    public Guid OwnerUid { get; set; }
    public int PlanId { get; set; }
    public DateTime StartsOn { get; set; }
    public DateTime? EndsOn { get; set; }
    public int StatusId { get; set; }
    public bool AutoRenew { get; set; }
    public bool IsActive { get; set; }
}

internal interface ISubscriptionRepository
{
    /// <summary>
    /// The owner's current subscription, or null when they have none.
    /// </summary>
    /// <remarks>
    /// ⚠️ Null is a real state, not an error. 3B found seven organisations
    /// holding a plan they should not have had, and the repair left the
    /// possibility of an account with none at all. Both dashboards render it.
    /// </remarks>
    Task<SubscriptionRow?> GetCurrentAsync(Guid ownerUid, CancellationToken cancellationToken);
}

internal sealed class SubscriptionRepository : BaseRepository, ISubscriptionRepository
{
    public SubscriptionRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<SubscriptionRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.App;

    public Task<SubscriptionRow?> GetCurrentAsync(Guid ownerUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@OwnerUid", ownerUid, DbType.Guid);

        return QueryFirstOrDefaultAsync<SubscriptionRow>("USP_GetCurrentSubscription", p, cancellationToken);
    }
}
