using System.ComponentModel.DataAnnotations;

namespace JP.Infrastructure.Address;

/// <summary>
/// Which address-lookup provider is in use, bound from the
/// <c>AddressLookup</c> section.
/// </summary>
/// <remarks>
/// 🔴 THE API KEY IS NOT HERE, AND MUST NEVER BE. Like the SMTP password and
/// the SQL password, it is read from an environment variable
/// (<see cref="ApiKeyEnvironmentVariable"/>) or user-secrets, so nothing
/// secret is ever committed (2.16).
/// <para>
/// A key in appsettings.json is caught by security-pass.mjs section 9, which
/// audits every appsettings file by script rather than by eye — so putting it
/// there does not merely violate a rule, it fails the suite.
/// </para>
/// <para>
/// ⚠️ SHIPPED OFF. <see cref="Provider"/> defaults to <c>None</c>, which means
/// the manual cascade is the only path until somebody deliberately turns
/// Places on with a key. A product that silently depends on a third party the
/// first time it is deployed is a product that breaks on a machine without the
/// key, in a way nobody predicted.
/// </para>
/// </remarks>
public sealed class AddressLookupOptions
{
    public const string SectionName = "AddressLookup";

    /// <summary>Environment variable holding the Places API key.</summary>
    public const string ApiKeyEnvironmentVariable = "GOOGLE_PLACES_API_KEY";

    /// <summary>
    /// <c>None</c> (the default) or <c>Google</c>.
    /// </summary>
    /// <remarks>
    /// A string rather than an enum because it is configuration a deployer
    /// edits, and an unrecognised value must fail loudly at startup with the
    /// value in the message — not silently fall back to a default they did not
    /// choose.
    /// </remarks>
    [Required]
    public string Provider { get; set; } = ProviderNone;

    public const string ProviderNone = "None";
    public const string ProviderGoogle = "Google";

    /// <summary>
    /// Bias results towards India. Google accepts an ISO country code.
    /// </summary>
    public string CountryBias { get; set; } = "in";

    /// <summary>
    /// How long to wait on the provider before giving up, in seconds.
    /// </summary>
    /// <remarks>
    /// ⚠️ SHORT ON PURPOSE. This sits in front of somebody typing their
    /// address. A lookup that takes eight seconds is worse than one that fails
    /// in three and lets them use the dropdowns, because they are staring at a
    /// box that is doing nothing.
    /// </remarks>
    [Range(1, 30)]
    public int TimeoutSeconds { get; set; } = 3;

    /// <summary>True when a provider is configured AND a key is present.</summary>
    public bool IsEnabled =>
        string.Equals(Provider, ProviderGoogle, StringComparison.OrdinalIgnoreCase)
        && !string.IsNullOrWhiteSpace(Environment.GetEnvironmentVariable(ApiKeyEnvironmentVariable));
}
