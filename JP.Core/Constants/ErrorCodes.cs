namespace JP.Core.Constants;

/// <summary>
/// Machine-readable codes carried in <see cref="Common.Response{T}.Code"/>.
/// </summary>
/// <remarks>
/// These are a public API contract. The Angular error interceptor and the
/// route guards branch on these exact strings, so renaming one is a breaking
/// change that must be made on both sides at once.
/// </remarks>
public static class ErrorCodes
{
    // ---- account state -----------------------------------------------------

    /// <summary>
    /// Authenticated, but the account is not yet approved (StatusId = 1).
    /// Returned as HTTP 403 by <c>[RequireActiveAccount]</c>. The portal
    /// redirects to the pending screen rather than logging the user out —
    /// a pending school still has to be able to upload its documents.
    /// </summary>
    public const string AccountPending = "ACCOUNT_PENDING";

    public const string AccountRejected = "ACCOUNT_REJECTED";
    public const string AccountSuspended = "ACCOUNT_SUSPENDED";
    public const string AccountLocked = "ACCOUNT_LOCKED";
    public const string AccountResubmitRequired = "ACCOUNT_RESUBMIT_REQUIRED";
    public const string AccountInactive = "ACCOUNT_INACTIVE";

    // ---- authentication ----------------------------------------------------

    /// <summary>
    /// Deliberately covers both "no such user" and "wrong password". Splitting
    /// them would let an attacker enumerate registered email addresses.
    /// </summary>
    public const string InvalidCredentials = "INVALID_CREDENTIALS";

    public const string Unauthorized = "UNAUTHORIZED";
    public const string Forbidden = "FORBIDDEN";
    public const string TokenInvalid = "TOKEN_INVALID";
    public const string TokenExpired = "TOKEN_EXPIRED";
    public const string TokenRevoked = "TOKEN_REVOKED";
    public const string TokenAlreadyUsed = "TOKEN_ALREADY_USED";

    // ---- OTP ---------------------------------------------------------------

    public const string OtpInvalid = "OTP_INVALID";
    public const string OtpExpired = "OTP_EXPIRED";
    public const string OtpMaxAttempts = "OTP_MAX_ATTEMPTS";

    // ---- password ----------------------------------------------------------

    public const string PasswordReused = "PASSWORD_REUSED";
    public const string PasswordIncorrect = "PASSWORD_INCORRECT";
    public const string PasswordPolicyFailed = "PASSWORD_POLICY_FAILED";

    // ---- registration / uniqueness -----------------------------------------

    public const string DuplicateEmail = "DUPLICATE_EMAIL";
    public const string DuplicateMobile = "DUPLICATE_MOBILE";
    public const string DuplicateRecord = "DUPLICATE_RECORD";

    // ---- entitlement engine (Phase 2.5) ------------------------------------

    /*
      🔴 These are distinct on purpose, and the UI treatment differs sharply:
      QUOTA_EXHAUSTED is an upgrade prompt, PLAN_LACKS_FEATURE is a DIFFERENT
      upgrade prompt, FEATURE_DISABLED is "we have turned this off", and
      SUBSCRIPTION_MISSING is "contact us". Collapsing any two of them would
      make one of those screens lie.

      ⚠️ The engine NEVER speaks about contact details. A subscription buys
      capability — search, invites — never a teacher's phone number (2.56).
    */

    /// <summary>
    /// The feature's kill switch is off for everyone
    /// (<c>m_mdm_features.Is_Active = 0</c>), or the code is unknown.
    /// </summary>
    /// <remarks>
    /// Outranks every other refusal: a kill switch that could be defeated by
    /// holding the right plan is not a kill switch. An operator during an
    /// incident gets one predictable answer rather than a different one per
    /// plan.
    /// </remarks>
    public const string FeatureDisabled = "FEATURE_DISABLED";

    /// <summary>
    /// 🔴 No subscription row exists for the owner. A DATA-INTEGRITY ERROR, not
    /// a normal state — every account has a plan from the moment it exists (2F
    /// provisioning, G21's closure). Logged at Error with the OwnerUid.
    /// </summary>
    public const string SubscriptionMissing = "SUBSCRIPTION_MISSING";

    /// <summary>Expired, cancelled or deactivated. The customer's situation.</summary>
    public const string SubscriptionInactive = "SUBSCRIPTION_INACTIVE";

    /// <summary>
    /// The plan does not include the feature — either mapped as excluded, or
    /// not mapped at all. Absence of a mapping is absence of a decision, and
    /// the engine refuses on it.
    /// </summary>
    public const string PlanLacksFeature = "PLAN_LACKS_FEATURE";

    /// <summary>Quota spent for this period AND no credits left. Both, not either.</summary>
    public const string QuotaExhausted = "QUOTA_EXHAUSTED";

    /// <summary>
    /// 🔴 A SUCCESS code, not a failure. The same reference was already
    /// charged, so nothing happened and nothing was charged twice.
    /// </summary>
    /// <remarks>
    /// A retried job posting told "you already paid for this" and then treated
    /// as an error by its caller is exactly how a customer gets charged twice
    /// by a system built not to charge them twice.
    /// </remarks>
    public const string AlreadyConsumed = "ALREADY_CONSUMED";

    /// <summary>
    /// The insert collided on the reference index, and the row it collided with
    /// was gone by the time it was re-read — a reversal landed in between.
    /// Retryable, and deliberately not retried inside the procedure.
    /// </summary>
    public const string ConsumeConflict = "CONSUME_CONFLICT";

    /// <summary>
    /// The owner's plan changed between the service resolving its features and
    /// the procedure taking its lock.
    /// </summary>
    /// <remarks>
    /// ⚠️ Internal, and a caller should never see it: the service re-resolves
    /// and retries once. It exists because the plan must be read (jp_app)
    /// before its mapping can be looked up (jp_mdm) and the two databases
    /// cannot join (2.2) — so there is a real window, and the alternative to
    /// naming it is pricing a consume against a plan the customer has left.
    /// </remarks>
    public const string PlanChanged = "PLAN_CHANGED";

    // ---- generic -----------------------------------------------------------

    public const string ValidationFailed = "VALIDATION_FAILED";
    public const string NotFound = "NOT_FOUND";
    public const string BusinessRuleViolated = "BUSINESS_RULE_VIOLATED";

    /// <summary>RowVersion did not match — somebody else saved first.</summary>
    public const string ConcurrencyConflict = "CONCURRENCY_CONFLICT";

    public const string RateLimited = "RATE_LIMITED";
    public const string FileTooLarge = "FILE_TOO_LARGE";
    public const string FileTypeNotAllowed = "FILE_TYPE_NOT_ALLOWED";

    /// <summary>Unhandled server fault. Never carries internal detail to the client.</summary>
    public const string InternalError = "INTERNAL_ERROR";
}
