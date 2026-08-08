using System.Net;
using JP.Core.Constants;
using JP.Core.Exceptions;
using JP.Infrastructure.Repositories;

namespace JP.Infrastructure.Services;

/// <summary>
/// Turns a procedure's Status/Code/Message envelope into the right exception.
/// </summary>
/// <remarks>
/// The service layer's half of decision 2.21. A procedure reports an expected
/// failure as Status = 0 with an ErrorCodes value; this maps that onto an
/// <see cref="AppException"/>, and GlobalExceptionHandlerMiddleware turns THAT
/// into the Response envelope with the right HTTP status.
///
/// Because the procedure already returns a code, nothing here has to inspect
/// message text — which decision 2.12 forbids.
/// </remarks>
internal static class ProcResultExtensions
{
    /// <summary>Throws when the procedure reported a business failure.</summary>
    internal static T EnsureSuccess<T>(this T result)
        where T : ProcResult
    {
        ArgumentNullException.ThrowIfNull(result);

        if (result.Succeeded)
        {
            return result;
        }

        throw ToException(result.Code, result.Message);
    }

    internal static AppException ToException(string? code, string message)
    {
        if (string.IsNullOrWhiteSpace(message))
        {
            message = "That request could not be completed.";
        }

        return code switch
        {
            ErrorCodes.NotFound => new NotFoundException(message),
            ErrorCodes.Forbidden => new ForbiddenException(message),
            ErrorCodes.ConcurrencyConflict => new ConcurrencyConflictException(message),

            // Token problems are an authentication failure, not a bad request.
            ErrorCodes.TokenInvalid or ErrorCodes.TokenExpired or ErrorCodes.TokenRevoked
                or ErrorCodes.TokenAlreadyUsed or ErrorCodes.Unauthorized
                => new AppException(message, code, HttpStatusCode.Unauthorized),

            // Account-state codes are 403: authenticated, but not usable yet.
            ErrorCodes.AccountPending or ErrorCodes.AccountRejected or ErrorCodes.AccountSuspended
                or ErrorCodes.AccountLocked or ErrorCodes.AccountResubmitRequired
                or ErrorCodes.AccountInactive
                => new AppException(message, code, HttpStatusCode.Forbidden),

            ErrorCodes.RateLimited => new AppException(message, code, HttpStatusCode.TooManyRequests),

            // Duplicates and rule violations are 400 by default.
            _ => new BusinessRuleException(message, code ?? ErrorCodes.BusinessRuleViolated),
        };
    }
}
