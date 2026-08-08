namespace JP.Domain.Auth;

/*==============================================================================
  Auth request and response contracts.

  These are the PUBLIC API surface. Nothing here may ever carry a password
  hash, a salt, or a token hash — the internal row that does carry those
  (UserLoginRow) is `internal` to JP.Infrastructure and cannot be referenced
  from an API project at all, so no serializer can reach it.

  Validation lives in JP.Sso.Api/Validators, not here: these are transport
  shapes, and the rules they must satisfy are an API concern.
==============================================================================*/

/// <summary>POST /api/auth/register/school</summary>
public sealed class RegisterSchoolRequest
{
    public string Email { get; set; } = string.Empty;
    public string? Mobile { get; set; }
    public string Password { get; set; } = string.Empty;
}

/// <summary>POST /api/auth/register/teacher</summary>
public sealed class RegisterTeacherRequest
{
    public string Email { get; set; } = string.Empty;
    public string? Mobile { get; set; }
    public string Password { get; set; } = string.Empty;
}

/// <summary>Returned by both registration endpoints.</summary>
public sealed class RegistrationResponse
{
    public Guid UserUid { get; set; }

    /// <summary>Null for teachers and admins, who belong to no organisation.</summary>
    public Guid? OrganizationUid { get; set; }

    /// <summary>1 = PendingApproval (school), 2 = Active (teacher).</summary>
    public int StatusId { get; set; }

    public string StatusCode { get; set; } = string.Empty;
}

/// <summary>
/// POST /api/auth/login.
/// </summary>
/// <remarks>
/// <c>LoginId</c> is an email or a mobile number; the server decides which by
/// looking for an '@'. One field rather than two, so the response cannot
/// differ by which was supplied.
/// </remarks>
public sealed class LoginRequest
{
    public string LoginId { get; set; } = string.Empty;
    public string Password { get; set; } = string.Empty;
}

/// <summary>Issued on successful sign-in and on refresh.</summary>
public sealed class AuthTokenResponse
{
    public string AccessToken { get; set; } = string.Empty;

    /// <summary>Opaque and random, not a JWT — a JWT could not be revoked.</summary>
    public string RefreshToken { get; set; } = string.Empty;

    public DateTime AccessTokenExpiresOnUtc { get; set; }
    public DateTime RefreshTokenExpiresOnUtc { get; set; }

    /// <summary>
    /// The account's status at issue time. A pending school receives a real
    /// token carrying status 1 — <c>[RequireActiveAccount]</c> is what blocks
    /// the business endpoints, not the absence of a token.
    /// </summary>
    public int StatusId { get; set; }

    public string StatusCode { get; set; } = string.Empty;
    public int UserTypeId { get; set; }
    public Guid UserUid { get; set; }
    public Guid? OrganizationUid { get; set; }
    public IReadOnlyList<string> Roles { get; set; } = [];
    public IReadOnlyList<string> Permissions { get; set; } = [];
}

/// <summary>POST /api/auth/refresh-token</summary>
public sealed class RefreshTokenRequest
{
    public string RefreshToken { get; set; } = string.Empty;
}

/// <summary>POST /api/auth/logout</summary>
public sealed class LogoutRequest
{
    public string? RefreshToken { get; set; }

    /// <summary>Revokes every session, not just this device.</summary>
    public bool AllDevices { get; set; }
}

/// <summary>POST /api/auth/forgot-password</summary>
public sealed class ForgotPasswordRequest
{
    public string Email { get; set; } = string.Empty;
}

/// <summary>POST /api/auth/reset-password</summary>
public sealed class ResetPasswordRequest
{
    /// <summary>The plaintext token from the emailed link. Only its hash is stored.</summary>
    public string Token { get; set; } = string.Empty;

    public string NewPassword { get; set; } = string.Empty;
}

/// <summary>POST /api/auth/change-password — authenticated.</summary>
public sealed class ChangePasswordRequest
{
    public string CurrentPassword { get; set; } = string.Empty;
    public string NewPassword { get; set; } = string.Empty;
}

/// <summary>POST /api/auth/set-password-from-invite</summary>
public sealed class SetPasswordFromInviteRequest
{
    public string Token { get; set; } = string.Empty;
    public string Password { get; set; } = string.Empty;
}

/// <summary>POST /api/auth/send-otp — authenticated.</summary>
public sealed class SendOtpRequest
{
    /// <summary>1 = Email, 2 = SMS.</summary>
    public int ChannelId { get; set; } = 1;
}

/// <summary>POST /api/auth/verify-otp — authenticated.</summary>
public sealed class VerifyOtpRequest
{
    public int ChannelId { get; set; } = 1;
    public string Code { get; set; } = string.Empty;
}

/// <summary>GET /api/auth/me</summary>
public sealed class CurrentUserResponse
{
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
    public DateTime? LastLoginOnUtc { get; set; }
    public DateTime? LastPasswordChangeOnUtc { get; set; }
    public DateTime CreatedOnUtc { get; set; }
    public int RowVersion { get; set; }
    public IReadOnlyList<string> Roles { get; set; } = [];
    public IReadOnlyList<string> Permissions { get; set; } = [];
}
