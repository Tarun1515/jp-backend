using System.Globalization;
using System.Net;
using System.Security.Cryptography;
using JP.Core.Constants;
using JP.Core.Enums;
using JP.Core.Exceptions;
using JP.Domain.Auth;
using JP.Infrastructure.Email;
using JP.Infrastructure.Repositories;
using JP.Infrastructure.Security;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Services;

internal sealed class AuthService : IAuthService
{
    private readonly IUserRepository _users;
    private readonly ITokenRepository _tokens;
    private readonly IPasswordService _passwords;
    private readonly ITokenHasher _tokenHasher;
    private readonly IJwtService _jwt;
    private readonly IEmailDispatchQueue _email;
    private readonly IDummyCredentialProvider _dummy;
    private readonly AuthOptions _options;
    private readonly JwtOptions _jwtOptions;
    private readonly ILogger<AuthService> _logger;

    public AuthService(
        IUserRepository users,
        ITokenRepository tokens,
        IPasswordService passwords,
        ITokenHasher tokenHasher,
        IJwtService jwt,
        IEmailDispatchQueue email,
        IDummyCredentialProvider dummy,
        IOptions<AuthOptions> options,
        IOptions<JwtOptions> jwtOptions,
        ILogger<AuthService> logger)
    {
        _users = users;
        _tokens = tokens;
        _passwords = passwords;
        _tokenHasher = tokenHasher;
        _jwt = jwt;
        _email = email;
        _dummy = dummy;
        _options = options.Value;
        _jwtOptions = jwtOptions.Value;
        _logger = logger;
    }

    // =======================================================================
    // Registration
    // =======================================================================

    public async Task<RegistrationResponse> RegisterSchoolAsync(
        RegisterSchoolRequest request, CancellationToken cancellationToken)
    {
        var hashed = _passwords.HashPassword(request.Password);

        var result = (await _users.RegisterSchoolAsync(
            NormaliseEmail(request.Email), NormaliseMobile(request.Mobile),
            hashed.Hash, hashed.Salt, (int)hashed.Algorithm, hashed.Iterations,
            cancellationToken).ConfigureAwait(false)).EnsureSuccess();

        return new RegistrationResponse
        {
            UserUid = result.UserUid ?? Guid.Empty,
            OrganizationUid = result.OrganizationUid,
            StatusId = (int)UserStatus.PendingApproval,
            StatusCode = StatusCodeFor(UserStatus.PendingApproval),
        };
    }

    public async Task<RegistrationResponse> RegisterTeacherAsync(
        RegisterTeacherRequest request, CancellationToken cancellationToken)
    {
        var hashed = _passwords.HashPassword(request.Password);

        var result = (await _users.RegisterTeacherAsync(
            NormaliseEmail(request.Email), NormaliseMobile(request.Mobile),
            hashed.Hash, hashed.Salt, (int)hashed.Algorithm, hashed.Iterations,
            cancellationToken).ConfigureAwait(false)).EnsureSuccess();

        return new RegistrationResponse
        {
            UserUid = result.UserUid ?? Guid.Empty,
            OrganizationUid = null,
            StatusId = (int)UserStatus.Active,
            StatusCode = StatusCodeFor(UserStatus.Active),
        };
    }

    // =======================================================================
    // Login
    // =======================================================================

    /// <summary>
    /// Signs a user in.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Constant time by construction.</b> A PBKDF2 verification runs on
    /// EVERY call, including when the identifier matched nothing — against the
    /// decoy credential, with the same iteration count. Skipping it when the
    /// user does not exist would return in ~2 ms instead of ~200 ms and turn
    /// this endpoint into a reliable account-existence oracle, regardless of
    /// how carefully the error message is worded.
    /// </para>
    /// <para>
    /// The same generic failure covers: unknown identifier, wrong password,
    /// soft-deleted account, and an invited account with no password yet.
    /// </para>
    /// <para>
    /// Lock state is revealed only AFTER the password has been verified. A
    /// caller who does not know the password learns nothing; a caller who does
    /// gets told why they cannot get in, which is the whole reason for
    /// surfacing it.
    /// </para>
    /// <para>
    /// Login SUCCEEDS for a pending account (PROJECT_MEMORY 2.9). The token
    /// carries the status claim and <c>[RequireActiveAccount]</c> gates the
    /// business endpoints — a pending school must be able to reach its own
    /// status and document-upload screens.
    /// </para>
    /// </remarks>
    public async Task<AuthTokenResponse> LoginAsync(
        LoginRequest request, string? ipAddress, string? userAgent, CancellationToken cancellationToken)
    {
        var loginId = (request.LoginId ?? string.Empty).Trim();
        var password = request.Password ?? string.Empty;

        var row = await _users.GetForLoginAsync(loginId, cancellationToken).ConfigureAwait(false);

        // ---- the constant-work section --------------------------------------
        // Real credential when there is one, decoy when there is not. Both
        // branches run the identical key derivation.
        var hasRealCredential = row is { HasCredential: true };

        var hash = hasRealCredential ? row!.PasswordHash! : _dummy.Credential.Hash;
        var salt = hasRealCredential ? row!.PasswordSalt! : _dummy.Credential.Salt;
        var iterations = hasRealCredential ? row!.Iterations!.Value : _dummy.Credential.Iterations;
        var algorithm = hasRealCredential ? row!.Algorithm : _dummy.Credential.Algorithm;

        var passwordMatches = _passwords.VerifyPassword(password, hash, salt, iterations, algorithm);

        // Can only be true against a REAL credential. The decoy is a hash of a
        // random GUID, so no supplied password can ever match it.
        var authenticated = hasRealCredential && passwordMatches;
        // ---------------------------------------------------------------------

        if (!authenticated)
        {
            await _users.RecordLoginAttemptAsync(
                row?.UserId, loginId, ipAddress, userAgent, false,
                row is null ? "NO_SUCH_USER" : "INVALID_PASSWORD",
                cancellationToken).ConfigureAwait(false);

            throw InvalidCredentials();
        }

        if (row!.IsLocked)
        {
            await _users.RecordLoginAttemptAsync(
                row.UserId, loginId, ipAddress, userAgent, false, "ACCOUNT_LOCKED",
                cancellationToken).ConfigureAwait(false);

            // Deliberately vague: no attempt count, no unlock time. Enough for
            // the user to stop retrying, not enough to help someone measure the
            // lockout policy.
            throw new AppException(
                "This account is temporarily locked. Please try again later.",
                ErrorCodes.AccountLocked, HttpStatusCode.Unauthorized);
        }

        await _users.RecordLoginAttemptAsync(
            row.UserId, loginId, ipAddress, userAgent, true, null, cancellationToken).ConfigureAwait(false);

        var response = await IssueTokensAsync(
            row.UserId, row.UserUid, row.UserTypeId, row.EffectiveStatusId, row.OrganizationUid,
            ipAddress, userAgent, cancellationToken).ConfigureAwait(false);

        await _users.UpdateLastLoginAsync(row.UserId, cancellationToken).ConfigureAwait(false);

        return response;
    }

    /// <summary>
    /// Rotates a refresh token.
    /// </summary>
    /// <remarks>
    /// Every failure — unknown token, expired, revoked, or a detected reuse —
    /// produces the SAME plain 401. Confirming that reuse was detected would
    /// tell an attacker their stolen token was genuine and that the theft has
    /// been noticed, which is information worth denying them. The chain has
    /// already been revoked inside the procedure regardless.
    /// </remarks>
    public async Task<AuthTokenResponse> RefreshAsync(
        RefreshTokenRequest request, string? ipAddress, string? userAgent, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(request.RefreshToken))
        {
            throw SessionExpired();
        }

        var presentedHash = _tokenHasher.Hash(request.RefreshToken);

        var existing = await _tokens.ValidateRefreshTokenAsync(presentedHash, cancellationToken)
            .ConfigureAwait(false);

        if (existing is null)
        {
            throw SessionExpired();
        }

        var replacement = _jwt.CreateRefreshToken();

        var rotation = await _tokens.RotateRefreshTokenAsync(
            existing.UserId, presentedHash, replacement.Token.Hash, replacement.ExpiresOnUtc,
            ipAddress, userAgent, cancellationToken).ConfigureAwait(false);

        if (!rotation.Succeeded)
        {
            if (rotation.ReuseDetected)
            {
                // Worth a loud log — this is either a stolen token or a client
                // bug, and both need investigating.
                _logger.LogWarning(
                    "Refresh token reuse detected for user {UserUid}. {RevokedCount} token(s) revoked. IP {IpAddress}.",
                    existing.UserUid, rotation.RevokedCount, ipAddress);
            }

            throw SessionExpired();
        }

        var claims = await _users.GetUserClaimsAsync(existing.UserId, cancellationToken).ConfigureAwait(false);

        var access = _jwt.CreateAccessToken(new JwtUserContext
        {
            UserId = existing.UserId,
            UserUid = existing.UserUid,
            UserType = (UserType)existing.UserTypeId,
            Status = (UserStatus)existing.StatusId,
            OrganizationUid = existing.OrganizationUid,
            Roles = claims.Roles,
            Permissions = claims.Permissions,
        });

        return new AuthTokenResponse
        {
            AccessToken = access.Token,
            RefreshToken = replacement.Token.PlainText,
            AccessTokenExpiresOnUtc = access.ExpiresOnUtc,
            RefreshTokenExpiresOnUtc = replacement.ExpiresOnUtc,
            StatusId = existing.StatusId,
            StatusCode = StatusCodeFor((UserStatus)existing.StatusId),
            UserTypeId = existing.UserTypeId,
            UserUid = existing.UserUid,
            OrganizationUid = existing.OrganizationUid,
            Roles = claims.Roles,
            Permissions = claims.Permissions,
        };
    }

    public async Task LogoutAsync(LogoutRequest request, long userId, CancellationToken cancellationToken)
    {
        if (request.AllDevices)
        {
            await _tokens.RevokeAllUserTokensAsync(userId, (int)TokenType.Refresh, userId, cancellationToken)
                .ConfigureAwait(false);
            return;
        }

        if (!string.IsNullOrWhiteSpace(request.RefreshToken))
        {
            await _tokens.RevokeRefreshTokenAsync(
                _tokenHasher.Hash(request.RefreshToken), userId, cancellationToken).ConfigureAwait(false);
        }
    }

    // =======================================================================
    // Password
    // =======================================================================

    /// <summary>
    /// Starts a password reset.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Identical response and comparable timing whether the address exists or
    /// not. Two things make that true:
    /// </para>
    /// <list type="number">
    ///   <item>A decoy key derivation runs on BOTH paths, so a fixed ~200 ms
    ///   dominates the few milliseconds of database writes that only the
    ///   found path performs.</item>
    ///   <item>The email is dispatched OFF the request path. Awaiting an SMTP
    ///   round trip only when the account exists would leak existence through
    ///   the clock far more loudly than any database work.</item>
    /// </list>
    /// </remarks>
    public async Task ForgotPasswordAsync(
        ForgotPasswordRequest request, string? ipAddress, string? userAgent, CancellationToken cancellationToken)
    {
        var email = NormaliseEmail(request.Email);
        var token = _tokenHasher.CreateToken();
        var expiresOn = DateTime.UtcNow.AddMinutes(_options.PasswordResetValidityMinutes);

        var result = await _users.CreatePasswordResetTokenAsync(
            email, token.Hash, expiresOn, ipAddress, userAgent, cancellationToken).ConfigureAwait(false);

        // Constant work on BOTH paths. The result is discarded; it exists only
        // to spend the same time either way.
        _ = _passwords.VerifyPassword(
            token.PlainText, _dummy.Credential.Hash, _dummy.Credential.Salt,
            _dummy.Credential.Iterations, _dummy.Credential.Algorithm);

        if (!result.Succeeded)
        {
            // A genuinely malformed request. Still no hint about the address.
            _logger.LogWarning("Password reset request rejected: {Code}", result.Code);
            return;
        }

        if (result.UserId is null)
        {
            // Unknown address. Nothing was written and nothing is sent — and the
            // caller cannot tell, because the response and the timing match.
            return;
        }

        var resetUrl = $"{_options.PortalBaseUrlFor(result.UserTypeId)}/auth/reset-password?token={Uri.EscapeDataString(token.PlainText)}";

        DispatchEmail(
            "password-reset", email, "Reset your password",
            new Dictionary<string, string>
            {
                ["UserName"] = email,
                ["ResetUrl"] = resetUrl,
                ["ValidityMinutes"] = _options.PasswordResetValidityMinutes.ToString(CultureInfo.InvariantCulture),
            });
    }

    public async Task ResetPasswordAsync(ResetPasswordRequest request, CancellationToken cancellationToken)
    {
        var tokenHash = _tokenHasher.Hash(request.Token);

        var token = await _users.ValidatePasswordResetTokenAsync(tokenHash, cancellationToken)
            .ConfigureAwait(false);

        if (token is null || !token.IsValid)
        {
            throw new AppException(
                "This reset link is not valid or has already been used.",
                ErrorCodes.TokenInvalid, HttpStatusCode.BadRequest);
        }

        await EnsureNotReusedAsync(token.UserId, request.NewPassword, cancellationToken).ConfigureAwait(false);

        var hashed = _passwords.HashPassword(request.NewPassword);

        (await _users.ChangePasswordAsync(
            token.UserId, hashed.Hash, hashed.Salt, (int)hashed.Algorithm, hashed.Iterations,
            tokenHash, token.UserId, cancellationToken).ConfigureAwait(false)).EnsureSuccess();
    }

    public async Task ChangePasswordAsync(
        ChangePasswordRequest request, Guid userUid, CancellationToken cancellationToken)
    {
        var (profile, _) = await _users.GetUserByUidAsync(userUid, cancellationToken).ConfigureAwait(false);

        if (profile is null)
        {
            throw new NotFoundException("That account no longer exists.");
        }

        var row = await _users.GetForLoginAsync(profile.Email, cancellationToken).ConfigureAwait(false);

        if (row is null || !row.HasCredential
            || !_passwords.VerifyPassword(request.CurrentPassword, row.PasswordHash!, row.PasswordSalt!,
                                          row.Iterations!.Value, row.Algorithm))
        {
            throw new AppException(
                "Your current password is not correct.",
                ErrorCodes.PasswordIncorrect, HttpStatusCode.BadRequest);
        }

        await EnsureNotReusedAsync(profile.UserId, request.NewPassword, cancellationToken).ConfigureAwait(false);

        var hashed = _passwords.HashPassword(request.NewPassword);

        (await _users.ChangePasswordAsync(
            profile.UserId, hashed.Hash, hashed.Salt, (int)hashed.Algorithm, hashed.Iterations,
            null, profile.UserId, cancellationToken).ConfigureAwait(false)).EnsureSuccess();
    }

    /// <summary>
    /// Blocks reuse of the last N passwords.
    /// </summary>
    /// <remarks>
    /// This cannot be done in SQL. Each historical credential has its own random
    /// salt, so the only way to know whether the new password matches an old one
    /// is to re-derive it once per history row, with that row's salt and cost,
    /// and compare in constant time. The procedure supplies the rows; the
    /// decision is made here.
    /// </remarks>
    private async Task EnsureNotReusedAsync(long userId, string newPassword, CancellationToken cancellationToken)
    {
        var history = await _users.GetPasswordHistoryAsync(
            userId, AppConstants.Password.HistoryDepth, cancellationToken).ConfigureAwait(false);

        foreach (var previous in history)
        {
            if (_passwords.VerifyPassword(
                    newPassword, previous.PasswordHash, previous.PasswordSalt,
                    previous.Iterations, previous.Algorithm))
            {
                throw new BusinessRuleException(
                    $"Please choose a password you have not used before. "
                    + $"The last {AppConstants.Password.HistoryDepth} cannot be reused.",
                    ErrorCodes.PasswordReused);
            }
        }
    }

    public async Task SetPasswordFromInviteAsync(
        SetPasswordFromInviteRequest request, string? ipAddress, CancellationToken cancellationToken)
    {
        var hashed = _passwords.HashPassword(request.Password);

        (await _users.SetPasswordFromInviteAsync(
            _tokenHasher.Hash(request.Token), hashed.Hash, hashed.Salt,
            (int)hashed.Algorithm, hashed.Iterations, ipAddress,
            cancellationToken).ConfigureAwait(false)).EnsureSuccess();
    }

    // =======================================================================
    // OTP
    // =======================================================================

    public async Task SendOtpAsync(SendOtpRequest request, Guid userUid, CancellationToken cancellationToken)
    {
        var (profile, _) = await _users.GetUserByUidAsync(userUid, cancellationToken).ConfigureAwait(false);

        if (profile is null)
        {
            throw new NotFoundException("That account no longer exists.");
        }

        var code = GenerateOtp();
        var sentTo = request.ChannelId == (int)OtpChannel.Sms ? profile.Mobile : profile.Email;

        if (string.IsNullOrWhiteSpace(sentTo))
        {
            throw new BusinessRuleException(
                "There is no destination on file for that channel.", ErrorCodes.ValidationFailed);
        }

        (await _users.SaveOtpAsync(
            profile.UserId, request.ChannelId, _tokenHasher.Hash(code), sentTo,
            DateTime.UtcNow.AddMinutes(_options.OtpValidityMinutes),
            cancellationToken).ConfigureAwait(false)).EnsureSuccess();

        if (request.ChannelId == (int)OtpChannel.Email)
        {
            DispatchEmail(
                "otp", sentTo, "Your verification code",
                new Dictionary<string, string>
                {
                    ["UserName"] = profile.Email,
                    ["OtpCode"] = code,
                    ["ValidityMinutes"] = _options.OtpValidityMinutes.ToString(CultureInfo.InvariantCulture),
                });
        }

        // SMS delivery is client question 6 (provider undecided). The code is
        // stored either way, so the flow is complete the moment a provider is
        // wired in.
    }

    public async Task VerifyOtpAsync(VerifyOtpRequest request, Guid userUid, CancellationToken cancellationToken)
    {
        var (profile, _) = await _users.GetUserByUidAsync(userUid, cancellationToken).ConfigureAwait(false);

        if (profile is null)
        {
            throw new NotFoundException("That account no longer exists.");
        }

        (await _users.VerifyOtpAsync(
            profile.UserId, request.ChannelId, _tokenHasher.Hash(request.Code ?? string.Empty),
            cancellationToken).ConfigureAwait(false)).EnsureSuccess();
    }

    // =======================================================================
    // Profile
    // =======================================================================

    public async Task<CurrentUserResponse> GetCurrentUserAsync(Guid userUid, CancellationToken cancellationToken)
    {
        var (profile, claims) = await _users.GetUserByUidAsync(userUid, cancellationToken).ConfigureAwait(false);

        if (profile is null)
        {
            throw new NotFoundException("That account no longer exists.");
        }

        return new CurrentUserResponse
        {
            UserUid = profile.UserUid,
            UserTypeId = profile.UserTypeId,
            UserTypeCode = profile.UserTypeCode,
            StatusId = profile.StatusId,
            StatusCode = profile.StatusCode,
            StatusName = profile.StatusName,
            Email = profile.Email,
            Mobile = profile.Mobile,
            IsEmailVerified = profile.IsEmailVerified,
            IsMobileVerified = profile.IsMobileVerified,
            OrganizationUid = profile.OrganizationUid,
            LastLoginOnUtc = profile.LastLoginOn,
            LastPasswordChangeOnUtc = profile.LastPasswordChangeOn,
            CreatedOnUtc = profile.CreatedOn,
            RowVersion = profile.RowVersion,
            Roles = claims.Roles,
            Permissions = claims.Permissions,
        };
    }

    // =======================================================================
    // Helpers
    // =======================================================================

    private async Task<AuthTokenResponse> IssueTokensAsync(
        long userId, Guid userUid, int userTypeId, int statusId, Guid? organizationUid,
        string? ipAddress, string? userAgent, CancellationToken cancellationToken)
    {
        var claims = await _users.GetUserClaimsAsync(userId, cancellationToken).ConfigureAwait(false);

        var access = _jwt.CreateAccessToken(new JwtUserContext
        {
            UserId = userId,
            UserUid = userUid,
            UserType = (UserType)userTypeId,
            Status = (UserStatus)statusId,
            OrganizationUid = organizationUid,
            Roles = claims.Roles,
            Permissions = claims.Permissions,
        });

        var refresh = _jwt.CreateRefreshToken();

        (await _tokens.SaveRefreshTokenAsync(
            userId, refresh.Token.Hash, refresh.ExpiresOnUtc, ipAddress, userAgent,
            cancellationToken).ConfigureAwait(false)).EnsureSuccess();

        return new AuthTokenResponse
        {
            AccessToken = access.Token,
            // The ONLY place the plaintext refresh token exists. The database
            // holds its hash.
            RefreshToken = refresh.Token.PlainText,
            AccessTokenExpiresOnUtc = access.ExpiresOnUtc,
            RefreshTokenExpiresOnUtc = refresh.ExpiresOnUtc,
            StatusId = statusId,
            StatusCode = StatusCodeFor((UserStatus)statusId),
            UserTypeId = userTypeId,
            UserUid = userUid,
            OrganizationUid = organizationUid,
            Roles = claims.Roles,
            Permissions = claims.Permissions,
        };
    }

    /// <summary>
    /// Sends without blocking the request.
    /// </summary>
    /// <remarks>
    /// Fire-and-forget on purpose. On the forgot-password path, awaiting an
    /// SMTP round trip ONLY when the account exists would reintroduce the exact
    /// timing oracle the decoy verification closes. Failures are logged and
    /// never propagate — an email problem must not fail the caller's request.
    /// </remarks>
    /// <summary>
    /// Hands the message to the background dispatcher and returns.
    /// </summary>
    /// <remarks>
    /// This is a security boundary, not a convenience. Forgot-password must
    /// take the same time whether the address has an account or not; sending
    /// inline — even via Task.Run, which still runs on the thread pool the
    /// request's own continuations need — was measurably slower on the path
    /// that had an email to send, at about 10% of the response time. Queueing
    /// reduces "there was an email" to a channel write. See
    /// Email/EmailDispatchQueue.cs.
    /// </remarks>
    private void DispatchEmail(string template, string to, string subject, IReadOnlyDictionary<string, string> tokens) =>
        _email.Enqueue(new EmailDispatchRequest(template, to, subject, tokens));

    /// <summary>Cryptographically random, not Random — this is a credential.</summary>
    private static string GenerateOtp()
    {
        var max = (int)Math.Pow(10, AppConstants.Otp.Length);
        var value = RandomNumberGenerator.GetInt32(0, max);

        return value.ToString(CultureInfo.InvariantCulture).PadLeft(AppConstants.Otp.Length, '0');
    }

    private static string NormaliseEmail(string? email) =>
        (email ?? string.Empty).Trim().ToLowerInvariant();

    private static string? NormaliseMobile(string? mobile) =>
        string.IsNullOrWhiteSpace(mobile) ? null : mobile.Trim();

    /// <summary>Mirrors the seeded m_sso_user_status codes.</summary>
    private static string StatusCodeFor(UserStatus status) => status switch
    {
        UserStatus.PendingApproval => "PENDING_APPROVAL",
        UserStatus.Active => "ACTIVE",
        UserStatus.Rejected => "REJECTED",
        UserStatus.Suspended => "SUSPENDED",
        UserStatus.Locked => "LOCKED",
        UserStatus.ResubmitRequired => "RESUBMIT_REQUIRED",
        _ => "UNKNOWN",
    };

    /// <summary>
    /// One message for every way a sign-in can fail to authenticate. Splitting
    /// them would let an attacker map which addresses have accounts.
    /// </summary>
    private static AppException InvalidCredentials() => new(
        "That email or password is not correct.",
        ErrorCodes.InvalidCredentials, HttpStatusCode.Unauthorized);

    private static AppException SessionExpired() => new(
        "Your session is no longer valid. Please sign in again.",
        ErrorCodes.TokenInvalid, HttpStatusCode.Unauthorized);
}
