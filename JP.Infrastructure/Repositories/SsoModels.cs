using JP.Core.Enums;

namespace JP.Infrastructure.Repositories;

/*==============================================================================
  Internal row shapes returned by the jp_sso procedures.

  EVERY TYPE IN THIS FILE IS `internal` — deliberately, and load-bearing.

  UserLoginRow and PasswordHistoryRow carry PasswordHash and PasswordSalt.
  Making them internal to JP.Infrastructure means JP.Sso.Api cannot reference
  them at all: not in a controller signature, not in an ActionResult, not by
  accident through an anonymous object. There is no serializer path to a
  password hash because there is no path to the TYPE.

  That is a compile-time guarantee rather than a code-review convention, which
  is the only kind worth having for this.
==============================================================================*/

/// <summary>
/// The Status/Code/Message/Id envelope every write procedure returns
/// (PROJECT_MEMORY 2.21).
/// </summary>
internal class ProcResult
{
    /// <summary>1 = success, 0 = expected business failure.</summary>
    public int Status { get; set; }

    /// <summary>A JP.Core.Constants.ErrorCodes value. Null on success.</summary>
    public string? Code { get; set; }

    public string Message { get; set; } = string.Empty;

    public long? Id { get; set; }

    public bool Succeeded => Status == 1;
}

internal sealed class RegisterSchoolResult : ProcResult
{
    public Guid? UserUid { get; set; }
    public Guid? OrganizationUid { get; set; }
}

internal sealed class RegisterUserResult : ProcResult
{
    public Guid? UserUid { get; set; }
}

internal sealed class InviteUserResult : ProcResult
{
    public Guid? UserUid { get; set; }
    public long? TokenId { get; set; }
}

internal sealed class LoginAttemptResult : ProcResult
{
    public int FailedAttemptCount { get; set; }
    public bool IsLocked { get; set; }
    public DateTime? UnlockOn { get; set; }
}

internal sealed class RotateTokenResult : ProcResult
{
    /// <summary>
    /// True when an already-consumed token was replayed. The whole chain has
    /// been revoked. NEVER surfaced to the caller — the API answers a plain
    /// 401, because confirming that reuse was detected tells an attacker their
    /// stolen token was genuine.
    /// </summary>
    public bool ReuseDetected { get; set; }

    public int RevokedCount { get; set; }
}

internal sealed class RevokeResult : ProcResult
{
    public int RevokedCount { get; set; }
}

internal sealed class ChangePasswordResult : ProcResult
{
    public int RevokedTokenCount { get; set; }
}

internal sealed class ResetTokenResult : ProcResult
{
    /// <summary>
    /// Null when the address matched no account. The procedure still reports
    /// Status = 1 so the endpoint can answer identically either way.
    /// </summary>
    public long? UserId { get; set; }

    /// <summary>
    /// Which app's reset page the emailed link should point at. Null for an
    /// address with no account — alongside UserId, so the two cannot disagree.
    /// </summary>
    public int? UserTypeId { get; set; }
}

internal sealed class OtpVerifyResult : ProcResult
{
    public int? AttemptCount { get; set; }
    public int? AttemptsRemaining { get; set; }
}

internal sealed class UpdateStatusResult : ProcResult
{
    public int RevokedTokenCount { get; set; }
    public bool RoleGranted { get; set; }
}

internal sealed class UnlockResult : ProcResult
{
    public int LockoutsCleared { get; set; }
    public int? RestoredStatusId { get; set; }
}

/// <summary>
/// Everything USP_GetUserForLogin returns, hash material included.
/// </summary>
/// <remarks>
/// Never leaves this assembly. AuthService reads the hash, hands it to
/// IPasswordService, and maps only non-secret fields onto the response DTO.
/// </remarks>
internal sealed class UserLoginRow
{
    public long UserId { get; set; }
    public Guid UserUid { get; set; }
    public int UserTypeId { get; set; }
    public int StatusId { get; set; }
    public string Email { get; set; } = string.Empty;
    public string? Mobile { get; set; }
    public bool IsEmailVerified { get; set; }
    public bool IsMobileVerified { get; set; }
    public Guid? OrganizationUid { get; set; }
    public int FailedAttemptCount { get; set; }
    public DateTime? LastLoginOn { get; set; }
    public DateTime? LastPasswordChangeOn { get; set; }
    public int RowVersion { get; set; }

    // ---- credential ------------------------------------------------------
    public long? CredentialId { get; set; }

    /// <summary>Null for an invited user who has not yet set a password.</summary>
    public byte[]? PasswordHash { get; set; }

    public byte[]? PasswordSalt { get; set; }
    public int? HashAlgorithmId { get; set; }
    public int? Iterations { get; set; }
    public DateTime? CredentialExpiresOn { get; set; }

    // ---- lockout ---------------------------------------------------------
    public long? LockoutId { get; set; }
    public int? LockReasonId { get; set; }
    public DateTime? LockedOn { get; set; }
    public DateTime? UnlockOn { get; set; }
    public int? PreviousStatusId { get; set; }
    public bool IsLocked { get; set; }

    /// <summary>
    /// The status to act on. Resolves an expired lock back to what the account
    /// was beforehand, so a Pending school does not emerge from a lockout as
    /// Active. Always read THIS rather than <see cref="StatusId"/>.
    /// </summary>
    public int EffectiveStatusId { get; set; }

    public bool HasCredential => PasswordHash is { Length: > 0 } && PasswordSalt is { Length: > 0 };

    public PasswordHashAlgorithm Algorithm =>
        (PasswordHashAlgorithm)(HashAlgorithmId ?? (int)PasswordHashAlgorithm.Pbkdf2Sha256);
}

/// <summary>One historical credential, for the password-reuse check.</summary>
internal sealed class PasswordHistoryRow
{
    public long CredentialId { get; set; }
    public byte[] PasswordHash { get; set; } = [];
    public byte[] PasswordSalt { get; set; } = [];
    public int HashAlgorithmId { get; set; }
    public int Iterations { get; set; }
    public bool IsCurrent { get; set; }
    public DateTime CreatedOn { get; set; }

    public PasswordHashAlgorithm Algorithm => (PasswordHashAlgorithm)HashAlgorithmId;
}

/// <summary>USP_ValidateRefreshToken / USP_ValidatePasswordResetToken.</summary>
internal sealed class TokenValidationRow
{
    public long TokenId { get; set; }
    public long UserId { get; set; }
    public DateTime ExpiresOn { get; set; }
    public DateTime? UsedOn { get; set; }
    public DateTime? RevokedOn { get; set; }
    public long? ReplacedByTokenId { get; set; }
    public Guid UserUid { get; set; }
    public string? Email { get; set; }
    public int StatusId { get; set; }
    public int UserTypeId { get; set; }
    public Guid? OrganizationUid { get; set; }
    public bool IsValid { get; set; }
    public bool IsReuseAttempt { get; set; }
}

/// <summary>USP_GetUserByUid, first result set.</summary>
internal sealed class UserProfileRow
{
    public long UserId { get; set; }
    public Guid UserUid { get; set; }
    public int UserTypeId { get; set; }
    public string UserTypeCode { get; set; } = string.Empty;
    public int StatusId { get; set; }
    public string StatusCode { get; set; } = string.Empty;
    public string StatusName { get; set; } = string.Empty;
    public string Email { get; set; } = string.Empty;
    public string? Mobile { get; set; }
    public bool IsEmailVerified { get; set; }
    public bool IsMobileVerified { get; set; }
    public Guid? OrganizationUid { get; set; }
    public DateTime? LastLoginOn { get; set; }
    public DateTime? LastPasswordChangeOn { get; set; }
    public DateTime CreatedOn { get; set; }
    public int RowVersion { get; set; }
}

/// <summary>Roles and permissions, as they go into the JWT.</summary>
internal sealed class UserClaimSet
{
    public IReadOnlyList<string> Roles { get; init; } = [];
    public IReadOnlyList<string> Permissions { get; init; } = [];
}

/// <summary>
/// USP_GetUserList, first result set.
/// </summary>
/// <remarks>
/// Kept separate from the public UserListItemResponse so the API contract is
/// not pinned to database column names. The DTO says LastLoginOnUtc because
/// that tells a client what the value means; the column says LastLoginOn.
/// Renaming one must not force the other.
/// </remarks>
internal sealed class UserListRow
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
    public DateTime? LastLoginOn { get; set; }
    public int FailedAttemptCount { get; set; }
    public DateTime CreatedOn { get; set; }
    public int RowVersion { get; set; }
}

internal sealed class RoleRow
{
    public int RoleId { get; set; }
    public string RoleCode { get; set; } = string.Empty;
    public string RoleName { get; set; } = string.Empty;
    public int UserTypeId { get; set; }
    public string UserTypeName { get; set; } = string.Empty;
    public bool IsSystemRole { get; set; }
    public Guid? OrganizationUid { get; set; }
    public byte Is_Active { get; set; }
    public int PermissionCount { get; set; }
}

internal sealed class PermissionRow
{
    public int PermissionId { get; set; }
    public string PermissionCode { get; set; } = string.Empty;
    public string PermissionName { get; set; } = string.Empty;
    public int ModuleId { get; set; }
    public string ModuleCode { get; set; } = string.Empty;
    public string ModuleName { get; set; } = string.Empty;
    public int ModuleDisplayOrder { get; set; }
    public int DisplayOrder { get; set; }
}

/// <summary>One row from USP_GetUserMenus.</summary>
/// <remarks>
/// Internal like every other row type here, though this one carries nothing
/// sensitive — the boundary is worth more as a rule with no exceptions than as
/// one applied case by case.
/// </remarks>
internal sealed class MenuRow
{
    public long MenuId { get; set; }
    public long? ParentMenuId { get; set; }
    public string MenuCode { get; set; } = string.Empty;
    public string MenuName { get; set; } = string.Empty;
    public string? RoutePath { get; set; }
    public string? IconName { get; set; }
    public string? PermissionCode { get; set; }
    public int DisplayOrder { get; set; }
    public bool IsMenuVisible { get; set; }
    public bool OpenInNewTab { get; set; }
}
