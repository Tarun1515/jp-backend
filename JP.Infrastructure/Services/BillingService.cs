using System.Security.Claims;
using JP.Core.Common;
using JP.Core.Constants;
using JP.Core.Enums;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Billing;
using JP.Domain.Common;
using JP.Infrastructure.Repositories;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Services;

/// <summary>
/// Billing, manual first. Phase 6.5.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 <see cref="VerifyAndActivateAsync"/> IS THE SEAM. One method owns the
/// whole transition — payment reaches SUCCESS, subscription activated. Today
/// the caller is an admin endpoint; when a gateway arrives it becomes a
/// callback endpoint calling the same method. Same business rule, new caller,
/// no redesign — the <c>IEmailService</c> / <c>IFileStorageService</c> pattern
/// this codebase already runs on (MONETIZATION_DESIGN 6.5-A).
/// </para>
/// <para>
/// 🔴 THE SEAM IS HERE AND NOT IN A PROCEDURE, and that is forced rather than
/// chosen: the payment lives in jp_mdm, the subscription in jp_app, no query
/// may cross (2.2), and there is no distributed transaction (2.48). So the two
/// halves are two procedures in two transactions, and this method reports the
/// truth about the handoff instead of smoothing it over — the same shape
/// <see cref="ApprovalService"/> uses for school approval.
/// </para>
/// <para>
/// ⚠️ The payment is NOT rolled back when activation fails. It cannot be — it is
/// committed in another database — and the money really did arrive. Recovery is
/// calling the method again: both halves are idempotent, the verify on the
/// payment reaching SUCCESS and the activation on the payment's Uid.
/// </para>
/// <para>
/// 🔒 A PAYMENT BUYS CAPABILITY AND NEVER CONTACT DETAILS (2.56, LOCKED).
/// Nothing here touches <c>fn_TeacherContactUnlocked</c>, which returns true on
/// exactly two paths: the teacher applied, or the teacher accepted an
/// invitation. A verified payment is not a third one, and the 2.56 greps assert
/// that against this file in both directions.
/// </para>
/// <para>
/// 🔴 PENDING CHANGES NOTHING. <see cref="RequestPlanChangeAsync"/> records an
/// intention and touches no entitlement, no subscription and no quota. The
/// active subscription rules until a payment is verified.
/// </para>
/// </remarks>
public interface IBillingService
{
    /// <summary>The plans the caller's user type can be on.</summary>
    Task<IReadOnlyList<PlanDto>> GetCatalogAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken);

    /// <summary>What the caller is on now, and what they have used of it.</summary>
    Task<CurrentPlanDto?> GetCurrentPlanAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken);

    /// <summary>Records an intention to move plan. Grants nothing.</summary>
    Task<PlanChangeRequestedDto> RequestPlanChangeAsync(
        ClaimsPrincipal caller, RequestPlanChangeRequest request,
        CancellationToken cancellationToken);

    /// <summary>Every subscription the caller has held.</summary>
    Task<IReadOnlyList<SubscriptionHistoryDto>> GetMyHistoryAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken);

    // ---- admin ----------------------------------------------------------

    Task<PagedResult<PendingPaymentDto>> GetPendingPaymentsAsync(
        ClaimsPrincipal caller, int pageNumber, int pageSize,
        CancellationToken cancellationToken);

    Task<PaymentDetailDto> GetPaymentAsync(
        ClaimsPrincipal caller, long paymentId, CancellationToken cancellationToken);

    /// <summary>🔴 THE SEAM. See the remarks on this interface.</summary>
    Task<VerifyPaymentResultDto> VerifyAndActivateAsync(
        ClaimsPrincipal caller, long paymentId, VerifyPaymentRequest request,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<SubscriptionHistoryDto>> GetHistoryForOwnerAsync(
        ClaimsPrincipal caller, Guid ownerUid, CancellationToken cancellationToken);
}

internal sealed class BillingService : IBillingService
{
    private readonly IBillingRepository _billing;
    private readonly ISubscriptionRepository _subscriptions;
    private readonly IPlanRepository _plans;
    private readonly IEntitlementLedgerRepository _ledger;
    private readonly IEntitlementRepository _catalog;
    private readonly ILogger<BillingService> _logger;

    public BillingService(
        IBillingRepository billing,
        ISubscriptionRepository subscriptions,
        IPlanRepository plans,
        IEntitlementLedgerRepository ledger,
        IEntitlementRepository catalog,
        ILogger<BillingService> logger)
    {
        _billing = billing;
        _subscriptions = subscriptions;
        _plans = plans;
        _ledger = ledger;
        _catalog = catalog;
        _logger = logger;
    }

    // =====================================================================
    //  The account's own side
    // =====================================================================

    public async Task<IReadOnlyList<PlanDto>> GetCatalogAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        /*
          🔴 The user type comes from the TOKEN, never from the request (2.39).
          A teacher cannot ask for school plans — there is no parameter for it,
          which is stronger than a check.
        */
        var userTypeId = (int)caller.GetUserType();

        var (plans, mappings) = await _billing
            .GetCatalogAsync(userTypeId, cancellationToken).ConfigureAwait(false);

        return plans.Select(p => new PlanDto
        {
            PlanId = p.PlanId,
            PlanCode = p.PlanCode,
            Name = p.Name,
            UserTypeId = p.UserTypeId,
            DurationDays = p.DurationDays,
            Price = p.Price,
            IsDefault = p.IsDefault,
            IsActive = p.IsActive,
            DisplayOrder = p.DisplayOrder,
            Features = mappings
                .Where(m => m.PlanId == p.PlanId)
                .Select(m => new PlanIncludesDto
                {
                    FeatureId = m.FeatureId,
                    FeatureCode = m.FeatureCode,
                    FeatureName = m.FeatureName,
                    IsIncluded = m.IsIncluded,
                    QuotaPerPeriod = m.QuotaPerPeriod,
                })
                .ToList(),
        }).ToList();
    }

    public async Task<CurrentPlanDto?> GetCurrentPlanAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        var ownerUid = OwnerUidOf(caller);
        var userTypeId = (int)caller.GetUserType();

        var subscription = await _subscriptions
            .GetCurrentAsync(ownerUid, cancellationToken).ConfigureAwait(false);

        /*
          ⚠️ Null is a real state the screen renders rather than crashes on. 3B
          found seven organisations holding a plan they should not have had, and
          the repair left the possibility of an account with none.
        */
        if (subscription is null) return null;

        var inForce = InForce(subscription.IsActive, subscription.StatusId, subscription.EndsOn);

        /*
          🔴 6.5-C — WHICH PLAN'S NUMBERS TO SHOW.

          A lapsed paid subscription reads as the free baseline, so the panel
          must describe the baseline too. Showing the paid plan's allowances
          beside a quota that is actually the free plan's is the specific lie
          this phase exists to avoid.
        */
        var effectivePlanId = subscription.PlanId;
        var onFreeBaseline = false;

        if (!inForce && subscription.StatusId == 1 && subscription.IsActive)
        {
            var fallback = await _plans
                .GetDefaultPlanAsync(userTypeId, cancellationToken).ConfigureAwait(false);

            if (fallback is not null)
            {
                effectivePlanId = fallback.PlanId;
                onFreeBaseline = true;
            }
        }

        var plan = await _plans.GetByIdAsync(effectivePlanId, cancellationToken)
            .ConfigureAwait(false);

        var usage = await UsageAsync(ownerUid, effectivePlanId, cancellationToken)
            .ConfigureAwait(false);

        return new CurrentPlanDto
        {
            SubscriptionId = subscription.SubscriptionId,
            PlanId = effectivePlanId,
            PlanCode = plan?.PlanCode ?? string.Empty,
            PlanName = plan?.Name ?? string.Empty,
            Price = plan?.Price ?? 0m,
            DurationDays = plan?.DurationDays,
            StartsOn = subscription.StartsOn,
            EndsOn = subscription.EndsOn,
            StatusId = subscription.StatusId,
            IsActive = subscription.IsActive,
            InForce = inForce,
            OnFreeBaseline = onFreeBaseline,
            Usage = usage,
        };
    }

    public async Task<PlanChangeRequestedDto> RequestPlanChangeAsync(
        ClaimsPrincipal caller, RequestPlanChangeRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);
        ArgumentNullException.ThrowIfNull(request);

        /*
          🔒 BILLING.MANAGE — a plan change is a financial commitment.

          6.5A had no check here, which let any member of a school commit it to
          a payment: a SCHOOL_VIEWER is read-only by design, and this was the
          one action that escaped that. See AppConstants.BillingManage.

          ⚠️ Checked HERE and not on the catalog or the panel. Reading what plan
          you are on is a property of the account, not a privilege.
        */
        EnsureCanManageBilling(caller);

        var ownerUid = OwnerUidOf(caller);
        var userTypeId = (int)caller.GetUserType();
        var orgUid = caller.GetOrganizationUid();

        var row = await _billing.RequestPlanChangeAsync(
            ownerUid,
            orgUid,
            caller.GetUserId(),
            userTypeId,
            request.PlanId,
            request.PaymentModeId,
            cancellationToken).ConfigureAwait(false);

        /*
          🔴 Branch on the CODE, never on the message (2.21). NOT_FOUND covers
          both "no such plan" and "that plan is not for your user type" — 2.6
          says a refusal must not confirm that something exists, and a teacher
          probing plan ids learns nothing about the school tier line-up.
        */
        if (row.Status != 1)
        {
            throw row.Code switch
            {
                "NOT_FOUND" => new NotFoundException(row.Message ?? "That plan was not found."),
                "ALREADY_REQUESTED" => new BusinessRuleException(
                    row.Message ?? "A plan change is already awaiting payment for this account."),
                _ => new BusinessRuleException(row.Message ?? "That request could not be recorded."),
            };
        }

        return new PlanChangeRequestedDto
        {
            RequestId = row.RequestId ?? 0,
            RequestNo = row.RequestNo ?? string.Empty,
            PaymentId = row.PaymentId ?? 0,
            PaymentUid = row.PaymentUid ?? Guid.Empty,
            PriceQuoted = row.PriceQuoted ?? 0m,
        };
    }

    public Task<IReadOnlyList<SubscriptionHistoryDto>> GetMyHistoryAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        return HistoryAsync(OwnerUidOf(caller), cancellationToken);
    }

    // =====================================================================
    //  The admin side
    // =====================================================================

    public async Task<PagedResult<PendingPaymentDto>> GetPendingPaymentsAsync(
        ClaimsPrincipal caller, int pageNumber, int pageSize,
        CancellationToken cancellationToken)
    {
        EnsureCanVerify(caller);

        var rows = await _billing.GetPendingAsync(pageNumber, pageSize, cancellationToken)
            .ConfigureAwait(false);

        return new PagedResult<PendingPaymentDto>
        {
            Items = rows.Select(ToDto).ToList(),
            TotalRecords = rows.Count > 0 ? rows[0].TotalRecords : 0,
        };
    }

    public async Task<PaymentDetailDto> GetPaymentAsync(
        ClaimsPrincipal caller, long paymentId, CancellationToken cancellationToken)
    {
        EnsureCanVerify(caller);

        var row = await _billing.GetPaymentAsync(paymentId, cancellationToken)
            .ConfigureAwait(false)
            ?? throw new NotFoundException("That payment was not found.");

        return new PaymentDetailDto
        {
            PaymentId = row.PaymentId,
            PaymentUid = row.PaymentUid,
            RequestId = row.RequestId,
            RequestNo = row.RequestNo,
            EntityUid = row.EntityUid,
            OrganizationUid = row.OrganizationUid,
            SubmittedOn = row.SubmittedOn,
            PlanId = row.PlanId,
            PlanCode = row.PlanCode,
            PlanName = row.PlanName,
            UserTypeId = row.UserTypeId,
            DurationDays = row.DurationDays,
            Amount = row.Amount,
            PriceQuoted = row.PriceQuoted,
            PaymentModeId = row.PaymentModeId,
            PaymentModeName = row.PaymentModeName,
            GatewayRefNo = row.GatewayRefNo,
            Remarks = row.Remarks,
            CreatedOn = row.CreatedOn,
            ShortBy = row.ShortBy,
            AmountDiffers = row.AmountDiffers,
            PaymentStatusId = row.PaymentStatusId,
            PaymentStatusCode = row.PaymentStatusCode,
            PaidOn = row.PaidOn,
            VerifiedByUserId = row.VerifiedByUserId,
            RequestStatusId = row.RequestStatusId,
            ReceiptNo = row.ReceiptNo,
            ReceiptIssuedOn = row.ReceiptIssuedOn,
        };
    }

    /// <inheritdoc />
    public async Task<VerifyPaymentResultDto> VerifyAndActivateAsync(
        ClaimsPrincipal caller, long paymentId, VerifyPaymentRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        EnsureCanVerify(caller);

        var payment = await _billing.GetPaymentAsync(paymentId, cancellationToken)
            .ConfigureAwait(false)
            ?? throw new NotFoundException("That payment was not found.");

        /*
          🔴 THE MISMATCH RULE LIVES HERE, NOT IN THE PROCEDURE (6.5-B).

          A school that transferred less than the price HAS paid that amount,
          and a procedure refusing to record it would not prevent an
          underpayment — it would make the real state of the world
          unrepresentable, and the correction would happen in SSMS with no
          trail. So the ledger records what arrived, and the REMARK is what
          turns an unexplained difference into a conversation.

          ⚠️ And it is in this layer specifically because the GATEWAY caller
          that arrives later has nobody to ask for a remark (6.5-A). A CHECK
          constraint here would make that seam a hope.
        */
        if (payment.PriceQuoted is not null
            && request.Amount != payment.PriceQuoted
            && string.IsNullOrWhiteSpace(request.Remarks))
        {
            throw new ValidationAppException(
                nameof(VerifyPaymentRequest.Remarks),
                "The amount differs from the plan's price, so a remark explaining why is required.");
        }

        var actorUserId = caller.GetUserId();

        var verified = await _billing.VerifyAsync(
            paymentId,
            request.Amount,
            request.PaymentModeId == 0 ? null : request.PaymentModeId,
            request.ReferenceNo,
            request.Remarks,
            request.PaidOn,
            actorUserId,

            // 🔴 ADMIN here; a callback will pass GATEWAY and no user (6.5-A).
            "ADMIN",
            cancellationToken).ConfigureAwait(false);

        if (verified.Status != 1)
        {
            throw verified.Code switch
            {
                "NOT_FOUND" => new NotFoundException(verified.Message ?? "That payment was not found."),
                _ => new BusinessRuleException(verified.Message ?? "That payment could not be verified."),
            };
        }

        var result = new VerifyPaymentResultDto
        {
            Verified = true,
            AlreadyVerified = verified.AlreadyVerified,
            ReceiptNo = verified.ReceiptNo,
            PlanId = verified.PlanId,
            PlanName = verified.PlanName,
            Message = verified.Message ?? "The payment is verified.",
        };

        /*
          🔴 THE CROSS-DATABASE HANDOFF.

          The payment is committed. Everything from here is another database
          with another transaction and any of it can fail — and this method's
          job is to report the truth about that rather than smooth it over
          (2.48, the shape ApprovalService uses).

          Note what is NOT done: the verification is not rolled back if
          activation fails. It cannot be, and pretending otherwise would be
          worse than saying so. Recovery is calling this endpoint again — the
          verify half answers "already verified" with the same payload and the
          activation half then completes.
        */
        if (verified.EntityUid is null || verified.PlanId is null)
        {
            _logger.LogError(
                "Payment {PaymentId} verified but returned no owner or plan; activation cannot run.",
                paymentId);

            result.ActivationCompleted = false;
            result.ActivationError = "The payment was recorded but the plan could not be activated.";
            return result;
        }

        try
        {
            var activation = await _subscriptions.ActivateAsync(
                verified.EntityUid.Value,
                verified.PlanId.Value,
                verified.PaymentUid ?? Guid.Empty,
                verified.DurationDays,
                actorUserId,
                cancellationToken).ConfigureAwait(false);

            result.ActivationCompleted = activation.Status == 1;
            result.AlreadyActivated = activation.AlreadyActivated;
            result.SubscriptionId = activation.SubscriptionId;
            result.EndsOn = activation.EndsOn;

            if (activation.Status != 1)
            {
                result.ActivationError = activation.Message
                    ?? "The payment was recorded but the plan could not be activated.";

                _logger.LogError(
                    "Payment {PaymentId} verified; activation refused with {Code}. The money is recorded "
                    + "and the plan is not active — retrying the verify endpoint will complete it.",
                    paymentId, activation.Code);
            }
        }
        catch (Exception ex)
        {
            /*
              ⚠️ Caught and reported, not rethrown. A 500 here would tell the
              admin the verification failed, and it did not — the money is
              recorded. Telling them the half-truth is how a payment gets
              entered twice.
            */
            _logger.LogError(
                ex,
                "Payment {PaymentId} verified but activation threw. The money IS recorded; "
                + "retrying the verify endpoint will complete the activation (both halves are idempotent).",
                paymentId);

            result.ActivationCompleted = false;
            result.ActivationError =
                "The payment was recorded but the plan could not be activated. Try again.";
        }

        return result;
    }

    public Task<IReadOnlyList<SubscriptionHistoryDto>> GetHistoryForOwnerAsync(
        ClaimsPrincipal caller, Guid ownerUid, CancellationToken cancellationToken)
    {
        EnsureCanVerify(caller);

        return HistoryAsync(ownerUid, cancellationToken);
    }

    // =====================================================================
    //  Internals
    // =====================================================================

    /// <summary>
    /// 🔴 The same predicate as <c>fn_SubscriptionInForce</c>, and the ONLY
    /// place it is written in C#.
    /// </summary>
    /// <remarks>
    /// The authority is the SQL function — it is what the consume path uses
    /// under its lock. This exists because a read-only panel should not have to
    /// take that lock to answer "has my plan ended", and it is kept to one
    /// private method so there is exactly one thing to change if the rule ever
    /// does. The verification asserts the two agree on a lapsed row.
    /// </remarks>
    private static bool InForce(bool isActive, int statusId, DateTime? endsOn) =>
        isActive && statusId == 1 && (endsOn is null || endsOn > DateTime.UtcNow);

    /// <summary>
    /// 🔴 The owner, from the TOKEN only (2.39) — the organisation for a school
    /// and the user for a teacher (2.51). Never a parameter a client picks.
    /// </summary>
    private static Guid OwnerUidOf(ClaimsPrincipal caller) =>
        caller.GetUserType() == UserType.Teacher
            ? caller.GetUserUid()
            : caller.RequireOrganizationUid();

    /// <summary>
    /// 🔒 BILLING.MANAGE — SCHOOL_OWNER and TEACHER only (jp_sso 007).
    /// </summary>
    /// <remarks>
    /// ⚠️ No user-type check beside it, unlike <see cref="EnsureCanVerify"/>.
    /// The permission is held by one school role and the teacher role, so the
    /// type is already implied — and adding a redundant type check would be a
    /// second answer to a question the grant already answers, which is how the
    /// two come to disagree.
    /// </remarks>
    private static void EnsureCanManageBilling(ClaimsPrincipal caller)
    {
        if (!caller.HasPermission(AppConstants.PermissionCodes.BillingManage))
        {
            throw new ForbiddenException(
                "You do not have permission to change this account's plan.");
        }
    }

    /// <summary>
    /// 🔒 PAYMENT.VERIFY, held by SUPER_ADMIN alone and by no school or teacher
    /// role (jp_sso 006). A school verifying its own payment is the entire
    /// attack, and the verification forces the negative on both.
    /// </summary>
    private static void EnsureCanVerify(ClaimsPrincipal caller)
    {
        ArgumentNullException.ThrowIfNull(caller);

        if (caller.GetUserType() != UserType.Admin
            || !caller.HasPermission(AppConstants.PermissionCodes.PaymentVerify))
        {
            throw new ForbiddenException("You do not have permission to verify payments.");
        }
    }

    private async Task<IReadOnlyList<SubscriptionHistoryDto>> HistoryAsync(
        Guid ownerUid, CancellationToken cancellationToken)
    {
        var rows = await _subscriptions.GetHistoryAsync(ownerUid, cancellationToken)
            .ConfigureAwait(false);

        var names = new Dictionary<int, string>();

        foreach (var planId in rows.Select(r => r.PlanId).Distinct())
        {
            var plan = await _plans.GetByIdAsync(planId, cancellationToken).ConfigureAwait(false);
            names[planId] = plan?.Name ?? string.Empty;
        }

        return rows.Select(r => new SubscriptionHistoryDto
        {
            SubscriptionId = r.SubscriptionId,
            PlanId = r.PlanId,
            PlanName = names.TryGetValue(r.PlanId, out var n) ? n : string.Empty,
            StartsOn = r.StartsOn,
            EndsOn = r.EndsOn,
            StatusId = r.StatusId,
            IsActive = r.IsActive,
            InForce = r.InForce,
            SourcePaymentUid = r.SourcePaymentUid,
        }).ToList();
    }

    /// <summary>
    /// Used against allowed, per feature, for the plan actually in force.
    /// </summary>
    /// <remarks>
    /// 🔴 DERIVED, never stored (2.64). The balance read sums the ledger for the
    /// current period; the allowance comes from the plan's mapping. Nothing here
    /// writes anything, and a Boolean feature contributes no ledger row at all.
    /// </remarks>
    private async Task<IReadOnlyList<FeatureUsageDto>> UsageAsync(
        Guid ownerUid, int planId, CancellationToken cancellationToken)
    {
        var matrix = await _catalog.GetMatrixAsync(cancellationToken).ConfigureAwait(false);
        var usage = new List<FeatureUsageDto>();

        foreach (var mapping in matrix.Mappings.Where(m => m.PlanId == planId && m.IsIncluded))
        {
            var feature = matrix.Features.FirstOrDefault(f => f.FeatureId == mapping.FeatureId);
            if (feature is null) continue;

            var balance = await _ledger
                .GetBalanceAsync(ownerUid, mapping.FeatureId, cancellationToken)
                .ConfigureAwait(false);

            var used = balance?.QuotaUsed ?? 0;

            usage.Add(new FeatureUsageDto
            {
                FeatureId = mapping.FeatureId,
                FeatureCode = feature.FeatureCode,
                FeatureName = feature.Name,
                Used = used,
                Allowed = mapping.QuotaPerPeriod,

                /*
                  🔴 CLAMPED AT ZERO (6.5-D). A downgrade below what has already
                  been used leaves used > allowed, and "−1 posts remaining" is a
                  bug report where "none, and your plan allows 2" is something a
                  customer can act on.
                */
                Remaining = mapping.QuotaPerPeriod is null
                    ? null
                    : Math.Max(0, mapping.QuotaPerPeriod.Value - used),
            });
        }

        return usage;
    }

    private static PendingPaymentDto ToDto(PendingPaymentRow row) => new()
    {
        PaymentId = row.PaymentId,
        PaymentUid = row.PaymentUid,
        RequestId = row.RequestId,
        RequestNo = row.RequestNo,
        EntityUid = row.EntityUid,
        OrganizationUid = row.OrganizationUid,
        RequestorUserId = row.RequestorUserId,
        SubmittedOn = row.SubmittedOn,
        PlanId = row.PlanId,
        PlanCode = row.PlanCode,
        PlanName = row.PlanName,
        UserTypeId = row.UserTypeId,
        DurationDays = row.DurationDays,
        Amount = row.Amount,
        PriceQuoted = row.PriceQuoted,
        PaymentModeId = row.PaymentModeId,
        PaymentModeName = row.PaymentModeName,
        GatewayRefNo = row.GatewayRefNo,
        Remarks = row.Remarks,
        CreatedOn = row.CreatedOn,
        ShortBy = row.ShortBy,
        AmountDiffers = row.AmountDiffers,
    };
}
