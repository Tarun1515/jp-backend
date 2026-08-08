using JP.Core.Common;
using JP.Domain.Users;
using JP.Infrastructure.Filters;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.Sso.Api.Controllers;

/// <summary>
/// User administration and team management.
/// </summary>
/// <remarks>
/// <c>[RequireActiveAccount]</c> applies to the whole controller. Unlike the
/// auth endpoints, none of this is something a pending account has any business
/// doing — it cannot invite colleagues before it has been approved itself.
///
/// Every action here is org-scoped from the JWT. No route or body carries an
/// organisation id, so there is nothing for a caller to tamper with.
/// </remarks>
[ApiController]
[Route("api/users")]
[Authorize]
[RequireActiveAccount]
public sealed class UsersController : ControllerBase
{
    private readonly IUserService _users;

    public UsersController(IUserService users) => _users = users;

    private string? ClientIp => HttpContext.Connection.RemoteIpAddress?.ToString();

    private string? ClientUserAgent =>
        Request.Headers.UserAgent.ToString() is { Length: > 0 } ua ? ua[..Math.Min(ua.Length, 400)] : null;

    /// <summary>
    /// Invites a colleague into the caller's own organisation.
    /// </summary>
    /// <remarks>
    /// Requires USER.MANAGE, which in the seeded roles only SCHOOL_OWNER holds
    /// on the school side. A custom role granting USER.MANAGE would also pass,
    /// which is the point of checking the permission rather than the role name.
    /// </remarks>
    [HttpPost("invite")]
    [ProducesResponseType(typeof(Response<InviteUserResponse>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> Invite(
        [FromBody] InviteUserRequest request, CancellationToken cancellationToken)
    {
        RequirePermission("USER.MANAGE");

        var result = await _users.InviteAsync(request, User, ClientIp, ClientUserAgent, cancellationToken);

        return Ok(ApiResponse.Success(result, "Invitation sent."));
    }

    /// <summary>
    /// Lists users. Admins see everything; everyone else sees their own
    /// organisation only.
    /// </summary>
    [HttpGet]
    [ProducesResponseType(typeof(Response<IReadOnlyList<UserListItemResponse>>), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetList(
        [FromQuery] UserListRequest request, CancellationToken cancellationToken)
    {
        var page = await _users.GetListAsync(request, User, cancellationToken);

        return Ok(ApiResponse.Paged(page.Items, page.TotalRecords));
    }

    /// <summary>Approves, rejects, suspends or reactivates an account.</summary>
    [HttpPut("{uid:guid}/status")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status409Conflict)]
    public async Task<IActionResult> UpdateStatus(
        Guid uid, [FromBody] UpdateUserStatusRequest request, CancellationToken cancellationToken)
    {
        await _users.UpdateStatusAsync(uid, request, User, cancellationToken);

        return Ok(ApiResponse.Success("Account status updated."));
    }

    /// <summary>Lifts a lockout ahead of its automatic expiry.</summary>
    [HttpPost("{uid:guid}/unlock")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> Unlock(
        Guid uid, [FromBody] UnlockUserRequest request, CancellationToken cancellationToken)
    {
        await _users.UnlockAsync(uid, request, User, cancellationToken);

        return Ok(ApiResponse.Success("Account unlocked."));
    }

    /// <summary>
    /// Refuses the request unless the caller holds the permission.
    /// </summary>
    /// <remarks>
    /// Throws ForbiddenException, which the global handler renders as a 403
    /// carrying the FORBIDDEN code, so the client handles it the same way as
    /// every other refusal.
    /// </remarks>
    private void RequirePermission(string permissionCode)
    {
        if (!JP.Core.Extensions.ClaimsPrincipalExtensions.HasPermission(User, permissionCode))
        {
            throw new JP.Core.Exceptions.ForbiddenException(
                "You do not have permission to perform this action.");
        }
    }
}
