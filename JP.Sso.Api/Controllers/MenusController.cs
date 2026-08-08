using JP.Core.Common;
using JP.Domain.Menus;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.Sso.Api.Controllers;

/// <summary>
/// The signed-in user's navigation.
/// </summary>
/// <remarks>
/// Deliberately NOT behind <c>[RequireActiveAccount]</c>. A pending school has
/// to reach its status and document screens, and those are menu rows too — the
/// procedure returns only what that user may see, so a pending account simply
/// gets a very short list (2.9).
/// </remarks>
[ApiController]
[Route("api/menus")]
[Authorize]
public sealed class MenusController : ControllerBase
{
    private readonly IMenuService _menus;

    public MenusController(IMenuService menus) => _menus = menus;

    /// <summary>Returns a flat menu list; the client builds the tree.</summary>
    /// <remarks>
    /// <c>no-store</c>, not merely <c>no-cache</c>. Menus change the instant a
    /// role is granted or revoked, and a cached menu offering a link the server
    /// will answer with 403 is worse than a slow one. <c>no-store</c> also
    /// keeps a per-user response out of any shared proxy.
    /// </remarks>
    [HttpGet]
    [ProducesResponseType(typeof(Response<IReadOnlyList<MenuResponse>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status401Unauthorized)]
    public async Task<IActionResult> GetMyMenus(CancellationToken cancellationToken)
    {
        var menus = await _menus.GetCurrentUserMenusAsync(User, cancellationToken);

        Response.Headers.CacheControl = "no-store, no-cache, must-revalidate";
        Response.Headers.Pragma = "no-cache";

        return Ok(ApiResponse.Success(menus));
    }
}
