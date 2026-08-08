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
