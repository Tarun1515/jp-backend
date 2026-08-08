using System.Security.Claims;
using JP.Core.Enums;
using JP.Core.Extensions;
using JP.Domain.Roles;
using JP.Infrastructure.Repositories;

namespace JP.Infrastructure.Services;

public interface IRoleService
{
    Task<IReadOnlyList<RoleResponse>> GetRolesAsync(ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<int> CreateSchoolRoleAsync(CreateRoleRequest request, ClaimsPrincipal caller,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<PermissionResponse>> GetPermissionsAsync(CancellationToken cancellationToken);
}

internal sealed class RoleService : IRoleService
{
    private readonly IRoleRepository _roles;

    public RoleService(IRoleRepository roles) => _roles = roles;

    /// <summary>
    /// The roles available to the caller's organisation: the seeded global
    /// roles plus that organisation's own custom ones.
    /// </summary>
    /// <remarks>
    /// Scoped from the token. An admin passes null and sees the global set;
    /// there is no parameter through which one school could ask for another
    /// school's private roles.
    /// </remarks>
    public async Task<IReadOnlyList<RoleResponse>> GetRolesAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        var isAdmin = caller.GetUserType() == UserType.Admin;
        var organizationUid = isAdmin ? null : caller.GetOrganizationUid();

        var rows = await _roles.GetRoleListAsync(organizationUid, null, cancellationToken)
            .ConfigureAwait(false);

        return rows.Select(r => new RoleResponse
        {
            RoleId = r.RoleId,
            RoleCode = r.RoleCode,
            RoleName = r.RoleName,
            UserTypeId = r.UserTypeId,
            UserTypeName = r.UserTypeName,
            IsSystemRole = r.IsSystemRole,
            OrganizationUid = r.OrganizationUid,
            IsActive = r.Is_Active == 1,
            PermissionCount = r.PermissionCount,
        }).ToList();
    }

    public async Task<int> CreateSchoolRoleAsync(
        CreateRoleRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        var organizationUid = caller.RequireOrganizationUid();

        // The procedure splits this with STRING_SPLIT and refuses the whole
        // request if any code fails to resolve, so a typo cannot silently
        // produce a role that grants less than it appears to.
        var codes = string.Join(',', request.PermissionCodes
            .Select(c => c.Trim().ToUpperInvariant())
            .Where(c => c.Length > 0)
            .Distinct(StringComparer.Ordinal));

        var result = (await _roles.CreateSchoolRoleAsync(
            organizationUid, request.RoleCode, request.RoleName, codes, caller.GetUserId(),
            cancellationToken).ConfigureAwait(false)).EnsureSuccess();

        return (int)(result.Id ?? 0);
    }

    public async Task<IReadOnlyList<PermissionResponse>> GetPermissionsAsync(CancellationToken cancellationToken)
    {
        var rows = await _roles.GetPermissionListAsync(null, cancellationToken).ConfigureAwait(false);

        return rows.Select(p => new PermissionResponse
        {
            PermissionId = p.PermissionId,
            PermissionCode = p.PermissionCode,
            PermissionName = p.PermissionName,
            ModuleId = p.ModuleId,
            ModuleCode = p.ModuleCode,
            ModuleName = p.ModuleName,
        }).ToList();
    }
}
