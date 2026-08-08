using System.ComponentModel.DataAnnotations;
using System.Globalization;
using JP.Core.Constants;

namespace JP.Infrastructure.Security;

/// <summary>Auth behaviour, bound from the <c>Auth</c> section.</summary>
public sealed class AuthOptions
{
    public const string SectionName = "Auth";

    /// <summary>
    /// Base64 PBKDF2 hash used as a decoy when a login identifier matches no
    /// account, so the not-found path performs the same key derivation as the
    /// found path.
    /// </summary>
    /// <remarks>
    /// NOT a secret — it is a hash of a value nobody knows and no password can
    /// ever match it. Leaving it blank makes the application generate one at
    /// startup, which is the recommended setup: it then always uses the
    /// current iteration count automatically.
    /// </remarks>
    public string? DummyPasswordHashBase64 { get; set; }

    /// <summary>Base64 salt paired with <see cref="DummyPasswordHashBase64"/>.</summary>
    public string? DummyPasswordSaltBase64 { get; set; }

    [Range(1, 120)]
    public int OtpValidityMinutes { get; set; } = AppConstants.Otp.ValidityMinutes;

    [Range(5, 1440)]
    public int PasswordResetValidityMinutes { get; set; } = AppConstants.Tokens.PasswordResetMinutes;

    [Range(1, 90)]
    public int InviteValidityDays { get; set; } = AppConstants.Tokens.InviteValidityDays;

    /// <summary>
    /// Where each kind of user's emailed links should land.
    /// </summary>
    /// <remarks>
    /// One URL per app. There is no longer a single portal to point at: admin,
    /// school and teacher are separate deployments on separate hosts, and a
    /// reset link sent into the wrong one arrives at a login page that will
    /// never accept its token.
    ///
    /// Keyed by UserTypeId as a string ('1', '2', '3') because that is what the
    /// procedure returns and what configuration binds cleanly to. Resolved
    /// through <see cref="PortalBaseUrlFor"/>, never indexed directly.
    /// </remarks>
    [Required]
    public Dictionary<string, string> PortalBaseUrls { get; set; } = new()
    {
        ["1"] = "http://localhost:4200",
        ["2"] = "http://localhost:4300",
        ["3"] = "http://localhost:4400",
    };

    /// <summary>
    /// The app URL for a user type, falling back to the school portal.
    /// </summary>
    /// <remarks>
    /// The fallback is deliberate rather than a throw: an unknown user type
    /// means someone added one server-side without adding its URL here, and
    /// sending that person a link to the wrong app is a far better failure than
    /// silently sending them no email at all.
    /// </remarks>
    public string PortalBaseUrlFor(int? userTypeId) =>
        (userTypeId is not null && PortalBaseUrls.TryGetValue(
            userTypeId.Value.ToString(CultureInfo.InvariantCulture), out var url)
            ? url
            : PortalBaseUrls.GetValueOrDefault("2", "http://localhost:4300")).TrimEnd('/');
}
