using System.Security.Claims;
using JP.Core.Constants;
using JP.Core.Enums;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Entitlements;
using JP.Infrastructure.Repositories;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Services;

/*==============================================================================
  🔴 THE PROHIBITION THIS ENGINE CARRIES EVERYWHERE (2.56 — LOCKED)

  The entitlement engine and contact unlock never reference each other, in
  either direction.

  A subscription buys the school's CAPABILITY — whether it may search the
  teacher database at all, how many invitations it may send, whether it may
  post a job. It never buys a teacher's phone number or email. Contact opens on
  the teacher's own consent: they applied here, or they accepted an invitation.

  Nothing in this file may be called from a contact decision, and no contact
  fact may be consulted here. If a requirement seems to need a plan check
  inside contact unlock, the requirement is being described wrongly — what is
  sold is reach, and reach is invites.
==============================================================================*/

/// <summary>
/// The one place that decides entitlement.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 NO SCREEN, CONTROLLER OR OTHER SERVICE MAY HAND-ROLL "does this plan
/// include the feature". Phase 4 onward calls <see cref="ConsumeAsync"/> and
/// branches on the result. A second implementation of this rule is a second
/// rule, and the day they disagree nobody will know which one is right.
/// </para>
/// <para>
/// ⚠️ There is no "may I?" method, deliberately. Check-then-consume across two
/// calls lets two sessions both be told yes for the same last unit. Asking IS
/// consuming, atomically, and a refusal is a normal return value.
/// </para>
/// </remarks>
public interface IEntitlementService
{
    /// <summary>Decide and record, atomically.</summary>
    Task<EntitlementDecision> ConsumeAsync(
        Guid ownerUid,
        string featureCode,
        int units = 1,
        RefEntityType? refEntityType = null,
        Guid? refEntityUid = null,
        string? notes = null,
        long? actorUserId = null,
        CancellationToken cancellationToken = default);

    Task<EntitlementBalanceDto> GetBalanceAsync(
        Guid ownerUid, string featureCode, CancellationToken cancellationToken);

    Task<IReadOnlyList<LedgerEntryDto>> GetLedgerAsync(
        Guid ownerUid, string? featureCode, int top, CancellationToken cancellationToken);

    // ---- administration; all require SETTINGS.MANAGE -----------------------

    /*
      ⚠️ The three "…AsAdmin" wrappers exist so the HTTP surface never has to
      perform its own permission check, and never has to fake one by calling a
      read it does not want just for the side effect. One gate, in the service,
      on every administrative path.
    */

    Task<EntitlementDecision> ConsumeAsAdminAsync(
        ClaimsPrincipal caller, ConsumeRequest request, CancellationToken cancellationToken);

    Task<EntitlementBalanceDto> GetBalanceAsAdminAsync(
        ClaimsPrincipal caller, Guid ownerUid, string featureCode, CancellationToken cancellationToken);

    Task<IReadOnlyList<LedgerEntryDto>> GetLedgerAsAdminAsync(
        ClaimsPrincipal caller, Guid ownerUid, string? featureCode, int top,
        CancellationToken cancellationToken);

    Task<EntitlementMatrixDto> GetMatrixAsync(ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task SaveFeatureGatingAsync(
        ClaimsPrincipal caller, int featureId, SaveFeatureGatingRequest request, CancellationToken cancellationToken);

    Task SavePlanFeatureAsync(
        ClaimsPrincipal caller, SavePlanFeatureRequest request, CancellationToken cancellationToken);

    Task<long> GrantCreditsAsync(
        ClaimsPrincipal caller, GrantCreditsRequest request, CancellationToken cancellationToken);

    Task<string?> ReverseAsync(
        ClaimsPrincipal caller, long entryId, string? notes, CancellationToken cancellationToken);
}

internal sealed class EntitlementService : IEntitlementService
{
    private readonly IEntitlementRepository _catalog;
    private readonly IEntitlementLedgerRepository _ledger;
    private readonly ISubscriptionRepository _subscriptions;
    private readonly ILogger<EntitlementService> _logger;

    public EntitlementService(
        IEntitlementRepository catalog,
        IEntitlementLedgerRepository ledger,
        ISubscriptionRepository subscriptions,
        ILogger<EntitlementService> logger)
    {
        _catalog = catalog;
        _ledger = ledger;
        _subscriptions = subscriptions;
        _logger = logger;
    }

    /// <summary>
    /// Resolve in jp_mdm, decide and record in jp_app.
    /// </summary>
    /// <remarks>
    /// <para>
    /// ⚠️ THE PRECEDENCE IS SPLIT ACROSS TWO DATABASES BECAUSE IT HAS TO BE.
    /// The feature's kill switch lives in jp_mdm and the subscription in
    /// jp_app, and no query may cross (2.2). So FEATURE_DISABLED is decided
    /// here and everything after it in the procedure — in the documented order
    /// either way.
    /// </para>
    /// <para>
    /// 🔴 That split does NOT weaken the rule. Both halves are server-side and
    /// both sit behind this method, which is the only way in.
    /// </para>
    /// </remarks>
    public async Task<EntitlementDecision> ConsumeAsync(
        Guid ownerUid,
        string featureCode,
        int units = 1,
        RefEntityType? refEntityType = null,
        Guid? refEntityUid = null,
        string? notes = null,
        long? actorUserId = null,
        CancellationToken cancellationToken = default)
    {
        /*
          One retry, and exactly one.

          PLAN_CHANGED means the owner's plan moved between reading it here and
          the procedure taking its lock. Re-resolving once closes that window;
          looping would turn a rare race into an unbounded spin against a
          database that is evidently being written to.
        */
        for (var attempt = 1; ; attempt++)
        {
            var decision = await ConsumeOnceAsync(
                ownerUid, featureCode, units, refEntityType, refEntityUid, notes, actorUserId,
                cancellationToken).ConfigureAwait(false);

            if (decision.Code != ErrorCodes.PlanChanged || attempt >= 2)
            {
                if (decision.Code == ErrorCodes.PlanChanged)
                {
                    _logger.LogWarning(
                        "Entitlement consume for {OwnerUid}/{FeatureCode} saw the plan change twice; giving up.",
                        ownerUid, featureCode);
                }

                return decision;
            }

            _logger.LogInformation(
                "Entitlement consume for {OwnerUid}/{FeatureCode} re-resolving after a plan change.",
                ownerUid, featureCode);
        }
    }

    private async Task<EntitlementDecision> ConsumeOnceAsync(
        Guid ownerUid,
        string featureCode,
        int units,
        RefEntityType? refEntityType,
        Guid? refEntityUid,
        string? notes,
        long? actorUserId,
        CancellationToken cancellationToken)
    {
        /*
          The plan first, because the mapping cannot be looked up without it.

          🔴 A missing subscription is a DATA-INTEGRITY ERROR. Every account has
          a plan from the moment it exists — 2F puts SCHOOL_FREE into
          provisioning, G21's closure puts TEACHER_FREE into teacher signup. If
          this is null, provisioning is broken, and the log line is the point of
          this branch existing separately from "your subscription expired".
        */
        var subscription = await _subscriptions
            .GetCurrentAsync(ownerUid, cancellationToken).ConfigureAwait(false);

        if (subscription is null)
        {
            _logger.LogError(
                "ENTITLEMENT INTEGRITY: owner {OwnerUid} has no subscription row. Provisioning is broken — "
                + "every account is supposed to hold a plan from the moment it exists (2F, G21).",
                ownerUid);

            return Refused(ErrorCodes.SubscriptionMissing,
                "This account has no subscription on file. Please contact support.");
        }

        /*
          🔴 ONE query, resolving the feature AND this plan's mapping together —
          and never through IMasterService, never from a cache. See
          IEntitlementRepository's remarks for what an hour of lag would cost.
        */
        var resolution = await _catalog
            .ResolveAsync(featureCode, subscription.PlanId, cancellationToken).ConfigureAwait(false);

        /*
          Unknown code and switched-off feature give the SAME answer,
          deliberately: to an operator asking "why did that stop working" they
          mean the same thing. The difference is preserved in the LOG, where it
          matters — an unknown code is a caller bug, an inactive feature is
          somebody's decision.
        */
        if (resolution is null)
        {
            _logger.LogError(
                "Entitlement asked for unknown feature code {FeatureCode}. This is a caller bug, "
                + "not an operator decision.", featureCode);

            return Refused(ErrorCodes.FeatureDisabled, "That feature is not available.");
        }

        if (!resolution.IsActive)
        {
            /*
              ⚠️ Information, not a warning. The kill switch being on is a
              deliberate operator action, and logging it as a problem would
              train people to ignore the line during exactly the incident it
              was flipped for.
            */
            _logger.LogInformation(
                "Feature {FeatureCode} is switched off (kill switch); refusing for {OwnerUid}.",
                featureCode, ownerUid);

            return Refused(ErrorCodes.FeatureDisabled, "That feature is currently switched off.");
        }

        var row = await _ledger.ConsumeAsync(
            ownerUid,
            resolution.FeatureId,
            resolution.GatingModeId,
            resolution.HasMapping,
            resolution.IsIncluded,
            resolution.QuotaPerPeriod,
            units,
            (int?)refEntityType,
            refEntityUid,
            notes,
            actorUserId,

            // 🔴 The guard. Compared under the procedure's lock against the plan
            // actually on the subscription at that moment.
            subscription.PlanId,
            cancellationToken).ConfigureAwait(false);

        var decision = new EntitlementDecision
        {
            Allowed = row.Succeeded,
            Code = row.Code,
            Message = row.Message,
            Consumed = row.Consumed == 1,
            EntryId = row.Id,
            Source = row.SourceId is null ? null : (LedgerSource)row.SourceId.Value,
            QuotaUsed = row.QuotaUsed,
            QuotaRemaining = row.QuotaRemaining,
            CreditBalance = row.CreditBalance,
            PeriodFromUtc = row.PeriodFromUtc,
            PeriodToUtc = row.PeriodToUtc,
        };

        if (decision.Code == ErrorCodes.SubscriptionMissing)
        {
            // Reachable if the row is deleted between the read above and the
            // lock. Same severity, same reason.
            _logger.LogError(
                "ENTITLEMENT INTEGRITY: owner {OwnerUid} lost its subscription row mid-consume.", ownerUid);
        }

        return decision;
    }

    public async Task<EntitlementBalanceDto> GetBalanceAsync(
        Guid ownerUid, string featureCode, CancellationToken cancellationToken)
    {
        var feature = await ResolveFeatureOrThrowAsync(featureCode, cancellationToken).ConfigureAwait(false);

        var row = await _ledger
            .GetBalanceAsync(ownerUid, feature.FeatureId, cancellationToken).ConfigureAwait(false)
            ?? throw new NotFoundException("No balance could be computed for that account.");

        return new EntitlementBalanceDto
        {
            OwnerUid = ownerUid,
            FeatureId = feature.FeatureId,
            FeatureCode = feature.FeatureCode,
            PeriodFromUtc = row.PeriodFromUtc,
            PeriodToUtc = row.PeriodToUtc,
            QuotaUsed = row.QuotaUsed,
            CreditBalance = row.CreditBalance,
            CreditUsedThisPeriod = row.CreditUsedThisPeriod,
        };
    }

    public async Task<IReadOnlyList<LedgerEntryDto>> GetLedgerAsync(
        Guid ownerUid, string? featureCode, int top, CancellationToken cancellationToken)
    {
        int? featureId = null;

        if (!string.IsNullOrWhiteSpace(featureCode))
        {
            var feature = await ResolveFeatureOrThrowAsync(featureCode, cancellationToken).ConfigureAwait(false);
            featureId = feature.FeatureId;
        }

        return await _ledger
            .GetLedgerAsync(ownerUid, featureId, Math.Clamp(top, 1, 500), cancellationToken)
            .ConfigureAwait(false);
    }

    // ---- administration ----------------------------------------------------

    public async Task<EntitlementDecision> ConsumeAsAdminAsync(
        ClaimsPrincipal caller, ConsumeRequest request, CancellationToken cancellationToken)
    {
        EnsureAdmin(caller);

        return await ConsumeAsync(
            request.OwnerUid,
            request.FeatureCode,
            request.Units <= 0 ? 1 : request.Units,
            (RefEntityType?)request.RefEntityTypeId,
            request.RefEntityUid,
            request.Notes,
            caller.GetUserId(),
            cancellationToken).ConfigureAwait(false);
    }

    public async Task<EntitlementBalanceDto> GetBalanceAsAdminAsync(
        ClaimsPrincipal caller, Guid ownerUid, string featureCode, CancellationToken cancellationToken)
    {
        EnsureAdmin(caller);

        return await GetBalanceAsync(ownerUid, featureCode, cancellationToken).ConfigureAwait(false);
    }

    public async Task<IReadOnlyList<LedgerEntryDto>> GetLedgerAsAdminAsync(
        ClaimsPrincipal caller, Guid ownerUid, string? featureCode, int top,
        CancellationToken cancellationToken)
    {
        EnsureAdmin(caller);

        return await GetLedgerAsync(ownerUid, featureCode, top, cancellationToken).ConfigureAwait(false);
    }

    public async Task<EntitlementMatrixDto> GetMatrixAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        EnsureAdmin(caller);

        return await _catalog.GetMatrixAsync(cancellationToken).ConfigureAwait(false);
    }

    public async Task SaveFeatureGatingAsync(
        ClaimsPrincipal caller, int featureId, SaveFeatureGatingRequest request,
        CancellationToken cancellationToken)
    {
        EnsureAdmin(caller);

        var result = await _catalog.SaveFeatureGatingAsync(
            featureId, request.GatingModeId, request.IsActive, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();

        /*
          🔴 Logged at Warning because this is the lever, and an incident review
          asks when it moved. There is no cache to invalidate — the next consume
          reads the row.
        */
        _logger.LogWarning(
            "Feature {FeatureId} gating set to mode {GatingModeId}, active {IsActive}, by user {UserId}.",
            featureId, request.GatingModeId, request.IsActive, caller.GetUserId());
    }

    public async Task SavePlanFeatureAsync(
        ClaimsPrincipal caller, SavePlanFeatureRequest request, CancellationToken cancellationToken)
    {
        EnsureAdmin(caller);

        var result = await _catalog
            .SavePlanFeatureAsync(request, caller.GetUserId(), cancellationToken).ConfigureAwait(false);

        result.EnsureSuccess();

        _logger.LogWarning(
            "Plan {PlanId} / feature {FeatureId} {Action} (included {IsIncluded}, quota {Quota}) by user {UserId}.",
            request.PlanId, request.FeatureId, request.Action, request.IsIncluded,
            request.QuotaPerPeriod, caller.GetUserId());
    }

    public async Task<long> GrantCreditsAsync(
        ClaimsPrincipal caller, GrantCreditsRequest request, CancellationToken cancellationToken)
    {
        EnsureAdmin(caller);

        var feature = await ResolveFeatureOrThrowAsync(request.FeatureCode, cancellationToken)
            .ConfigureAwait(false);

        var result = await _ledger.GrantCreditsAsync(
            request.OwnerUid, feature.FeatureId, request.Units, request.Notes,
            caller.GetUserId(), cancellationToken).ConfigureAwait(false);

        result.EnsureSuccess();

        _logger.LogWarning(
            "Granted {Units} credits of {FeatureCode} to {OwnerUid} by user {UserId}.",
            request.Units, request.FeatureCode, request.OwnerUid, caller.GetUserId());

        return result.Id ?? 0;
    }

    public async Task<string?> ReverseAsync(
        ClaimsPrincipal caller, long entryId, string? notes, CancellationToken cancellationToken)
    {
        EnsureAdmin(caller);

        var result = await _ledger
            .ReverseAsync(entryId, notes, caller.GetUserId(), cancellationToken).ConfigureAwait(false);

        result.EnsureSuccess();

        _logger.LogWarning("Ledger entry {EntryId} reversed by user {UserId}.", entryId, caller.GetUserId());

        return result.Code;
    }

    // ---- helpers -----------------------------------------------------------

    /// <summary>
    /// Resolves a feature by code without a plan — for reads that do not gate.
    /// </summary>
    /// <remarks>
    /// ⚠️ Passes plan 0, which matches nothing, so HasMapping is always false
    /// here. That is fine: this path never decides access. Nothing may use it
    /// to gate — <see cref="ConsumeAsync"/> is the only method that decides.
    /// </remarks>
    private async Task<EntitlementResolution> ResolveFeatureOrThrowAsync(
        string featureCode, CancellationToken cancellationToken)
    {
        var feature = await _catalog.ResolveAsync(featureCode, 0, cancellationToken).ConfigureAwait(false);

        return feature ?? throw new NotFoundException("That feature does not exist.");
    }

    private static EntitlementDecision Refused(string code, string message) =>
        new() { Allowed = false, Code = code, Message = message, Consumed = false };

    /// <summary>
    /// Every administrative method on this service goes through here.
    /// </summary>
    /// <remarks>
    /// SETTINGS.MANAGE is seeded and held by SUPER_ADMIN alone. Deciding what a
    /// plan includes is a system setting, and gating it on an existing
    /// permission means the screen works the day it ships rather than after
    /// somebody remembers to grant a new one.
    /// </remarks>
    private static void EnsureAdmin(ClaimsPrincipal caller)
    {
        if (caller.GetUserType() != UserType.Admin
            || !caller.HasPermission(AppConstants.PermissionCodes.SettingsManage))
        {
            throw new ForbiddenException("You do not have permission to manage plans and features.");
        }
    }
}
