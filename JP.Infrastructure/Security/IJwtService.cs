using System.Security.Claims;
using JP.Core.Enums;

namespace JP.Infrastructure.Security;

/// <summary>
/// Everything that goes into an access token, gathered from
/// <c>USP_GetUserClaims</c>.
/// </summary>
public sealed record JwtUserContext
{
    public required long UserId { get; init; }

    public required Guid UserUid { get; init; }

    public required UserType UserType { get; init; }

    /// <summary>
    /// Account status at issue time. A pending school receives a real token
    /// carrying <see cref="UserStatus.PendingApproval"/> — it is
    /// <c>[RequireActiveAccount]</c> that blocks business endpoints, not the
    /// absence of a token.
    /// </summary>
    public required UserStatus Status { get; init; }

    /// <summary>
    /// Tenant boundary. Null for admins and teachers, who belong to no
    /// organisation.
    /// </summary>
    public Guid? OrganizationUid { get; init; }

    public IReadOnlyList<string> Roles { get; init; } = [];

    public IReadOnlyList<string> Permissions { get; init; } = [];
}

/// <summary>An issued access token.</summary>
public sealed record AccessTokenResult(string Token, DateTime ExpiresOnUtc, string TokenId);

/// <summary>
/// An issued refresh token. <see cref="SecureToken.PlainText"/> goes to the
/// client; <see cref="SecureToken.Hash"/> is what
/// <c>t_sso_user_tokens.TokenHash</c> stores.
/// </summary>
public sealed record RefreshTokenResult(SecureToken Token, DateTime ExpiresOnUtc);

/// <summary>Issues and validates JWTs.</summary>
public interface IJwtService
{
    /// <summary>Issues a signed access token carrying the standard claim set.</summary>
    AccessTokenResult CreateAccessToken(JwtUserContext user);

    /// <summary>
    /// Generates a refresh token. Opaque and random — not a JWT, because it
    /// must be revocable, and a self-contained token cannot be revoked.
    /// </summary>
    RefreshTokenResult CreateRefreshToken();

    /// <summary>
    /// Validates a token and returns its principal, or <see langword="null"/>
    /// if it fails validation for any reason.
    /// </summary>
    /// <param name="token">The raw JWT.</param>
    /// <param name="validateLifetime">
    /// Pass <see langword="false"/> only on the refresh path, where an expired
    /// access token is exactly what is expected and the refresh token is what
    /// actually carries the authority.
    /// </param>
    Task<ClaimsPrincipal?> ValidateAccessTokenAsync(string token, bool validateLifetime = true);
}
