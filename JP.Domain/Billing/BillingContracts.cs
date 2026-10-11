namespace JP.Domain.Billing;

/// <summary>One plan a caller of this user type could be on.</summary>
/// <remarks>
/// ⚠️ <c>IsActive</c> arrives through an alias in the procedure
/// (<c>Is_Active AS IsActive</c>) and cannot work without one — Dapper does not
/// strip underscores and the failure is silent (2.61, G25).
/// </remarks>
public sealed class PlanDto
{
    public int PlanId { get; set; }

    public string PlanCode { get; set; } = string.Empty;

    public string Name { get; set; } = string.Empty;

    public int UserTypeId { get; set; }

    /// <summary>Null = perpetual, which is every free plan.</summary>
    public int? DurationDays { get; set; }

    public decimal Price { get; set; }

    public bool IsDefault { get; set; }

    public bool IsActive { get; set; }

    public int DisplayOrder { get; set; }

    /// <summary>What this plan maps to — the half a customer compares.</summary>
    public IReadOnlyList<PlanIncludesDto> Features { get; set; } = [];
}

/// <summary>One feature a plan includes, and how much of it.</summary>
public sealed class PlanIncludesDto
{
    public int FeatureId { get; set; }

    public string FeatureCode { get; set; } = string.Empty;

    public string FeatureName { get; set; } = string.Empty;

    public bool IsIncluded { get; set; }

    /// <summary>
    /// Null = unlimited within the plan. NOT the same as zero, and the screen
    /// must not render it as one — the engine uses the identical convention
    /// (<c>USP_ConsumeFeatureCore.@QuotaPerPeriod</c>).
    /// </summary>
    public int? QuotaPerPeriod { get; set; }
}

/// <summary>
/// What an account is on right now, and what it has used of it.
/// </summary>
/// <remarks>
/// 🔴 <see cref="InForce"/> is NOT <c>IsActive</c>. A paid subscription past
/// <c>EndsOn</c> is still an ACTIVE row and is no longer in force — it reads as
/// the free baseline instead (MONETIZATION_DESIGN 6.5-C). Both are returned so
/// a screen can say "your plan ended on the 3rd" rather than silently showing
/// different numbers.
/// </remarks>
public sealed class CurrentPlanDto
{
    public long SubscriptionId { get; set; }

    public int PlanId { get; set; }

    public string PlanCode { get; set; } = string.Empty;

    public string PlanName { get; set; } = string.Empty;

    public decimal Price { get; set; }

    public int? DurationDays { get; set; }

    public DateTime StartsOn { get; set; }

    public DateTime? EndsOn { get; set; }

    public int StatusId { get; set; }

    public bool IsActive { get; set; }

    /// <summary>The one predicate, from <c>fn_SubscriptionInForce</c>.</summary>
    public bool InForce { get; set; }

    /// <summary>
    /// True when the row is a lapsed paid plan and the numbers below describe
    /// the free baseline rather than what was bought.
    /// </summary>
    public bool OnFreeBaseline { get; set; }

    /// <summary>
    /// What the account has used this period, per feature — the DERIVED numbers
    /// the engine already computes. Never stored (2.64).
    /// </summary>
    public IReadOnlyList<FeatureUsageDto> Usage { get; set; } = [];
}

/// <summary>Used against allowed, for one feature, this period.</summary>
public sealed class FeatureUsageDto
{
    public int FeatureId { get; set; }

    public string FeatureCode { get; set; } = string.Empty;

    public string FeatureName { get; set; } = string.Empty;

    public int Used { get; set; }

    /// <summary>Null = unlimited within the plan.</summary>
    public int? Allowed { get; set; }

    /// <summary>
    /// 🔴 Clamped at zero, never negative. A downgrade below what has already
    /// been used leaves <c>Used &gt; Allowed</c>, and "−1 posts remaining" is a
    /// bug report where "none, and your plan allows 2" is actionable (6.5-D).
    /// </summary>
    public int? Remaining { get; set; }
}

/// <summary>A school or teacher asking to move to a plan.</summary>
public sealed class RequestPlanChangeRequest
{
    public int PlanId { get; set; }

    /// <summary>
    /// How they intend to pay. Defaults to NEFT — the mode the screen offers
    /// first, and the only one that needs no physical handover.
    /// </summary>
    public int PaymentModeId { get; set; } = 2;
}

/// <summary>What the requester is told.</summary>
/// <remarks>
/// ⚠️ <see cref="RequestNo"/> is the thing a school quotes to support, which is
/// why it is returned rather than only stored (2.46).
/// </remarks>
public sealed class PlanChangeRequestedDto
{
    public long RequestId { get; set; }

    public string RequestNo { get; set; } = string.Empty;

    public long PaymentId { get; set; }

    public Guid PaymentUid { get; set; }

    /// <summary>
    /// The price AT REQUEST TIME. Prices are data and change (2.7); this is
    /// what was agreed.
    /// </summary>
    public decimal PriceQuoted { get; set; }
}

/// <summary>One row of the admin queue.</summary>
public sealed class PendingPaymentDto
{
    public long PaymentId { get; set; }

    public Guid PaymentUid { get; set; }

    public long RequestId { get; set; }

    public string RequestNo { get; set; } = string.Empty;

    public Guid EntityUid { get; set; }

    public Guid? OrganizationUid { get; set; }

    public long RequestorUserId { get; set; }

    public DateTime SubmittedOn { get; set; }

    public int PlanId { get; set; }

    public string PlanCode { get; set; } = string.Empty;

    public string PlanName { get; set; } = string.Empty;

    public int UserTypeId { get; set; }

    public int? DurationDays { get; set; }

    /// <summary>What is recorded — expected until an admin replaces it.</summary>
    public decimal Amount { get; set; }

    /// <summary>What it cost when the account agreed to it.</summary>
    public decimal? PriceQuoted { get; set; }

    public int PaymentModeId { get; set; }

    public string PaymentModeName { get; set; } = string.Empty;

    public string? GatewayRefNo { get; set; }

    public string? Remarks { get; set; }

    public DateTime CreatedOn { get; set; }

    /// <summary>
    /// 🔴 Positive = short, negative = overpaid. Computed in SQL so the queue
    /// and the form cannot get the sign different ways round (6.5-B).
    /// </summary>
    public decimal ShortBy { get; set; }

    public bool AmountDiffers { get; set; }
}

/// <summary>Everything the verify form needs, including what it already was.</summary>
/// <remarks>
/// 🔴 A STANDALONE TYPE RATHER THAN A SUBCLASS OF
/// <see cref="PendingPaymentDto"/>, and the duplication is deliberate.
///
/// <para>
/// 6B learned this with the teacher-search row: inheriting forces the base to
/// be unsealed, and an unsealed DTO is one somebody later adds a field to for
/// one screen's convenience — which then appears on the runtime type of every
/// object the serialiser sees. The first draft of this file did inherit, and the
/// compiler refused it because the base is sealed. That refusal was right.
/// </para>
/// <para>
/// ⚠️ So the queue shape and the form shape are two contracts that happen to
/// overlap, and they are free to diverge — which is the honest description of
/// what they are.
/// </para>
/// </remarks>
public sealed class PaymentDetailDto
{
    public long PaymentId { get; set; }

    public Guid PaymentUid { get; set; }

    public long RequestId { get; set; }

    public string RequestNo { get; set; } = string.Empty;

    public Guid EntityUid { get; set; }

    public Guid? OrganizationUid { get; set; }

    public DateTime SubmittedOn { get; set; }

    public int PlanId { get; set; }

    public string PlanCode { get; set; } = string.Empty;

    public string PlanName { get; set; } = string.Empty;

    public int UserTypeId { get; set; }

    public int? DurationDays { get; set; }

    public decimal Amount { get; set; }

    public decimal? PriceQuoted { get; set; }

    public int PaymentModeId { get; set; }

    public string PaymentModeName { get; set; } = string.Empty;

    public string? GatewayRefNo { get; set; }

    public string? Remarks { get; set; }

    public DateTime CreatedOn { get; set; }

    /// <summary>Positive = short, negative = overpaid. Computed in SQL (6.5-B).</summary>
    public decimal ShortBy { get; set; }

    public bool AmountDiffers { get; set; }

    public int PaymentStatusId { get; set; }

    public string PaymentStatusCode { get; set; } = string.Empty;

    public DateTime? PaidOn { get; set; }

    public long? VerifiedByUserId { get; set; }

    public int RequestStatusId { get; set; }

    public string? ReceiptNo { get; set; }

    public DateTime? ReceiptIssuedOn { get; set; }
}

/// <summary>An admin recording that money arrived.</summary>
/// <remarks>
/// 🔴 <see cref="Remarks"/> is REQUIRED when <see cref="Amount"/> differs from
/// the quoted price — enforced in the service, NOT in the procedure, because the
/// gateway caller that arrives later has nobody to ask for one (6.5-A). Putting
/// the rule in SQL would make that seam a hope.
/// </remarks>
public sealed class VerifyPaymentRequest
{
    public decimal Amount { get; set; }

    public int PaymentModeId { get; set; }

    /// <summary>The UTR, the cheque number, the receipt book number.</summary>
    public string? ReferenceNo { get; set; }

    public string? Remarks { get; set; }

    /// <summary>
    /// When the money actually arrived, which is not when the admin got round
    /// to recording it. Null = now.
    /// </summary>
    public DateTime? PaidOn { get; set; }
}

/// <summary>
/// The result of the whole seam: payment verified, subscription activated.
/// </summary>
/// <remarks>
/// 🔴 <see cref="ActivationCompleted"/> reports the truth about a handoff that
/// spans two databases with no distributed transaction (2.2, 2.48). The payment
/// is NOT rolled back when activation fails — it cannot be, it is committed
/// elsewhere, and the money really did arrive. Recovery is calling the endpoint
/// again: both halves are idempotent (6.5-A).
/// </remarks>
public sealed class VerifyPaymentResultDto
{
    public bool Verified { get; set; }

    public bool AlreadyVerified { get; set; }

    public string? ReceiptNo { get; set; }

    public bool ActivationCompleted { get; set; }

    public string? ActivationError { get; set; }

    public bool AlreadyActivated { get; set; }

    public long? SubscriptionId { get; set; }

    public int? PlanId { get; set; }

    public string? PlanName { get; set; }

    public DateTime? EndsOn { get; set; }

    public string Message { get; set; } = string.Empty;
}

/// <summary>One subscription an account has held.</summary>
public sealed class SubscriptionHistoryDto
{
    public long SubscriptionId { get; set; }

    public int PlanId { get; set; }

    public string PlanName { get; set; } = string.Empty;

    public DateTime StartsOn { get; set; }

    public DateTime? EndsOn { get; set; }

    public int StatusId { get; set; }

    public bool IsActive { get; set; }

    /// <summary>From <c>fn_SubscriptionInForce</c> — never re-derived here.</summary>
    public bool InForce { get; set; }

    /// <summary>Null on every row provisioning opened — nobody paid for those.</summary>
    public Guid? SourcePaymentUid { get; set; }
}
