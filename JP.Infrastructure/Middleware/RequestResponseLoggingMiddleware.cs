using System.Diagnostics;
using JP.Core.Constants;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Middleware;

/// <summary>
/// Logs one structured line per request: method, path, status, duration and
/// who made it.
/// </summary>
/// <remarks>
/// <para>
/// Request and response BODIES are deliberately never logged. Every
/// authentication endpoint in this system takes a password, an OTP or a token
/// in its body, and a log sink is precisely where those survive long after
/// they should have expired. Nothing here can be reconfigured to start
/// capturing them.
/// </para>
/// <para>
/// Query strings are logged with sensitive parameter values replaced, since
/// reset links legitimately carry a token in the URL.
/// </para>
/// </remarks>
public sealed class RequestResponseLoggingMiddleware : IMiddleware
{
    /// <summary>Response header carrying the correlation id back to the caller.</summary>
    public const string CorrelationIdHeader = "X-Correlation-Id";

    private const string Redacted = "[redacted]";

    /// <summary>Query parameters whose values must never reach a log.</summary>
    private static readonly HashSet<string> SensitiveQueryKeys =
        new(StringComparer.OrdinalIgnoreCase)
        {
            "token", "refreshToken", "accessToken", "otp", "code",
            "password", "newPassword", "key", "secret", "apiKey",
        };

    private readonly ILogger<RequestResponseLoggingMiddleware> _logger;

    public RequestResponseLoggingMiddleware(ILogger<RequestResponseLoggingMiddleware> logger)
    {
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    public async Task InvokeAsync(HttpContext context, RequestDelegate next)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(next);

        var correlationId = ResolveCorrelationId(context);
        context.Response.Headers[CorrelationIdHeader] = correlationId;

        // Attaches to every log line written during this request, so a support
        // ticket quoting one id pulls up the whole story.
        using var scope = _logger.BeginScope(new Dictionary<string, object>
        {
            ["CorrelationId"] = correlationId,
        });

        var stopwatch = Stopwatch.StartNew();

        try
        {
            await next(context).ConfigureAwait(false);
        }
        finally
        {
            stopwatch.Stop();

            var statusCode = context.Response.StatusCode;

            // 5xx is ours, 4xx is usually the caller's, everything else is noise
            // at information level.
            var level = statusCode >= 500 ? LogLevel.Error
                : statusCode >= 400 ? LogLevel.Warning
                : LogLevel.Information;

            _logger.Log(level,
                "{Method} {Path}{Query} responded {StatusCode} in {ElapsedMs} ms for user {UserUid}",
                context.Request.Method,
                context.Request.Path.Value,
                RedactQueryString(context.Request.QueryString.Value),
                statusCode,
                stopwatch.ElapsedMilliseconds,
                context.User?.FindFirst(JpClaimTypes.UserUid)?.Value ?? "anonymous");
        }
    }

    /// <summary>
    /// Reuses an inbound correlation id when one is supplied, so a trace
    /// started in the Angular app carries through both APIs.
    /// </summary>
    private static string ResolveCorrelationId(HttpContext context)
    {
        var inbound = context.Request.Headers[CorrelationIdHeader].ToString();

        // Bounded before use: this value is attacker-controlled and ends up in
        // every log line for the request.
        if (!string.IsNullOrWhiteSpace(inbound) && inbound.Length <= 64)
        {
            return inbound;
        }

        return context.TraceIdentifier;
    }

    private static string RedactQueryString(string? queryString)
    {
        if (string.IsNullOrEmpty(queryString) || queryString == "?")
        {
            return string.Empty;
        }

        var pairs = queryString.TrimStart('?').Split('&', StringSplitOptions.RemoveEmptyEntries);
        var rebuilt = pairs.Select(pair =>
        {
            var separatorIndex = pair.IndexOf('=', StringComparison.Ordinal);
            if (separatorIndex <= 0)
            {
                return pair;
            }

            var key = pair[..separatorIndex];
            return SensitiveQueryKeys.Contains(key) ? $"{key}={Redacted}" : pair;
        });

        return $"?{string.Join('&', rebuilt)}";
    }
}
