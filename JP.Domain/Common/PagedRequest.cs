using JP.Core.Constants;

namespace JP.Domain.Common;

/// <summary>
/// Base for every list request. Inherit and add the filters a given list needs.
/// </summary>
/// <remarks>
/// Paging values self-clamp on assignment, so a caller sending
/// <c>pageSize=100000</c> gets <see cref="AppConstants.Paging.MaxPageSize"/>
/// rather than an error or a table scan.
/// </remarks>
public class PagedRequest
{
    private int _pageNumber = AppConstants.Paging.DefaultPageNumber;
    private int _pageSize = AppConstants.Paging.DefaultPageSize;

    /// <summary>One-based page number. Values below 1 clamp to 1.</summary>
    public int PageNumber
    {
        get => _pageNumber;
        set => _pageNumber = value < 1 ? AppConstants.Paging.DefaultPageNumber : value;
    }

    /// <summary>
    /// Rows per page, clamped to <see cref="AppConstants.Paging.MaxPageSize"/>.
    /// </summary>
    public int PageSize
    {
        get => _pageSize;
        set => _pageSize = value switch
        {
            < 1 => AppConstants.Paging.DefaultPageSize,
            > AppConstants.Paging.MaxPageSize => AppConstants.Paging.MaxPageSize,
            _ => value,
        };
    }

    /// <summary>Free-text search term. Interpretation is up to each stored procedure.</summary>
    public string? Search { get; set; }

    /// <summary>
    /// Column to sort by.
    /// </summary>
    /// <remarks>
    /// This value reaches a stored procedure as a parameter and must be
    /// resolved there through an explicit CASE whitelist. It must never be
    /// concatenated into dynamic SQL — that would be an injection point that
    /// no amount of Dapper parameterisation upstream can close.
    /// </remarks>
    public string? SortBy { get; set; }

    /// <summary><c>ASC</c> or <c>DESC</c>. Anything else is treated as ASC by the procedure.</summary>
    public string? SortDirection { get; set; }

    /// <summary>Rows to skip — what OFFSET/FETCH takes.</summary>
    public int Offset => (PageNumber - 1) * PageSize;
}
