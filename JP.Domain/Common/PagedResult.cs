namespace JP.Domain.Common;

/// <summary>
/// One page of results plus the counts needed to render a pager.
/// </summary>
/// <remarks>
/// When this goes out through <c>Response.Paged</c>, <see cref="TotalRecords"/>
/// is also copied to the envelope's <c>totalRecords</c> field, which is where
/// existing clients read it from.
/// </remarks>
public sealed class PagedResult<T>
{
    public PagedResult()
    {
    }

    public PagedResult(IReadOnlyList<T> items, long totalRecords, int pageNumber, int pageSize)
    {
        Items = items;
        TotalRecords = totalRecords;
        PageNumber = pageNumber;
        PageSize = pageSize;
    }

    public IReadOnlyList<T> Items { get; set; } = [];

    /// <summary>Rows matching the filter across all pages, before paging.</summary>
    public long TotalRecords { get; set; }

    public int PageNumber { get; set; }

    public int PageSize { get; set; }

    public int TotalPages => PageSize <= 0 ? 0 : (int)Math.Ceiling(TotalRecords / (double)PageSize);

    public bool HasPrevious => PageNumber > 1;

    public bool HasNext => PageNumber < TotalPages;

    /// <summary>An empty page, for when a filter matches nothing.</summary>
    public static PagedResult<T> Empty(int pageNumber, int pageSize) =>
        new([], 0, pageNumber, pageSize);
}
