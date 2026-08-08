using JP.Domain.Auth;

namespace JP.Infrastructure.Services;

/// <summary>
/// The public boundary of the authentication layer.
/// </summary>
/// <remarks>
/// Every member returns a DTO from JP.Domain. The internal rows that carry
/// password hashes never appear here, and cannot — they are internal to this
/// assembly, so an API project could not name one even deliberately.
///
/// Failures are raised as AppException carrying an ErrorCodes value;
/// GlobalExceptionHandlerMiddleware renders them into the Response envelope.
/// </remarks>
public interface IAuthService
{
    Task<RegistrationResponse> RegisterSchoolAsync(RegisterSchoolRequest request, CancellationToken cancellationToken);

    Task<RegistrationResponse> RegisterTeacherAsync(RegisterTeacherRequest request, CancellationToken cancellationToken);

    Task<AuthTokenResponse> LoginAsync(LoginRequest request, string? ipAddress, string? userAgent,
        CancellationToken cancellationToken);

    Task<AuthTokenResponse> RefreshAsync(RefreshTokenRequest request, string? ipAddress, string? userAgent,
        CancellationToken cancellationToken);

    Task LogoutAsync(LogoutRequest request, long userId, CancellationToken cancellationToken);

    /// <summary>
    /// Always completes the same way whether the address exists or not.
    /// </summary>
    Task ForgotPasswordAsync(ForgotPasswordRequest request, string? ipAddress, string? userAgent,
        CancellationToken cancellationToken);

    Task ResetPasswordAsync(ResetPasswordRequest request, CancellationToken cancellationToken);

    Task ChangePasswordAsync(ChangePasswordRequest request, Guid userUid, CancellationToken cancellationToken);

    Task SetPasswordFromInviteAsync(SetPasswordFromInviteRequest request, string? ipAddress,
        CancellationToken cancellationToken);

    Task SendOtpAsync(SendOtpRequest request, Guid userUid, CancellationToken cancellationToken);

    Task VerifyOtpAsync(VerifyOtpRequest request, Guid userUid, CancellationToken cancellationToken);

    Task<CurrentUserResponse> GetCurrentUserAsync(Guid userUid, CancellationToken cancellationToken);
}
