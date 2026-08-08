using JP.Core.Common;
using JP.Core.Extensions;
using JP.Domain.Auth;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.Sso.Api.Controllers;

// Rate limits are applied by the chained global limiter configured in
// Program.cs, not by [EnableRateLimiting] attributes here. Login needs two
// independent limits (per IP and per identifier) and a named policy resolves
// to a single partition — see JP.Sso.Api/RateLimiting/AuthRateLimiting.cs.

/// <summary>
/// Authentication and account self-service.
/// </summary>
/// <remarks>
/// Anonymous by default; the endpoints that need a signed-in caller say so
/// individually. Note that <c>[RequireActiveAccount]</c> appears NOWHERE in
/// this controller — a pending school must be able to sign in, change its
/// password and verify its email while it waits for approval. That filter
/// belongs on the business endpoints (PROJECT_MEMORY 2.9).
/// </remarks>
[ApiController]
[Route("api/auth")]
[AllowAnonymous]
public sealed class AuthController : ControllerBase
{
    private readonly IAuthService _auth;

    public AuthController(IAuthService auth) => _auth = auth;

    private string? ClientIp => HttpContext.Connection.RemoteIpAddress?.ToString();

    private string? ClientUserAgent =>
        Request.Headers.UserAgent.ToString() is { Length: > 0 } ua ? ua[..Math.Min(ua.Length, 400)] : null;

    /// <summary>Registers a school. The account starts pending verification.</summary>
    [HttpPost("register/school")]
    [ProducesResponseType(typeof(Response<RegistrationResponse>), StatusCodes.Status200OK)]
    public async Task<IActionResult> RegisterSchool(
        [FromBody] RegisterSchoolRequest request, CancellationToken cancellationToken)
    {
        var result = await _auth.RegisterSchoolAsync(request, cancellationToken);

        return Ok(ApiResponse.Success(result,
            "Registration received. Your account is awaiting verification."));
    }

    /// <summary>Registers a teacher. Active immediately.</summary>
    [HttpPost("register/teacher")]
    [ProducesResponseType(typeof(Response<RegistrationResponse>), StatusCodes.Status200OK)]
    public async Task<IActionResult> RegisterTeacher(
        [FromBody] RegisterTeacherRequest request, CancellationToken cancellationToken)
    {
        var result = await _auth.RegisterTeacherAsync(request, cancellationToken);

        return Ok(ApiResponse.Success(result, "Welcome. Your account is ready."));
    }

    /// <summary>
    /// Signs in with an email or mobile number.
    /// </summary>
    /// <remarks>
    /// Succeeds for a pending account — the token carries the status claim and
    /// the business endpoints are gated separately.
    /// Rate limited per IP and per identifier.
    /// </remarks>
    [HttpPost("login")]
    [ProducesResponseType(typeof(Response<AuthTokenResponse>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status401Unauthorized)]
    public async Task<IActionResult> Login(
        [FromBody] LoginRequest request, CancellationToken cancellationToken)
    {
        var result = await _auth.LoginAsync(request, ClientIp, ClientUserAgent, cancellationToken);

        return Ok(ApiResponse.Success(result, "Signed in."));
    }

    /// <summary>Exchanges a refresh token for a new pair.</summary>
    [HttpPost("refresh-token")]
    [ProducesResponseType(typeof(Response<AuthTokenResponse>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status401Unauthorized)]
    public async Task<IActionResult> Refresh(
        [FromBody] RefreshTokenRequest request, CancellationToken cancellationToken)
    {
        var result = await _auth.RefreshAsync(request, ClientIp, ClientUserAgent, cancellationToken);

        return Ok(ApiResponse.Success(result, "Session refreshed."));
    }

    /// <summary>Signs out this device, or every device.</summary>
    [HttpPost("logout")]
    [Authorize]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> Logout(
        [FromBody] LogoutRequest request, CancellationToken cancellationToken)
    {
        await _auth.LogoutAsync(request, User.GetUserId(), cancellationToken);

        return Ok(ApiResponse.Success("Signed out."));
    }

    /// <summary>
    /// Starts a password reset.
    /// </summary>
    /// <remarks>
    /// Answers identically whether the address has an account or not — the
    /// response text, the status code and the elapsed time all match. Anything
    /// else turns this into an account-existence oracle.
    /// </remarks>
    [HttpPost("forgot-password")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> ForgotPassword(
        [FromBody] ForgotPasswordRequest request, CancellationToken cancellationToken)
    {
        await _auth.ForgotPasswordAsync(request, ClientIp, ClientUserAgent, cancellationToken);

        return Ok(ApiResponse.Success(
            "If that address has an account, we have sent a reset link."));
    }

    /// <summary>Completes a password reset using the emailed token.</summary>
    [HttpPost("reset-password")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> ResetPassword(
        [FromBody] ResetPasswordRequest request, CancellationToken cancellationToken)
    {
        await _auth.ResetPasswordAsync(request, cancellationToken);

        return Ok(ApiResponse.Success(
            "Your password has been changed. Please sign in again."));
    }

    /// <summary>
    /// Changes the signed-in user's password.
    /// </summary>
    /// <remarks>
    /// Revokes every refresh token, including the caller's. That is the point:
    /// a password change that leaves other sessions alive has not removed
    /// anyone's access.
    /// </remarks>
    [HttpPost("change-password")]
    [Authorize]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> ChangePassword(
        [FromBody] ChangePasswordRequest request, CancellationToken cancellationToken)
    {
        await _auth.ChangePasswordAsync(request, User.GetUserUid(), cancellationToken);

        return Ok(ApiResponse.Success(
            "Your password has been changed. Other devices have been signed out."));
    }

    /// <summary>Sets the first password for an invited user.</summary>
    [HttpPost("set-password-from-invite")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> SetPasswordFromInvite(
        [FromBody] SetPasswordFromInviteRequest request, CancellationToken cancellationToken)
    {
        await _auth.SetPasswordFromInviteAsync(request, ClientIp, cancellationToken);

        return Ok(ApiResponse.Success("Your password has been set. You can sign in now."));
    }

    /// <summary>Sends a one-time verification code.</summary>
    [HttpPost("send-otp")]
    [Authorize]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> SendOtp(
        [FromBody] SendOtpRequest request, CancellationToken cancellationToken)
    {
        await _auth.SendOtpAsync(request, User.GetUserUid(), cancellationToken);

        return Ok(ApiResponse.Success("Verification code sent."));
    }

    /// <summary>Verifies a one-time code.</summary>
    [HttpPost("verify-otp")]
    [Authorize]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public async Task<IActionResult> VerifyOtp(
        [FromBody] VerifyOtpRequest request, CancellationToken cancellationToken)
    {
        await _auth.VerifyOtpAsync(request, User.GetUserUid(), cancellationToken);

        return Ok(ApiResponse.Success("Verified."));
    }

    /// <summary>The signed-in user's profile, roles and permissions.</summary>
    [HttpGet("me")]
    [Authorize]
    [ProducesResponseType(typeof(Response<CurrentUserResponse>), StatusCodes.Status200OK)]
    public async Task<IActionResult> Me(CancellationToken cancellationToken)
    {
        var result = await _auth.GetCurrentUserAsync(User.GetUserUid(), cancellationToken);

        return Ok(ApiResponse.Success(result));
    }
}
