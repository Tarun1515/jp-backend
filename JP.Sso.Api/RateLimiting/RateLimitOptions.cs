using System.ComponentModel.DataAnnotations;

namespace JP.Sso.Api.RateLimiting;

/// <summary>
/// One fixed window: how many requests, over how long.
/// </summary>
public sealed class RateLimitWindow
{
    [Range(1, 10_000)]
    public int PermitLimit { get; set; } = 5;

    [Range(1, 86_400)]
    public int WindowSeconds { get; set; } = 60;

    internal TimeSpan Window => TimeSpan.FromSeconds(WindowSeconds);
}

/// <summary>
/// Auth rate limits, bound from the <c>RateLimits</c> section.
/// </summary>
/// <remarks>
/// <para>
/// The defaults below ARE the specified limits, so an installation with no
/// <c>RateLimits</c> section behaves exactly as required. Configuration exists
/// so an operator can tighten them under attack, or loosen them for a load
/// test, without a rebuild — not so they can be forgotten.
/// </para>
/// <para>
/// These windows are per process. Behind more than one instance each node
/// counts separately, so the effective limit multiplies by the instance count;
/// a distributed limiter is the fix, and is out of scope for Phase 1C.
/// </para>
/// </remarks>
public sealed class RateLimitOptions
{
    public const string SectionName = "RateLimits";

    /// <summary>Stops one machine hammering the login endpoint.</summary>
    [Required]
    public RateLimitWindow LoginPerIp { get; set; } = new() { PermitLimit = 5, WindowSeconds = 60 };

    /// <summary>
    /// Stops a botnet spreading attempts on ONE account across many addresses,
    /// which the per-IP limit cannot see.
    /// </summary>
    [Required]
    public RateLimitWindow LoginPerIdentifier { get; set; } = new() { PermitLimit = 10, WindowSeconds = 3600 };

    [Required]
    public RateLimitWindow ForgotPasswordPerEmail { get; set; } = new() { PermitLimit = 3, WindowSeconds = 3600 };

    [Required]
    public RateLimitWindow SendOtpPerUser { get; set; } = new() { PermitLimit = 3, WindowSeconds = 600 };
}
