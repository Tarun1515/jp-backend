namespace JP.Domain.Roles;

/// <summary>GET /api/roles</summary>
public sealed class RoleResponse
{
    public int RoleId { get; set; }
    public string RoleCode { get; set; } = string.Empty;
    public string RoleName { get; set; } = string.Empty;
    public int UserTypeId { get; set; }
    public string UserTypeName { get; set; } = string.Empty;

    /// <summary>Seeded roles cannot be renamed or deleted by a school.</summary>
    public bool IsSystemRole { get; set; }

    /// <summary>Null for a global role; set for a school's own custom role.</summary>
    public Guid? OrganizationUid { get; set; }

    public bool IsActive { get; set; }
    public int PermissionCount { get; set; }
}

/// <summary>
/// POST /api/roles — a school defines a custom role.
/// </summary>
/// <remarks>
/// No organisation id: the role is created for the caller's own organisation,
/// taken from the token.
/// </remarks>
public sealed class CreateRoleRequest
{
    public string RoleCode { get; set; } = string.Empty;
    public string RoleName { get; set; } = string.Empty;

    /// <summary>
    /// Permission codes to grant. Only codes from the seeded catalogue are
    /// accepted — a school composes roles out of existing permissions, it never
    /// invents one, because a permission code has to match a check that exists
    /// in the code.
    /// </summary>
    public IReadOnlyList<string> PermissionCodes { get; set; } = [];
}

/// <summary>GET /api/permissions</summary>
public sealed class PermissionResponse
{
    public int PermissionId { get; set; }
    public string PermissionCode { get; set; } = string.Empty;
    public string PermissionName { get; set; } = string.Empty;
    public int ModuleId { get; set; }
    public string ModuleCode { get; set; } = string.Empty;
    public string ModuleName { get; set; } = string.Empty;
}
