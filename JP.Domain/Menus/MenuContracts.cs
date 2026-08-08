namespace JP.Domain.Menus;

/*==============================================================================
  Menu contracts.

  A FLAT list, exactly as the procedure returns it. The client nests it from
  ParentMenuId.

  Building the tree server-side was considered and rejected: the client has to
  walk the list anyway to render it, so a nested DTO means building the shape
  twice and shipping the parent's fields inside every child. A flat list also
  serialises to a smaller payload and diffs cleanly in a signal.
==============================================================================*/

/// <summary>One navigation entry.</summary>
public sealed class MenuResponse
{
    public long MenuId { get; set; }

    /// <summary>Null for a top-level entry. The client nests on this.</summary>
    public long? ParentMenuId { get; set; }

    /// <summary>Stable identifier. Code matches on this, never on MenuId.</summary>
    public string MenuCode { get; set; } = string.Empty;

    public string MenuName { get; set; } = string.Empty;

    /// <summary>
    /// Null for a group node — a heading with children rather than a link.
    /// </summary>
    public string? RoutePath { get; set; }

    public string? IconName { get; set; }

    /// <summary>
    /// The permission that gated this entry, or null if it needed none.
    /// </summary>
    /// <remarks>
    /// Returned for the client's benefit only — the server has ALREADY applied
    /// it, so this list contains nothing the caller may not see. It is here so
    /// the UI can explain why something is missing, not so the UI can filter.
    /// </remarks>
    public string? PermissionCode { get; set; }

    public int DisplayOrder { get; set; }

    /// <summary>
    /// False for routable-but-not-listed screens: detail pages, edit forms.
    /// </summary>
    /// <remarks>
    /// The client uses one list for two jobs — draw the sidebar from the
    /// visible rows, and check "may this route be opened at all" against every
    /// row. Filtering these out server-side would break the second job.
    /// </remarks>
    public bool IsMenuVisible { get; set; }

    public bool OpenInNewTab { get; set; }
}
