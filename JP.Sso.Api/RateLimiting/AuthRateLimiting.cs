using System.Text.Json;
using System.Threading.RateLimiting;
using JP.Core.Common;
using JP.Core.Constants;
using Microsoft.AspNetCore.RateLimiting;

namespace JP.Sso.Api.RateLimiting;

/*==============================================================================
  Rate limiting for the authentication endpoints.

  ----------------------------------------------------------------------------
  WHY ONE CHAINED GLOBAL LIMITER RATHER THAN NAMED POLICIES
  ----------------------------------------------------------------------------
  Login needs TWO independent limits at once:

      5 per minute per IP          — stops one machine hammering the endpoint
      10 per hour per identifier   — stops a botnet spreading attempts on ONE
                                     account across many addresses

  A named policy resolves to a single partition, so it can express one limit or
  a limit on the COMBINATION (ip+identifier) — and the combination is exactly
  the wrong thing here, because a distributed attack has a different IP every
  time and would never fill a combined bucket.

  PartitionedRateLimiter.CreateChained applies several limiters to the same
  request and rejects if ANY of them is exhausted, which is the real
  requirement. Each limiter below returns NoLimiter for paths it does not care
  about, so ordinary traffic is untouched.
==============================================================================*/

internal static class AuthRateLimiting
{
    /// <summary>
    /// Where AuthRateLimitKeyMiddleware leaves the identifier it read from the
    /// request body. Reading the body in the partition function itself is not
    /// possible — the stream has not been buffered at that point.
    /// </summary>
    internal const string BodyKeyItem = "__jp_ratelimit_body_key";

    private const string LoginPath = "/api/auth/login";
    private const string ForgotPasswordPath = "/api/auth/forgot-password";
    private const string SendOtpPath = "/api/auth/send-otp";

    internal static PartitionedRateLimiter<HttpContext> CreateChained(RateLimitOptions options)
    {
        ArgumentNullException.ThrowIfNull(options);

        return PartitionedRateLimiter.CreateChained(
            LoginPerIp(options.LoginPerIp),
            LoginPerIdentifier(options.LoginPerIdentifier),
            ForgotPasswordPerEmail(options.ForgotPasswordPerEmail),
            SendOtpPerUser(options.SendOtpPerUser));
    }

    /// <summary>Per IP. Stops one machine hammering the endpoint.</summary>
    private static PartitionedRateLimiter<HttpContext> LoginPerIp(RateLimitWindow window) =>
        PartitionedRateLimiter.Create<HttpContext, string>(context =>
            !IsPath(context, LoginPath)
                ? RateLimitPartition.GetNoLimiter("none")
                : RateLimitPartition.GetFixedWindowLimiter(
                    $"login-ip:{ClientIp(context)}",
                    _ => Options(window)));

    /// <summary>
    /// Per login identifier.
    /// </summary>
    /// <remarks>
    /// The identifier is lowercased so a.b@x.com and A.B@X.COM share one
    /// bucket — otherwise changing the case of a letter would reset the count.
    /// </remarks>
    private static PartitionedRateLimiter<HttpContext> LoginPerIdentifier(RateLimitWindow window) =>
        PartitionedRateLimiter.Create<HttpContext, string>(context =>
        {
            if (!IsPath(context, LoginPath))
            {
                return RateLimitPartition.GetNoLimiter("none");
            }

            var identifier = BodyKey(context);

            // No identifier in the body means the request will fail validation
            // anyway; the per-IP limiter still covers it.
            return string.IsNullOrEmpty(identifier)
                ? RateLimitPartition.GetNoLimiter("none")
                : RateLimitPartition.GetFixedWindowLimiter(
                    $"login-id:{identifier}",
                    _ => Options(window));
        });

    /// <summary>Per email address.</summary>
    private static PartitionedRateLimiter<HttpContext> ForgotPasswordPerEmail(RateLimitWindow window) =>
        PartitionedRateLimiter.Create<HttpContext, string>(context =>
        {
            if (!IsPath(context, ForgotPasswordPath))
            {
                return RateLimitPartition.GetNoLimiter("none");
            }

            var email = BodyKey(context);

            // Falls back to the IP so an empty body cannot bypass the limit.
            var key = string.IsNullOrEmpty(email) ? $"ip:{ClientIp(context)}" : email;

            return RateLimitPartition.GetFixedWindowLimiter($"forgot:{key}", _ => Options(window));
        });

    /// <summary>
    /// Per user.
    /// </summary>
    /// <remarks>
    /// This endpoint is authenticated, so the partition key comes from the
    /// token rather than the body — nothing to read, nothing to spoof.
    /// </remarks>
    private static PartitionedRateLimiter<HttpContext> SendOtpPerUser(RateLimitWindow window) =>
        PartitionedRateLimiter.Create<HttpContext, string>(context =>
        {
            if (!IsPath(context, SendOtpPath))
            {
                return RateLimitPartition.GetNoLimiter("none");
            }

            var userUid = context.User.FindFirst(JpClaimTypes.UserUid)?.Value;

            return string.IsNullOrEmpty(userUid)
                ? RateLimitPartition.GetNoLimiter("none")
                : RateLimitPartition.GetFixedWindowLimiter($"otp:{userUid}", _ => Options(window));
        });

    // QueueLimit 0 throughout: a caller who is over the limit is told so
    // immediately. Queueing would hold the connection open and hand an attacker
    // a way to exhaust the server's sockets with requests it already refused.
    private static FixedWindowRateLimiterOptions Options(RateLimitWindow window) => new()
    {
        PermitLimit = window.PermitLimit,
        Window = window.Window,
        QueueLimit = 0,
    };

    private static bool IsPath(HttpContext context, string path) =>
        HttpMethods.IsPost(context.Request.Method)
        && context.Request.Path.StartsWithSegments(path, StringComparison.OrdinalIgnoreCase);

    private static string ClientIp(HttpContext context) =>
        context.Connection.RemoteIpAddress?.ToString() ?? "unknown";

    private static string BodyKey(HttpContext context) =>
        context.Items.TryGetValue(BodyKeyItem, out var value) && value is string s ? s : string.Empty;
}

/// <summary>
/// Lifts the rate-limit partition key out of the request body.
/// </summary>
/// <remarks>
/// <para>
/// Rate limiting runs before model binding, so the login identifier and the
/// forgot-password address are not available as parsed objects yet — and the
/// request stream can only be read once. This buffers the body, reads the one
/// field needed, rewinds, and leaves the value in HttpContext.Items.
/// </para>
/// <para>
/// Applies to exactly two paths, and caps the read at 8 KB. Buffering every
/// request would put a copy of every payload in memory for no reason.
/// </para>
/// </remarks>
internal sealed class AuthRateLimitKeyMiddleware : IMiddleware
{
    private const int MaxBodyBytes = 8 * 1024;

    private static readonly string[] WatchedPaths =
    [
        "/api/auth/login",
        "/api/auth/forgot-password",
    ];

    private readonly ILogger<AuthRateLimitKeyMiddleware> _logger;

    public AuthRateLimitKeyMiddleware(ILogger<AuthRateLimitKeyMiddleware> logger) => _logger = logger;

    public async Task InvokeAsync(HttpContext context, RequestDelegate next)
    {
        if (HttpMethods.IsPost(context.Request.Method) && IsWatched(context.Request.Path))
        {
            await ExtractKeyAsync(context).ConfigureAwait(false);
        }

        await next(context).ConfigureAwait(false);
    }

    private static bool IsWatched(PathString path) =>
        WatchedPaths.Any(p => path.StartsWithSegments(p, StringComparison.OrdinalIgnoreCase));

    private async Task ExtractKeyAsync(HttpContext context)
    {
        try
        {
            context.Request.EnableBuffering();

            if (context.Request.ContentLength > MaxBodyBytes)
            {
                return;
            }

            var buffer = new byte[MaxBodyBytes];
            var read = await context.Request.Body.ReadAsync(buffer.AsMemory(), context.RequestAborted)
                .ConfigureAwait(false);

            // Rewind unconditionally — model binding reads this stream next.
            context.Request.Body.Position = 0;

            if (read == 0)
            {
                return;
            }

            using var document = JsonDocument.Parse(buffer.AsMemory(0, read));

            // Case-insensitive property lookup: the body is camelCase by
            // convention but nothing enforces that on the wire.
            var key = FindProperty(document.RootElement, "loginId")
                   ?? FindProperty(document.RootElement, "email");

            if (!string.IsNullOrWhiteSpace(key))
            {
                context.Items[AuthRateLimiting.BodyKeyItem] = key.Trim().ToLowerInvariant();
            }
        }
        catch (JsonException)
        {
            // Malformed JSON. Model binding will reject it; the per-IP limiter
            // still applies. Nothing is logged from the body itself.
            _logger.LogDebug("Could not read a rate-limit key from the request body on {Path}.",
                context.Request.Path);
        }
    }

    private static string? FindProperty(JsonElement root, string name)
    {
        if (root.ValueKind != JsonValueKind.Object)
        {
            return null;
        }

        foreach (var property in root.EnumerateObject())
        {
            if (property.NameEquals(name)
                || string.Equals(property.Name, name, StringComparison.OrdinalIgnoreCase))
            {
                return property.Value.ValueKind == JsonValueKind.String ? property.Value.GetString() : null;
            }
        }

        return null;
    }
}

/// <summary>Renders a rejected request in the standard Response envelope.</summary>
internal static class RateLimitRejection
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    internal static async ValueTask WriteAsync(OnRejectedContext context, CancellationToken cancellationToken)
    {
        context.HttpContext.Response.StatusCode = StatusCodes.Status429TooManyRequests;
        context.HttpContext.Response.ContentType = "application/json; charset=utf-8";

        // Retry-After when the limiter knows; a fixed window usually does.
        if (context.Lease.TryGetMetadata(MetadataName.RetryAfter, out var retryAfter))
        {
            context.HttpContext.Response.Headers.RetryAfter =
                ((int)retryAfter.TotalSeconds).ToString(System.Globalization.CultureInfo.InvariantCulture);
        }

        var body = ApiResponse.Failure(
            "Too many attempts. Please wait a moment and try again.", ErrorCodes.RateLimited);

        await context.HttpContext.Response
            .WriteAsync(JsonSerializer.Serialize(body, JsonOptions), cancellationToken)
            .ConfigureAwait(false);
    }
}
