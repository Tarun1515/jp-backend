using System.Globalization;
using System.Text.Json;
using System.Threading.RateLimiting;
using JP.Core.Common;
using JP.Core.Constants;
using Microsoft.AspNetCore.RateLimiting;

namespace JP.App.Api.RateLimiting;

/*==============================================================================
  Rate limiting for the PUBLIC endpoints. Phase 7A.

  ----------------------------------------------------------------------------
  🔴 WHY THIS API HAS A RATE LIMITER AT ALL, NOW
  ----------------------------------------------------------------------------
  Every endpoint on JP.App.Api until this phase required a token, and a token is
  itself a rate limit: an attacker has to get an account first, and the account
  is revocable. 7A adds the first UNAUTHENTICATED endpoints over business data,
  so the only thing between a scraper and the job table is this file.

  ----------------------------------------------------------------------------
  THE SAME CHAINED SHAPE AS 2.35, AND THE SAME REASON
  ----------------------------------------------------------------------------
  A named policy resolves to ONE partition. The public surface needs two
  independent limits at once:

      60 / minute per IP   on the search      — a human browsing is nowhere
                                                near this; a scraper paging
                                                through results passes it fast
       3 / hour  per IP    on the contact form — a person writes to us once

  PartitionedRateLimiter.CreateChained applies both and rejects if EITHER is
  exhausted. Each limiter returns NoLimiter for paths it does not care about,
  so the authenticated endpoints on this API are untouched.

  ⚠️ Numbers live in the RateLimits:Public config section (2.7). The defaults in
  code match, so behaviour is unchanged when the section is absent.

  ----------------------------------------------------------------------------
  🔴 A SECOND COPY OF THE REJECTION WRITER, AND WHY THAT IS THE LESSER EVIL
  ----------------------------------------------------------------------------
  JP.Sso.Api has an identical RateLimitRejection. Sharing it would mean putting
  it in JP.Core — and JP.Core's own csproj says it "deliberately references
  NOTHING: no other project, no NuGet package", while this needs
  OnRejectedContext from ASP.NET Core.

  So the choice was: break the innermost layer's one rule to share twenty-five
  lines, or duplicate them. Duplicated — and the duplication is NAMED here so
  that a change to either is a prompt to look at the other. G27's lesson is
  about silent copies, not acknowledged ones.

  ⚠️ What is NOT duplicated is the message or the code: both come from
  ApiResponse and ErrorCodes in JP.Core, so the two APIs cannot drift on what a
  429 actually says.
==============================================================================*/

internal static class PublicRateLimiting
{
    /*
      Exact paths, lowercased. A StartsWith would also catch a future
      /api/public-admin and silently rate-limit it, and a regex over every
      request is a cost paid by the authenticated traffic too.
    */
    private const string JobSearchPath = "/api/public/jobs";
    private const string FiltersPath = "/api/public/jobs/filters";
    private const string ContactPath = "/api/public/contact";

    internal static PartitionedRateLimiter<HttpContext> CreateChained(PublicRateLimitOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);

        return PartitionedRateLimiter.CreateChained(
            ReadsPerIp(options.PublicReadsPerIp),
            ContactPerIp(options.ContactPerIp));
    }

    /// <summary>
    /// Every public READ, per IP.
    /// </summary>
    /// <remarks>
    /// ⚠️ ONE BUDGET ACROSS THE READS, not one each. A scraper alternating
    /// between the listing and the detail would otherwise get both budgets, and
    /// what needs limiting is "how much of our catalogue can one address pull",
    /// which is the sum.
    ///
    /// ⚠️ The job DETAIL path is matched by prefix because it carries a uid.
    /// That is the one place a prefix is correct: everything under
    /// /api/public/jobs/ is a public read by construction.
    /// </remarks>
    private static PartitionedRateLimiter<HttpContext> ReadsPerIp(RateLimitWindow window) =>
        PartitionedRateLimiter.Create<HttpContext, string>(context =>
        {
            var path = context.Request.Path.Value?.ToLowerInvariant() ?? string.Empty;

            var isPublicRead =
                path.Equals(JobSearchPath, StringComparison.Ordinal)
                || path.Equals(FiltersPath, StringComparison.Ordinal)
                || path.StartsWith(JobSearchPath + "/", StringComparison.Ordinal)
                || path.Equals("/api/public/faqs", StringComparison.Ordinal)
                || path.Equals("/api/public/content-blocks", StringComparison.Ordinal);

            return !isPublicRead
                ? RateLimitPartition.GetNoLimiter("none")
                : RateLimitPartition.GetFixedWindowLimiter(
                    $"public-read:{ClientIp(context)}",
                    _ => Options(window));
        });

    /// <summary>
    /// The contact form, per IP — tight, because a person writes to us once.
    /// </summary>
    private static PartitionedRateLimiter<HttpContext> ContactPerIp(RateLimitWindow window) =>
        PartitionedRateLimiter.Create<HttpContext, string>(context =>
            !context.Request.Path.Value?.Equals(ContactPath, StringComparison.OrdinalIgnoreCase) ?? true
                ? RateLimitPartition.GetNoLimiter("none")
                : RateLimitPartition.GetFixedWindowLimiter(
                    $"public-contact:{ClientIp(context)}",
                    _ => Options(window)));

    private static FixedWindowRateLimiterOptions Options(RateLimitWindow window) => new()
    {
        PermitLimit = window.PermitLimit,
        Window = TimeSpan.FromSeconds(window.WindowSeconds),

        /*
          ⚠️ No queue. A queued public request is a request held open on a
          thread while a scraper waits — which is the resource the limit exists
          to protect. Rejecting immediately is the point.
        */
        QueueLimit = 0,
        QueueProcessingOrder = QueueProcessingOrder.OldestFirst,
    };

    /// <summary>
    /// 🔴 The client address, and behind a proxy this is the PROXY's.
    /// </summary>
    /// <remarks>
    /// ⚠️ X-Forwarded-For is deliberately NOT read here. A header a client can
    /// set is a rate limit a client can reset — every request with a fresh
    /// fake value would get a fresh budget. Honouring it requires
    /// ForwardedHeadersOptions with a KnownProxies list, which is a deployment
    /// decision this project has not made yet; until it does, the honest
    /// behaviour is to limit what we can actually see.
    ///
    /// The cost is stated plainly: behind a single reverse proxy, every visitor
    /// shares one bucket. 2.35 already records the sibling caveat that windows
    /// are per process.
    /// </remarks>
    private static string ClientIp(HttpContext context) =>
        context.Connection.RemoteIpAddress?.ToString() ?? "unknown";
}

/// <summary>
/// The public limits, from the <c>RateLimits:Public</c> configuration section.
/// </summary>
internal sealed class PublicRateLimitOptions
{
    public const string SectionName = "RateLimits:Public";

    /// <summary>
    /// All public reads together, per IP. 60/minute is far above a human
    /// browsing and well below a useful scrape rate.
    /// </summary>
    public RateLimitWindow PublicReadsPerIp { get; set; } = new() { PermitLimit = 60, WindowSeconds = 60 };

    /// <summary>The contact form, per IP. A person writes once.</summary>
    public RateLimitWindow ContactPerIp { get; set; } = new() { PermitLimit = 3, WindowSeconds = 3600 };
}

/// <summary>One fixed window. Mirrors the SSO API's type of the same name.</summary>
internal sealed class RateLimitWindow
{
    public int PermitLimit { get; set; } = 60;

    public int WindowSeconds { get; set; } = 60;
}

/// <summary>
/// Writes the 429 body. A second copy of the SSO API's writer — see this file's
/// header for why JP.Core cannot hold it.
/// </summary>
internal static class PublicRateLimitRejection
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    internal static async ValueTask WriteAsync(
        OnRejectedContext context, CancellationToken cancellationToken)
    {
        context.HttpContext.Response.StatusCode = StatusCodes.Status429TooManyRequests;
        context.HttpContext.Response.ContentType = "application/json; charset=utf-8";

        if (context.Lease.TryGetMetadata(MetadataName.RetryAfter, out var retryAfter))
        {
            context.HttpContext.Response.Headers.RetryAfter =
                ((int)retryAfter.TotalSeconds).ToString(CultureInfo.InvariantCulture);
        }

        /*
          🔒 THE BODY LEAKS NOTHING.

          Not which limit was hit, not how many requests remain, not whether the
          path exists. A 429 that says "job search limit" confirms the endpoint
          and hands a scraper the shape of the limit to pace against — and the
          brief's verification reads these bytes.
        */
        var body = ApiResponse.Failure(
            "Too many requests. Please wait a moment and try again.", ErrorCodes.RateLimited);

        await context.HttpContext.Response
            .WriteAsync(JsonSerializer.Serialize(body, JsonOptions), cancellationToken)
            .ConfigureAwait(false);
    }
}
