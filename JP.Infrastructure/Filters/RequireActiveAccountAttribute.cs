using System.Net;
using JP.Core.Common;
using JP.Core.Constants;
using JP.Core.Enums;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;

namespace JP.Infrastructure.Filters;

/// <summary>
/// Blocks any endpoint unless the caller's account status is
/// <see cref="UserStatus.Active"/>.
/// </summary>
/// <remarks>
/// <para>
/// This is the approval gate, and it is enforced here rather than at login on
/// purpose. A school signs up as <see cref="UserStatus.PendingApproval"/> and
/// still needs to log in — to see where its verification stands and to upload
/// corrected documents. Refusing the login would leave it with no way to
/// finish the process it is waiting on.
/// </para>
/// <para>
/// So login succeeds, a real token is issued carrying the status claim, and
/// this filter is what keeps a pending account out of the business endpoints.
/// Apply it broadly; leave it off <c>/auth/*</c>, the registration-status
/// endpoint and document upload.
/// </para>
/// <para>
/// The status is read from the token, so it is as current as the token is. A
/// user approved seconds ago stays gated until their access token refreshes —
/// an acceptable trade for not querying the database on every single request.
/// </para>
/// </remarks>
[AttributeUsage(AttributeTargets.Class | AttributeTargets.Method, AllowMultiple = false)]
public sealed class RequireActiveAccountAttribute : Attribute, IAuthorizationFilter
{
    public void OnAuthorization(AuthorizationFilterContext context)
    {
        ArgumentNullException.ThrowIfNull(context);

        var user = context.HttpContext.User;

        if (user.Identity?.IsAuthenticated != true)
        {
            context.Result = Refuse(
                HttpStatusCode.Unauthorized,
                "You are not signed in.",
                ErrorCodes.Unauthorized);
            return;
        }

        var statusClaim = user.FindFirst(JpClaimTypes.Status)?.Value;

        if (!int.TryParse(statusClaim, out var statusValue) ||
            !Enum.IsDefined(typeof(UserStatus), statusValue))
        {
            context.Result = Refuse(
                HttpStatusCode.Unauthorized,
                "Your session is not valid. Please sign in again.",
                ErrorCodes.TokenInvalid);
            return;
        }

        var status = (UserStatus)statusValue;

        if (status == UserStatus.Active)
        {
            return;
        }

        var (message, code) = Describe(status);
        context.Result = Refuse(HttpStatusCode.Forbidden, message, code);
    }

    /// <summary>
    /// Maps a status to the message and code the client acts on. The Angular
    /// error interceptor routes on the code — <c>ACCOUNT_PENDING</c> goes to
    /// the pending screen rather than logging the user out.
    /// </summary>
    private static (string Message, string Code) Describe(UserStatus status) => status switch
    {
        UserStatus.PendingApproval => (
            "Your account is awaiting verification. You will be notified once it is approved.",
            ErrorCodes.AccountPending),

        UserStatus.Rejected => (
            "Your registration was not approved. Please contact support for details.",
            ErrorCodes.AccountRejected),

        UserStatus.Suspended => (
            "This account has been suspended. Please contact support.",
            ErrorCodes.AccountSuspended),

        UserStatus.Locked => (
            "This account is locked. Try again later or reset your password.",
            ErrorCodes.AccountLocked),

        UserStatus.ResubmitRequired => (
            "Some of your documents need to be resubmitted before your account can be activated.",
            ErrorCodes.AccountResubmitRequired),

        _ => (
            "This account is not active.",
            ErrorCodes.AccountInactive),
    };

    private static ObjectResult Refuse(HttpStatusCode statusCode, string message, string code) =>
        new(ApiResponse.Failure(message, code))
        {
            StatusCode = (int)statusCode,
        };
}
