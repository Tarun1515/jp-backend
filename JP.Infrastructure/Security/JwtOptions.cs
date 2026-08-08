using System.ComponentModel.DataAnnotations;
using JP.Core.Constants;

namespace JP.Infrastructure.Security;

/// <summary>
/// JWT configuration, bound from the <c>Jwt</c> section.
/// </summary>
/// <remarks>
/// <see cref="Key"/> must NOT live in appsettings.json. In development it comes
/// from .NET user-secrets; in production from an environment variable or key
/// vault. Both APIs must be configured with the same key — JP.Sso.Api issues
/// the tokens and JP.App.Api validates them.
/// <para>
/// These annotations are validated at startup (<c>ValidateOnStart</c>), so a
/// missing or too-short key stops the application booting rather than
/// producing tokens nobody can validate.
/// </para>
/// </remarks>
public sealed class JwtOptions
{
    public const string SectionName = "Jwt";

    /// <summary>
    /// HMAC-SHA256 signing key. At least 64 characters — HS256 needs 256 bits
    /// of key material and a short key silently weakens every token issued.
    /// </summary>
    [Required(ErrorMessage = "Jwt:Key is not configured. Set it with: dotnet user-secrets set \"Jwt:Key\" \"<64+ chars>\"")]
    [MinLength(64, ErrorMessage = "Jwt:Key must be at least 64 characters.")]
    public string Key { get; set; } = string.Empty;

    [Required]
    public string Issuer { get; set; } = string.Empty;

    [Required]
    public string Audience { get; set; } = string.Empty;

    [Range(1, 1440)]
    public int AccessTokenMinutes { get; set; } = AppConstants.Tokens.AccessTokenMinutes;

    [Range(1, 90)]
    public int RefreshTokenDays { get; set; } = AppConstants.Tokens.RefreshTokenDays;

    /// <summary>
    /// Allowed clock drift between the issuing and validating servers.
    /// Deliberately small; the .NET default of five minutes is far more than
    /// two machines in the same deployment need.
    /// </summary>
    [Range(0, 300)]
    public int ClockSkewSeconds { get; set; } = 30;
}
