namespace JP.Domain.Notifications;

/// <summary>
/// One notification, as the person it belongs to reads it. Phase 6C.
/// </summary>
/// <remarks>
/// <para>
/// 🔒 There is no recipient field. A caller only ever receives their OWN rows —
/// the procedure filters on the uid from the JWT (2.39) — so echoing the
/// recipient back would say nothing the caller did not already know, and would
/// put a user identifier on the wire for no reason.
/// </para>
/// <para>
/// ⚠️ <see cref="Title"/> and <see cref="Body"/> are the text as it was WRITTEN,
/// not composed on read. 030's header argues it: a notification is a record of
/// what somebody was told, and re-rendering it from live data would silently
/// rewrite history when a job is renamed.
/// </para>
/// <para>
/// 🔒 Nothing here is contact-shaped. A teacher's name may appear in a school's
/// notification — the browse profile returns names to any school — but no
/// email, mobile or resume path is ever stored in a notification, let alone
/// served in one. Contact goes through
/// <c>USP_GetTeacherContactForSchool</c> and nothing else (2.56).
/// </para>
/// </remarks>
public sealed record NotificationDto
{
    public long NotificationId { get; init; }

    public Guid NotificationUid { get; init; }

    /// <summary>The master's stable code — branch on this, never on the text (2.21).</summary>
    public string TypeCode { get; init; } = string.Empty;

    /// <summary>The master's editable display name (2.47).</summary>
    public string TypeName { get; init; } = string.Empty;

    public string Title { get; init; } = string.Empty;

    public string? Body { get; init; }

    /// <summary>
    /// A RELATIVE path inside the recipient's own app, or null.
    /// </summary>
    /// <remarks>
    /// ⚠️ Relative on purpose (030). G30's lesson was a button that did nothing;
    /// an absolute URL baked into a stored row is the slower version of the same
    /// bug — it works until the host changes.
    /// </remarks>
    public string? ActionUrl { get; init; }

    /// <summary>1 application · 2 invitation · 3 offer · 4 job.</summary>
    public byte? RefEntityTypeId { get; init; }

    public Guid? RefEntityUid { get; init; }

    public bool IsRead { get; init; }

    public DateTime? ReadOn { get; init; }

    public DateTime CreatedOn { get; init; }
}

/// <summary>What the bell shows. Phase 6C.</summary>
/// <remarks>
/// Its own endpoint rather than a count on the list, because every screen asks
/// for this on every navigation and the list is the expensive half. 030 gives
/// it a filtered index for the same reason.
/// </remarks>
public sealed record UnreadCountDto
{
    public int UnreadCount { get; init; }
}

/// <summary>
/// The result of marking things read.
/// </summary>
/// <remarks>
/// ⚠️ <see cref="Affected"/> can be zero on a success, and that is not a
/// contradiction: "mark all read" when nothing is unread has already achieved
/// what was asked. A client that treats zero as a failure will show an error
/// for the one case where there was nothing to do.
/// </remarks>
public sealed record MarkReadResultDto
{
    public long Affected { get; init; }
}
