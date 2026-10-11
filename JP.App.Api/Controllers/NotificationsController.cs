using JP.Core.Common;
using JP.Domain.Notifications;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/// <summary>
/// The notification centre. Phase 6C.
/// </summary>
/// <remarks>
/// <para>
/// 🔒 SCOPE IS THE WHOLE DESIGN. Every route here reads the caller's uid from
/// their token and nothing else — there is no <c>?userUid=</c>, no admin
/// listing, and no route that takes a recipient. Somebody else's notification id
/// answers 404, never 403 (2.6): a 403 would confirm the row exists.
/// </para>
/// <para>
/// ⚠️ ONE CONTROLLER FOR EVERY AUDIENCE, deliberately. A teacher, a school owner
/// and a school viewer all read their own notifications through the same three
/// routes, because a notification belongs to a PERSON rather than to a role.
/// Splitting this into school and teacher controllers — which is how the rest of
/// the API is shaped — would have invited a permission attribute onto a thing
/// that permissions do not describe.
/// </para>
/// <para>
/// ⚠️ No <c>[RequirePermission]</c> anywhere, and its absence is the point. See
/// <see cref="INotificationService"/>: a notification is addressed to a person,
/// not granted by a role, so the scope IS the authorisation.
/// </para>
/// </remarks>
[ApiController]
[Route("api/notifications")]
[Authorize]
[Produces("application/json")]
public sealed class NotificationsController : ControllerBase
{
    private readonly INotificationService _notifications;

    public NotificationsController(INotificationService notifications)
        => _notifications = notifications;

    /// <summary>The caller's notifications, newest first.</summary>
    /// <remarks>
    /// ⚠️ Server-side paging from day one — G29's lesson, where an applicant
    /// list shipped with client-side paging under a 200-row cap and the cap was
    /// the only thing holding it up. A notification list is the one list in the
    /// product that only grows.
    /// </remarks>
    [HttpGet]
    [ProducesResponseType(typeof(Response<IReadOnlyList<NotificationDto>>), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetMine(
        [FromQuery] bool unreadOnly = false,
        [FromQuery] int pageNumber = 1,
        [FromQuery] int pageSize = 20,
        CancellationToken cancellationToken = default)
    {
        var page = await _notifications
            .GetMineAsync(User, unreadOnly, pageNumber, pageSize, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Paged(page.Items, page.TotalRecords));
    }

    /// <summary>What the bell shows.</summary>
    /// <remarks>
    /// Its own route rather than a field on the list, because every screen asks
    /// for this on every navigation and the list is the expensive half. 030
    /// gives it a filtered index for the same reason.
    /// </remarks>
    [HttpGet("unread-count")]
    [ProducesResponseType(typeof(Response<UnreadCountDto>), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetUnreadCount(CancellationToken cancellationToken)
    {
        var result = await _notifications.GetUnreadCountAsync(User, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(result));
    }

    /// <summary>Marks one notification read.</summary>
    /// <remarks>
    /// ⚠️ Marking an already-read one again is a SUCCESS, not a conflict. A list
    /// that marks rows read as they scroll past will send the same id twice and
    /// neither send is a mistake (2.48's shape). What earns a 404 is an id that
    /// is not the caller's.
    /// </remarks>
    [HttpPost("{notificationId:long}/read")]
    [ProducesResponseType(typeof(Response<MarkReadResultDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> MarkRead(long notificationId, CancellationToken cancellationToken)
    {
        var result = await _notifications.MarkReadAsync(User, notificationId, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(result, "Marked as read."));
    }

    /// <summary>Marks everything of the caller's read.</summary>
    [HttpPost("read-all")]
    [ProducesResponseType(typeof(Response<MarkReadResultDto>), StatusCodes.Status200OK)]
    public async Task<IActionResult> MarkAllRead(CancellationToken cancellationToken)
    {
        var result = await _notifications.MarkAllReadAsync(User, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(result, "All caught up."));
    }
}
