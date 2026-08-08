using JP.Domain.Common;

namespace JP.Domain.Users;

/*==============================================================================
  User management contracts.

  Note what is ABSENT from InviteUserRequest: an organisation id. The tenant
  always comes from the caller's JWT (PROJECT_MEMORY 2.6). Accepting one here,
  even to validate it, would create a field an attacker would try to bend.
==============================================================================*/

/// <summary>POST /api/users/invite</summary>
public sealed class InviteUserRequest
{
    public string Email { get; set; } = string.Empty;
    public string? Mobile { get; set; }

    /// <summary>A school role code, e.g. <c>HR</c> or <c>SENIOR_HR</c>.</summary>
    public string RoleCode { get; set; } = string.Empty;
}

public sealed class InviteUserResponse
{
    public Guid UserUid { get; set; }
    public string Email { get; set; } = string.Empty;
    public DateTime InviteExpiresOnUtc { get; set; }
}

/// <summary>
/// GET /api/users query string.
/// </summary>
/// <remarks>
/// <c>OrganizationUid</c> is deliberately not a member. The list is scoped from
/// the caller's token: an admin sees everything, anyone else sees only their
/// own organisation.
/// </remarks>
public sealed class UserListRequest : PagedRequest
{
    public int? UserTypeId { get; set; }
    public int? StatusId { get; set; }

    /// <summary>IST calendar date. Converted to a UTC range by the procedure.</summary>
    public DateOnly? FromDate { get; set; }

    /// <summary>IST calendar date, inclusive.</summary>
    public DateOnly? ToDate { get; set; }
}

public sealed class UserListItemResponse
{
    public Guid UserUid { get; set; }
    public int UserTypeId { get; set; }
    public string UserTypeName { get; set; } = string.Empty;
    public int StatusId { get; set; }
    public string StatusCode { get; set; } = string.Empty;
    public string StatusName { get; set; } = string.Empty;
    public string Email { get; set; } = string.Empty;
    public string? Mobile { get; set; }
    public bool IsEmailVerified { get; set; }
    public bool IsMobileVerified { get; set; }
    public Guid? OrganizationUid { get; set; }
    public DateTime? LastLoginOnUtc { get; set; }
    public int FailedAttemptCount { get; set; }
    public DateTime CreatedOnUtc { get; set; }

    /// <summary>Must be echoed back on a status update, for optimistic concurrency.</summary>
    public int RowVersion { get; set; }
}

/// <summary>PUT /api/users/{uid}/status</summary>
public sealed class UpdateUserStatusRequest
{
    public int NewStatusId { get; set; }

    /// <summary>From the row being edited. A stale value is refused.</summary>
    public int RowVersion { get; set; }

    public string? Remarks { get; set; }
}

/// <summary>POST /api/users/{uid}/unlock</summary>
public sealed class UnlockUserRequest
{
    public string? Remarks { get; set; }
}
