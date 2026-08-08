using System.Security.Claims;
using JP.Core.Extensions;
using JP.Domain.Menus;
using JP.Infrastructure.Repositories;

namespace JP.Infrastructure.Services;

public interface IMenuService
{
    Task<IReadOnlyList<MenuResponse>> GetCurrentUserMenusAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken);
}

internal sealed class MenuService : IMenuService
{
    private readonly IMenuRepository _menus;

    public MenuService(IMenuRepository menus) => _menus = menus;

    /// <summary>
    /// The signed-in user's navigation.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The user id comes from the JWT claim and from nowhere else — there is
    /// no route parameter, no query string and no body on this endpoint, so
    /// there is nothing for an attacker to substitute (2.6).
    /// </para>
    /// <para>
    /// No caching layer here on purpose. A menu changes the moment a role is
    /// assigned or revoked, and a stale menu showing a link the server will
    /// refuse is a worse experience than one extra query per sign-in. The
    /// query is a single index seek over a few dozen rows.
    /// </para>
    /// </remarks>
    public async Task<IReadOnlyList<MenuResponse>> GetCurrentUserMenusAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        var rows = await _menus.GetUserMenusAsync(caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        return rows.Select(m => new MenuResponse
        {
            MenuId = m.MenuId,
            ParentMenuId = m.ParentMenuId,
            MenuCode = m.MenuCode,
            MenuName = m.MenuName,
            RoutePath = m.RoutePath,
            IconName = m.IconName,
            PermissionCode = m.PermissionCode,
            DisplayOrder = m.DisplayOrder,
            IsMenuVisible = m.IsMenuVisible,
            OpenInNewTab = m.OpenInNewTab,
        }).ToList();
    }
}
