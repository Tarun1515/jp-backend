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

/// <summary>The result of <c>USP_ActivateSubscription</c>.</summary>
/// <remarks>
/// 🔴 <see cref="AlreadyActivated"/> is the idempotency answer, and it is a
/// SUCCESS. Verification and activation span two databases with no distributed
/// transaction (2.2, 2.48), so a retry after a half-completed verification is
/// the normal recovery path — and it must finish the job rather than open a
/// second subscription for money that arrived once (6.5-A).
/// </remarks>
internal sealed class ActivationRow
{
    public int Status { get; set; }
    public string? Code { get; set; }
    public string? Message { get; set; }
    public long? SubscriptionId { get; set; }
    public Guid? SubscriptionUid { get; set; }
    public int? PreviousPlanId { get; set; }
    public DateTime? StartsOn { get; set; }
    public DateTime? EndsOn { get; set; }
    public bool AlreadyActivated { get; set; }
}

/// <summary>One subscription an owner has held, past or present.</summary>
/// <remarks>
/// 🔴 Both <c>IsActive</c> and <c>InForce</c> are aliased in the procedure, and
/// they are different facts: a paid row past <c>EndsOn</c> is still ACTIVE and
/// is no longer in force (6.5-C). <c>InForce</c> comes from
/// <c>fn_SubscriptionInForce</c> and is never re-derived out here.
/// </remarks>
internal sealed class SubscriptionHistoryRow
{
    public long SubscriptionId { get; set; }
    public Guid SubscriptionUid { get; set; }
    public Guid OwnerUid { get; set; }
    public int PlanId { get; set; }
    public DateTime StartsOn { get; set; }
    public DateTime? EndsOn { get; set; }
    public int StatusId { get; set; }
    public bool AutoRenew { get; set; }
    public Guid? SourcePaymentUid { get; set; }
    public DateTime CreatedOn { get; set; }
    public bool IsActive { get; set; }
    public bool InForce { get; set; }
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

    /// <summary>
    /// Closes the owner's current subscription and opens one on the new plan,
    /// in a single transaction. Idempotent on <paramref name="paymentUid"/>.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 <c>UQ_t_app_subscriptions_OneActivePerOwner</c> permits one ACTIVE row
    /// per owner, so activation is NECESSARILY close-then-open — the database
    /// makes the shape structural rather than a convention (2.36). Neither row
    /// is ever edited in place: the old plan stays readable, which is the first
    /// thing anybody asks when a bill is disputed.
    /// </para>
    /// <para>
    /// ⚠️ <paramref name="durationDays"/> is passed in because plans live in
    /// jp_mdm and no query may cross (2.2). Null = perpetual.
    /// </para>
    /// </remarks>
    Task<ActivationRow> ActivateAsync(
        Guid ownerUid, int planId, Guid paymentUid, int? durationDays,
        long? actorUserId, CancellationToken cancellationToken);

    /// <summary>Every subscription the owner has held, newest first.</summary>
    Task<IReadOnlyList<SubscriptionHistoryRow>> GetHistoryAsync(
        Guid ownerUid, CancellationToken cancellationToken);
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

    public Task<ActivationRow> ActivateAsync(
        Guid ownerUid, int planId, Guid paymentUid, int? durationDays,
        long? actorUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@OwnerUid", ownerUid, DbType.Guid);
        p.Add("@PlanId", planId, DbType.Int32);
        p.Add("@PaymentUid", paymentUid, DbType.Guid);
        p.Add("@DurationDays", durationDays, DbType.Int32);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ActivationRow>("USP_ActivateSubscription", p, cancellationToken);
    }

    public Task<IReadOnlyList<SubscriptionHistoryRow>> GetHistoryAsync(
        Guid ownerUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@OwnerUid", ownerUid, DbType.Guid);

        return QueryAsync<SubscriptionHistoryRow>("USP_GetSubscriptionHistory", p, cancellationToken);
    }
}
