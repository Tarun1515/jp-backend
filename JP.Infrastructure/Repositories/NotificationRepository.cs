using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Domain.Notifications;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

/// <summary>
/// A notification as the list procedure returns it, plus the window's total.
/// </summary>
/// <remarks>
/// 🔒 A standalone type rather than a subclass of <see cref="NotificationDto"/>.
/// 6B learned this the hard way with the search row: inheriting would leave
/// <c>TotalRecords</c> on the runtime type of every object handed to the
/// serialiser, and would stop the DTO being sealed. The mapping is explicit
/// below.
/// </remarks>
internal sealed class NotificationRow
{
    public long NotificationId { get; set; }
    public Guid NotificationUid { get; set; }
    public string TypeCode { get; set; } = string.Empty;
    public string TypeName { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string? Body { get; set; }
    public string? ActionUrl { get; set; }
    public byte? RefEntityTypeId { get; set; }
    public Guid? RefEntityUid { get; set; }
    public bool IsRead { get; set; }
    public DateTime? ReadOn { get; set; }
    public DateTime CreatedOn { get; set; }
    public long TotalRecords { get; set; }
}

/// <summary>One notification still owed an email, for the dispatcher.</summary>
internal sealed class PendingNotificationEmailRow
{
    public long NotificationId { get; set; }

    /// <summary>
    /// ⚠️ The uid, not an address. Users live in jp_sso and 2.2 forbids the
    /// join, so 021 cannot return a mailing list even if somebody wanted one.
    /// </summary>
    public Guid RecipientUserUid { get; set; }

    public string TypeCode { get; set; } = string.Empty;
    public string Title { get; set; } = string.Empty;
    public string? Body { get; set; }
    public DateTime CreatedOn { get; set; }
}

/// <summary>Notifications, over the jp_app procedures. Phase 6C.</summary>
internal interface INotificationRepository
{
    Task<(IReadOnlyList<NotificationDto> Rows, long Total)> GetMineAsync(
        Guid userUid, bool unreadOnly, int pageNumber, int pageSize, CancellationToken cancellationToken);

    Task<int> GetUnreadCountAsync(Guid userUid, CancellationToken cancellationToken);

    Task<ProcResult> MarkReadAsync(Guid userUid, long notificationId, CancellationToken cancellationToken);

    Task<ProcResult> MarkAllReadAsync(Guid userUid, CancellationToken cancellationToken);

    Task<IReadOnlyList<PendingNotificationEmailRow>> GetPendingEmailsAsync(
        int maxRows, CancellationToken cancellationToken);

    Task<ProcResult> MarkEmailSentAsync(long notificationId, CancellationToken cancellationToken);

    /// <summary>
    /// Creates one notification directly.
    /// </summary>
    /// <remarks>
    /// 🔴 THE ONLY CALLER IS VERIFICATION, AND IT IS THE ONLY EVENT THAT HAS TO
    /// WORK THIS WAY. Every other notification is written inside its event's own
    /// transaction by 021's notifiers, because the event and the notification
    /// share a database. A verification outcome is decided by the approval
    /// engine in <c>jp_mdm</c>, and 2.2 forbids that transaction reaching into
    /// jp_app — so this one is orchestrated afterwards, in the API, and 2.48's
    /// rule applies: the HTTP 200 means the approval succeeded, not that the
    /// notification did.
    /// </remarks>
    Task<long?> CreateAsync(
        Guid recipientUserUid, int notificationTypeId, string title, string? body,
        string? actionUrl, byte? refEntityTypeId, Guid? refEntityUid,
        CancellationToken cancellationToken);
}

internal sealed class NotificationRepository : BaseRepository, INotificationRepository
{
    public NotificationRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<NotificationRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.App;

    public async Task<(IReadOnlyList<NotificationDto> Rows, long Total)> GetMineAsync(
        Guid userUid, bool unreadOnly, int pageNumber, int pageSize, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@UnreadOnly", unreadOnly, DbType.Boolean);
        p.Add("@PageNumber", pageNumber, DbType.Int32);
        p.Add("@PageSize", pageSize, DbType.Int32);

        var rows = (await QueryAsync<NotificationRow>("USP_GetMyNotifications", p, cancellationToken)
            .ConfigureAwait(false)).AsList();

        /*
          ⚠️ The total rides on every row (COUNT(*) OVER()), so the count and the
          page describe the same result set. No rows means zero, which is the
          only honest reading of an empty page.
        */
        var total = rows.Count > 0 ? rows[0].TotalRecords : 0;

        var mapped = rows.Select(r => new NotificationDto
        {
            NotificationId = r.NotificationId,
            NotificationUid = r.NotificationUid,
            TypeCode = r.TypeCode,
            TypeName = r.TypeName,
            Title = r.Title,
            Body = r.Body,
            ActionUrl = r.ActionUrl,
            RefEntityTypeId = r.RefEntityTypeId,
            RefEntityUid = r.RefEntityUid,
            IsRead = r.IsRead,
            ReadOn = r.ReadOn,
            CreatedOn = r.CreatedOn,
        }).ToList();

        return (mapped, total);
    }

    public async Task<int> GetUnreadCountAsync(Guid userUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);

        var row = await QueryFirstOrDefaultAsync<UnreadCountDto>(
            "USP_GetUnreadNotificationCount", p, cancellationToken).ConfigureAwait(false);

        return row?.UnreadCount ?? 0;
    }

    public Task<ProcResult> MarkReadAsync(Guid userUid, long notificationId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@NotificationId", notificationId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_MarkNotificationRead", p, cancellationToken);
    }

    public Task<ProcResult> MarkAllReadAsync(Guid userUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);

        return QuerySingleAsync<ProcResult>("USP_MarkAllNotificationsRead", p, cancellationToken);
    }

    public async Task<IReadOnlyList<PendingNotificationEmailRow>> GetPendingEmailsAsync(
        int maxRows, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@MaxRows", maxRows, DbType.Int32);

        return (await QueryAsync<PendingNotificationEmailRow>(
            "USP_GetPendingNotificationEmails", p, cancellationToken).ConfigureAwait(false)).AsList();
    }

    public Task<ProcResult> MarkEmailSentAsync(long notificationId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@NotificationId", notificationId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_MarkNotificationEmailSent", p, cancellationToken);
    }

    public async Task<long?> CreateAsync(
        Guid recipientUserUid, int notificationTypeId, string title, string? body,
        string? actionUrl, byte? refEntityTypeId, Guid? refEntityUid,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@RecipientUserUid", recipientUserUid, DbType.Guid);
        p.Add("@NotificationTypeId", notificationTypeId, DbType.Int32);
        p.Add("@Title", title, DbType.String, size: 200);
        p.Add("@Body", body, DbType.String, size: 1000);
        p.Add("@ActionUrl", actionUrl, DbType.String, size: 300);
        p.Add("@RefEntityTypeId", refEntityTypeId, DbType.Byte);
        p.Add("@RefEntityUid", refEntityUid, DbType.Guid);

        /*
          🔴 AN OUTPUT PARAMETER, because 021's creators return no result set.
          Its header has the reason and it is worth knowing: a procedure EXEC'd
          from inside another emits its result sets to the client first, so a
          creator that ended with the usual Status/Code/Message/Id SELECT would
          have handed Dapper the NOTIFICATION's row instead of the event's — and
          nothing would have errored, because 2.21 made the shapes identical.
        */
        p.Add("@NotificationId", dbType: DbType.Int64, direction: ParameterDirection.Output);

        await ExecuteAsync("USP_CreateNotification", p, cancellationToken).ConfigureAwait(false);

        return p.Get<long?>("@NotificationId");
    }
}
