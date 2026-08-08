using System.Net;
using System.Text.Json;
using JP.Core.Common;
using JP.Core.Constants;
using JP.Core.Exceptions;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Middleware;

/// <summary>
/// Converts every unhandled exception into a <see cref="Response{T}"/>.
/// </summary>
/// <remarks>
/// The split that matters is between exceptions we threw on purpose and
/// everything else.
/// <para>
/// An <see cref="AppException"/> is a decision the application made — the
/// account is pending, the email is taken, the row was changed by someone
/// else. Its message is written for the user and is returned verbatim, and it
/// is logged at warning level because it is not a fault.
/// </para>
/// <para>
/// Anything else is a bug. It is logged in full with its stack trace, and the
/// client gets a fixed generic message. Exception text routinely contains
/// connection strings, file paths and procedure names, and none of that
/// belongs in a response body.
/// </para>
/// </remarks>
public sealed class GlobalExceptionHandlerMiddleware : IMiddleware
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    private readonly ILogger<GlobalExceptionHandlerMiddleware> _logger;
    private readonly IHostEnvironment _environment;

    public GlobalExceptionHandlerMiddleware(
        ILogger<GlobalExceptionHandlerMiddleware> logger,
        IHostEnvironment environment)
    {
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _environment = environment ?? throw new ArgumentNullException(nameof(environment));
    }

    public async Task InvokeAsync(HttpContext context, RequestDelegate next)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(next);

        try
        {
            await next(context).ConfigureAwait(false);
        }
        catch (OperationCanceledException) when (context.RequestAborted.IsCancellationRequested)
        {
            // The client hung up. Not an error, and there is nobody left to
            // send a response to.
            _logger.LogInformation("Request {Method} {Path} was cancelled by the client.",
                context.Request.Method, context.Request.Path);
        }
        catch (ValidationAppException ex)
        {
            await WriteAsync(context, HttpStatusCode.BadRequest,
                ApiResponse.ValidationFailure(ex.Errors, ex.Message)).ConfigureAwait(false);
        }
        catch (AppException ex)
        {
            _logger.LogWarning("{Code} on {Method} {Path}: {Message}",
                ex.Code, context.Request.Method, context.Request.Path, ex.Message);

            await WriteAsync(context, ex.StatusCode,
                ApiResponse.Failure(ex.Message, ex.Code)).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Unhandled exception on {Method} {Path}",
                context.Request.Method, context.Request.Path);

            // Detail only outside production, and even then only because a
            // developer is the one reading it.
            var message = _environment.IsDevelopment()
                ? $"{ex.GetType().Name}: {ex.Message}"
                : "Something went wrong. Please try again.";

            await WriteAsync(context, HttpStatusCode.InternalServerError,
                ApiResponse.Failure(message, ErrorCodes.InternalError)).ConfigureAwait(false);
        }
    }

    private static async Task WriteAsync<T>(HttpContext context, HttpStatusCode statusCode, Response<T> body)
    {
        if (context.Response.HasStarted)
        {
            // Headers are already on the wire; anything written now would
            // corrupt the response rather than replace it.
            return;
        }

        // Clear() drops every header set so far, including the correlation id.
        // That is the one header worth keeping on an error response — it is
        // what ties the user's screenshot to the stack trace in the log.
        var correlationId = context.Response
            .Headers[RequestResponseLoggingMiddleware.CorrelationIdHeader].ToString();

        context.Response.Clear();

        if (!string.IsNullOrEmpty(correlationId))
        {
            context.Response.Headers[RequestResponseLoggingMiddleware.CorrelationIdHeader] = correlationId;
        }

        context.Response.StatusCode = (int)statusCode;
        context.Response.ContentType = "application/json; charset=utf-8";

        await context.Response
            .WriteAsync(JsonSerializer.Serialize(body, JsonOptions), context.RequestAborted)
            .ConfigureAwait(false);
    }
}
