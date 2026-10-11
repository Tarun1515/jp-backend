using System.Security.Claims;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Common;
using JP.Domain.Notifications;
using JP.Infrastructure.Repositories;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Services;

/// <summary>Notifications — the caller's own, and nobody else's. Phase 6C.</summary>
/// <remarks>
/// <para>
/// 🔒 EVERY METHOD TAKES THE CALLER AND READS THE UID FROM THEIR TOKEN through
/// <c>GetUserUid()</c> — the same reader every other service uses, so a token
/// with no uid gives the same 401 here as anywhere else.
/// There is no overload that accepts a user id, which means there is no way for
/// a controller to pass somebody else's — not by mistake, and not by a later
/// well-meaning "admin view" feature. 030 removed the column that would make a
/// cross-user query expressible at all.
/// </para>
/// <para>
/// ⚠️ No permission check anywhere here, and that is correct rather than
/// missing. A notification is addressed to a person, not granted by a role; a
/// school VIEWER reads their own notifications exactly as the owner reads
/// theirs. The scope IS the authorisation.
/// </para>
/// </remarks>
public interface INotificationService
{
    Task<PagedResult<NotificationDto>> GetMineAsync(
        ClaimsPrincipal caller, bool unreadOnly, int pageNumber, int pageSize,
        CancellationToken cancellationToken);

    Task<UnreadCountDto> GetUnreadCountAsync(ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<MarkReadResultDto> MarkReadAsync(
        ClaimsPrincipal caller, long notificationId, CancellationToken cancellationToken);

    Task<MarkReadResultDto> MarkAllReadAsync(ClaimsPrincipal caller, CancellationToken cancellationToken);
}

internal sealed class NotificationService : INotificationService
{
    private readonly INotificationRepository _notifications;
    private readonly ILogger<NotificationService> _logger;

    public NotificationService(
        INotificationRepository notifications,
        ILogger<NotificationService> logger)
    {
        _notifications = notifications;
        _logger = logger;
    }

    public async Task<PagedResult<NotificationDto>> GetMineAsync(
        ClaimsPrincipal caller, bool unreadOnly, int pageNumber, int pageSize,
        CancellationToken cancellationToken)
    {
        var userUid = caller.GetUserUid();

        /*
          ⚠️ Clamped here AND in the procedure. Belt and braces on purpose: the
          procedure is the one that cannot be bypassed, and this one makes the
          contract visible to anybody reading the service.
        */
        if (pageSize < 1) pageSize = 20;
        if (pageSize > 100) pageSize = 100;
        if (pageNumber < 1) pageNumber = 1;

        var (rows, total) = await _notifications
            .GetMineAsync(userUid, unreadOnly, pageNumber, pageSize, cancellationToken)
            .ConfigureAwait(false);

        return new PagedResult<NotificationDto>(rows, total, pageNumber, pageSize);
    }

    public async Task<UnreadCountDto> GetUnreadCountAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        var userUid = caller.GetUserUid();

        var count = await _notifications.GetUnreadCountAsync(userUid, cancellationToken)
            .ConfigureAwait(false);

        return new UnreadCountDto { UnreadCount = count };
    }

    public async Task<MarkReadResultDto> MarkReadAsync(
        ClaimsPrincipal caller, long notificationId, CancellationToken cancellationToken)
    {
        var userUid = caller.GetUserUid();

        var result = await _notifications.MarkReadAsync(userUid, notificationId, cancellationToken)
            .ConfigureAwait(false);

        if (result.Status != 1)
        {
            /*
              🔒 404, AND IT IS THE ONLY ANSWER SOMEBODY ELSE'S ID CAN GET.

              The procedure matches on recipient, so a notification belonging to
              another user resolves to nothing — identical to one that does not
              exist. A 403 here would confirm the row exists and that it is
              somebody else's, which is precisely what 2.6 forbids.
            */
            throw new NotFoundException(result.Message);
        }

        return new MarkReadResultDto { Affected = result.Id ?? 0 };
    }

    public async Task<MarkReadResultDto> MarkAllReadAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        var userUid = caller.GetUserUid();

        var result = await _notifications.MarkAllReadAsync(userUid, cancellationToken)
            .ConfigureAwait(false);

        /*
          ⚠️ Zero is a success. "Mark everything read" when nothing is unread has
          already achieved what was asked, and treating it as a failure would
          put an error on the one screen state where there was nothing to do.
        */
        return new MarkReadResultDto { Affected = result.Id ?? 0 };
    }
}
