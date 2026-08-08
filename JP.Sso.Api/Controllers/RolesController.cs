using JP.Core.Common;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Roles;
using JP.Infrastructure.Filters;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.Sso.Api.Controllers;

/// <summary>Roles available to the caller, and custom role creation.</summary>
[ApiController]
[Route("api/roles")]
[Authorize]
[RequireActiveAccount]
public sealed class RolesController : ControllerBase
{
    private readonly IRoleService _roles;

    public RolesController(IRoleService roles) => _roles = roles;

    /// <summary>
    /// The seeded global roles plus the caller organisation's own custom ones.
    /// </summary>
    [HttpGet]
    [ProducesResponseType(typeof(Response<IReadOnlyList<RoleResponse>>), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetRoles(CancellationToken cancellationToken)
    {
        var roles = await _roles.GetRolesAsync(User, cancellationToken);

        return Ok(ApiResponse.Success(roles));
    }

    /// <summary>
    /// Defines a custom role for the caller's organisation.
    /// </summary>
    /// <remarks>
    /// Permissions are chosen from the seeded catalogue; a school composes
    /// roles, it never invents a permission. USER.MANAGE is required, because
    /// creating a role is effectively deciding what colleagues can do.
    /// </remarks>
    [HttpPost]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> CreateRole(
        [FromBody] CreateRoleRequest request, CancellationToken cancellationToken)
    {
        if (!User.HasPermission("USER.MANAGE"))
        {
            throw new ForbiddenException("You do not have permission to manage roles.");
        }

        var roleId = await _roles.CreateSchoolRoleAsync(request, User, cancellationToken);

        return Ok(ApiResponse.Success(new { RoleId = roleId }, "Role created."));
    }
}

/// <summary>The permission catalogue, for the role editor.</summary>
[ApiController]
[Route("api/permissions")]
[Authorize]
[RequireActiveAccount]
public sealed class PermissionsController : ControllerBase
{
    private readonly IRoleService _roles;

    public PermissionsController(IRoleService roles) => _roles = roles;

    /// <summary>
    /// Every permission, grouped by module.
    /// </summary>
    /// <remarks>
    /// Static and identical for everyone — it is a catalogue of what CAN be
    /// granted, not of what the caller holds. What the caller holds is in
    /// their token, and in GET /api/auth/me.
    /// </remarks>
    [HttpGet]
    [ProducesResponseType(typeof(Response<IReadOnlyList<PermissionResponse>>), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetPermissions(CancellationToken cancellationToken)
    {
        var permissions = await _roles.GetPermissionsAsync(cancellationToken);

        return Ok(ApiResponse.Success(permissions));
    }
}
