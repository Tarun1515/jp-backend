namespace JP.Core.Enums;

/// <summary>
/// Mirrors <c>m_sso_token_types</c>.
/// </summary>
/// <remarks>
/// Every one of these is stored in <c>t_sso_user_tokens</c> as a hash. The
/// plaintext token exists only in the response body or the email that carries
/// it, and is never written to the database or to a log.
/// </remarks>
public enum TokenType
{
    Refresh = 1,
    PasswordReset = 2,
    EmailVerify = 3,
    Invite = 4,
}
