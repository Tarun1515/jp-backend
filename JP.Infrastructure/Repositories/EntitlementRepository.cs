using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Domain.Entitlements;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

/*==============================================================================
  🔴 THE PROHIBITION THIS ENGINE CARRIES EVERYWHERE (2.56 — LOCKED)

  The entitlement engine and contact unlock never reference each other, in
  either direction. A subscription buys the school's CAPABILITY — search,
  invites — never a teacher's contact details. Nothing here may be consulted by
  a contact decision, and no contact fact may be consulted here.
==============================================================================*/

/// <summary>
/// The feature and its plan mapping, resolved together for one consume.
/// </summary>
/// <remarks>
/// 🔴 <c>IsActive</c> arrives through an ALIAS in the procedure
/// (<c>Is_Active AS IsActive</c>) and cannot work without one — Dapper does not
/// strip underscores and the failure is silent (2.61, incident G25).
///
/// ⚠️ On THIS property the silent failure is the worst one available: every
/// feature would read as switched off and the engine would refuse everything,
/// everywhere, with nothing logged.
/// </remarks>
internal sealed class EntitlementResolution
{
    public int FeatureId { get; set; }
    public string FeatureCode { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public int GatingModeId { get; set; }
    public int AppliesToUserTypeId { get; set; }

    /// <summary>🔴 The kill switch. See the remarks above.</summary>
    public bool IsActive { get; set; }

    /// <summary>
    /// Whether a mapping row exists at all — returned explicitly rather than
    /// inferred from a null quota, because "no decision" and "a quota of zero"
    /// are different facts with the same shape.
    /// </summary>
    public bool HasMapping { get; set; }

    public bool IsIncluded { get; set; }

    /// <summary>Null = unlimited within the plan. Not the same as 0.</summary>
    public int? QuotaPerPeriod { get; set; }
}

/// <summary>
/// The entitlement catalog in jp_mdm: the consume path's resolution, and the
/// admin matrix behind it.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 THIS REPOSITORY NEVER TOUCHES <c>IMasterService</c>, AND IS NEVER GIVEN A
/// CACHE. That is the whole reason it exists separately.
/// </para>
/// <para>
/// Features and gating modes are master data by every structural test — they
/// are <c>m_mdm_*</c> tables, pure reference data, changed almost never, read
/// constantly. Everything about them says "put them behind IMasterService", and
/// IMasterService is the single most obvious place in this codebase to add an
/// <c>IMemoryCache</c>.
/// </para>
/// <para>
/// If gating were on that path, an hour of lag would mean the kill switch
/// engages up to an hour after the operator flips it — during exactly the
/// incident it was flipped for — and a FREE to METERED change keeps serving
/// free until the cache turns. Both fail silently, while the admin screen shows
/// the new value the entire time.
/// </para>
/// <para>
/// ⚠️ A stale subject name for an hour is cosmetic. A stale entitlement for an
/// hour is an unsellable kill switch and unbilled usage. Same storage, same
/// access pattern, completely different tolerance — which is why this is a
/// separate class rather than a comment on a shared one (2.36's precedent:
/// structure, not a remark somebody has to read).
/// </para>
/// </remarks>
internal interface IEntitlementRepository
{
    /// <summary>
    /// One query, one round trip: the feature and this plan's mapping together.
    /// </summary>
    /// <remarks>
    /// 🔴 ONE query is a correctness property, not an optimisation. Read
    /// separately, an admin flip landing between the two reads could hand the
    /// engine a combination that never existed — METERED from the first read
    /// beside a quota row the second read no longer finds.
    ///
    /// Returns null when the feature code is unknown.
    /// </remarks>
    Task<EntitlementResolution?> ResolveAsync(
        string featureCode, int planId, CancellationToken cancellationToken);

    Task<EntitlementMatrixDto> GetMatrixAsync(CancellationToken cancellationToken);

    Task<ProcResult> SaveFeatureGatingAsync(
        int featureId, int gatingModeId, bool isActive, long actorUserId, CancellationToken cancellationToken);

    Task<ProcResult> SavePlanFeatureAsync(
        SavePlanFeatureRequest request, long actorUserId, CancellationToken cancellationToken);
}

internal sealed class EntitlementRepository : BaseRepository, IEntitlementRepository
{
    public EntitlementRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<EntitlementRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.Mdm;

    public Task<EntitlementResolution?> ResolveAsync(
        string featureCode, int planId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@FeatureCode", featureCode, DbType.AnsiString, size: 50);
        p.Add("@PlanId", planId, DbType.Int32);

        return QueryFirstOrDefaultAsync<EntitlementResolution>(
            "USP_ResolveEntitlement", p, cancellationToken);
    }

    public Task<EntitlementMatrixDto> GetMatrixAsync(CancellationToken cancellationToken)
    {
        return QueryMultipleAsync<EntitlementMatrixDto>("USP_GetEntitlementMatrix", async grid =>
        {
            var plans = (await grid.ReadAsync<PlanSummaryDto>().ConfigureAwait(false)).ToList();
            var features = (await grid.ReadAsync<FeatureDto>().ConfigureAwait(false)).ToList();
            var mappings = (await grid.ReadAsync<PlanFeatureDto>().ConfigureAwait(false)).ToList();
            var modes = (await grid.ReadAsync<GatingModeDto>().ConfigureAwait(false)).ToList();

            return new EntitlementMatrixDto
            {
                Plans = plans,
                Features = features,
                Mappings = mappings,
                GatingModes = modes,
            };
        }, new DynamicParameters(), cancellationToken);
    }

    public Task<ProcResult> SaveFeatureGatingAsync(
        int featureId, int gatingModeId, bool isActive, long actorUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@FeatureId", featureId, DbType.Int32);
        p.Add("@GatingModeId", (byte)gatingModeId, DbType.Byte);
        p.Add("@IsActive", isActive ? (byte)1 : (byte)0, DbType.Byte);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_SaveFeatureGating", p, cancellationToken);
    }

    public Task<ProcResult> SavePlanFeatureAsync(
        SavePlanFeatureRequest request, long actorUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@PlanId", request.PlanId, DbType.Int32);
        p.Add("@FeatureId", request.FeatureId, DbType.Int32);
        p.Add("@Action", request.Action, DbType.AnsiString, size: 10);
        p.Add("@IsIncluded", request.IsIncluded ? (byte)1 : (byte)0, DbType.Byte);
        p.Add("@QuotaPerPeriod", request.QuotaPerPeriod, DbType.Int32);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_SavePlanFeature", p, cancellationToken);
    }
}

// =============================================================================

/// <summary>The raw shape USP_ConsumeFeature returns.</summary>
internal sealed class ConsumeRow : ProcResult
{
    public byte Consumed { get; set; }
    public byte? SourceId { get; set; }
    public int? QuotaUsed { get; set; }
    public int? QuotaRemaining { get; set; }
    public int? CreditBalance { get; set; }
    public DateTime? PeriodFromUtc { get; set; }
    public DateTime? PeriodToUtc { get; set; }
}

internal sealed class BalanceRow
{
    public Guid OwnerUid { get; set; }
    public int FeatureId { get; set; }
    public DateTime PeriodFromUtc { get; set; }
    public DateTime PeriodToUtc { get; set; }
    public int QuotaUsed { get; set; }
    public int CreditBalance { get; set; }
    public int CreditUsedThisPeriod { get; set; }
}

/// <summary>
/// The append-only ledger in jp_app.
/// </summary>
/// <remarks>
/// ⚠️ SEPARATE FROM <see cref="IEntitlementRepository"/> BECAUSE THE DATABASES
/// ARE SEPARATE. Features and plans are in jp_mdm; subscriptions and the ledger
/// are here, and neither may join to the other (2.2). One repository cannot
/// span both — <c>BaseRepository.Database</c> names exactly one.
///
/// The service is what joins them, which is the same shape provisioning has
/// used since 2F.
/// </remarks>
internal interface IEntitlementLedgerRepository
{
    Task<ConsumeRow> ConsumeAsync(
        Guid ownerUid,
        int featureId,
        int gatingModeId,
        bool hasMapping,
        bool isIncluded,
        int? quotaPerPeriod,
        int units,
        int? refEntityTypeId,
        Guid? refEntityUid,
        string? notes,
        long? actorUserId,

        /*
          The plan the caller resolved the mapping against. Compared under the
          procedure's lock; a mismatch answers PLAN_CHANGED rather than pricing
          the consume against a plan the owner has already left.
        */
        int expectedPlanId,
        CancellationToken cancellationToken);

    Task<ProcResult> GrantCreditsAsync(
        Guid ownerUid, int featureId, int units, string? notes, long actorUserId,
        CancellationToken cancellationToken);

    Task<ProcResult> ReverseAsync(
        long entryId, string? notes, long actorUserId, CancellationToken cancellationToken);

    Task<BalanceRow?> GetBalanceAsync(
        Guid ownerUid, int featureId, CancellationToken cancellationToken);

    Task<IReadOnlyList<LedgerEntryDto>> GetLedgerAsync(
        Guid ownerUid, int? featureId, int top, CancellationToken cancellationToken);
}

internal sealed class EntitlementLedgerRepository : BaseRepository, IEntitlementLedgerRepository
{
    public EntitlementLedgerRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<EntitlementLedgerRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.App;

    public Task<ConsumeRow> ConsumeAsync(
        Guid ownerUid,
        int featureId,
        int gatingModeId,
        bool hasMapping,
        bool isIncluded,
        int? quotaPerPeriod,
        int units,
        int? refEntityTypeId,
        Guid? refEntityUid,
        string? notes,
        long? actorUserId,
        int expectedPlanId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@ExpectedPlanId", expectedPlanId, DbType.Int32);
        p.Add("@OwnerUid", ownerUid, DbType.Guid);
        p.Add("@FeatureId", featureId, DbType.Int32);
        p.Add("@GatingModeId", (byte)gatingModeId, DbType.Byte);
        p.Add("@HasMapping", hasMapping ? (byte)1 : (byte)0, DbType.Byte);
        p.Add("@IsIncluded", isIncluded ? (byte)1 : (byte)0, DbType.Byte);
        p.Add("@QuotaPerPeriod", quotaPerPeriod, DbType.Int32);
        p.Add("@Units", units, DbType.Int32);
        p.Add("@RefEntityTypeId", (byte?)refEntityTypeId, DbType.Byte);
        p.Add("@RefEntityUid", refEntityUid, DbType.Guid);
        p.Add("@Notes", notes, DbType.String, size: 400);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ConsumeRow>("USP_ConsumeFeature", p, cancellationToken);
    }

    public Task<ProcResult> GrantCreditsAsync(
        Guid ownerUid, int featureId, int units, string? notes, long actorUserId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@OwnerUid", ownerUid, DbType.Guid);
        p.Add("@FeatureId", featureId, DbType.Int32);
        p.Add("@Units", units, DbType.Int32);
        p.Add("@Notes", notes, DbType.String, size: 400);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_GrantFeatureCredits", p, cancellationToken);
    }

    public Task<ProcResult> ReverseAsync(
        long entryId, string? notes, long actorUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@EntryId", entryId, DbType.Int64);
        p.Add("@Notes", notes, DbType.String, size: 400);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_ReverseLedgerEntry", p, cancellationToken);
    }

    public Task<BalanceRow?> GetBalanceAsync(
        Guid ownerUid, int featureId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@OwnerUid", ownerUid, DbType.Guid);
        p.Add("@FeatureId", featureId, DbType.Int32);

        return QueryFirstOrDefaultAsync<BalanceRow>("USP_GetFeatureBalance", p, cancellationToken);
    }

    public Task<IReadOnlyList<LedgerEntryDto>> GetLedgerAsync(
        Guid ownerUid, int? featureId, int top, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@OwnerUid", ownerUid, DbType.Guid);
        p.Add("@FeatureId", featureId, DbType.Int32);
        p.Add("@Top", top, DbType.Int32);

        return QueryAsync<LedgerEntryDto>("USP_GetFeatureLedger", p, cancellationToken);
    }
}
