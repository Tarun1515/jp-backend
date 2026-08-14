using JP.Domain.Users;

namespace JP.Infrastructure.Repositories;

/// <summary>
/// Internal — its return types carry password hashes, so it cannot be public.
/// </summary>
internal interface IUserRepository
{
    Task<RegisterSchoolResult> RegisterSchoolAsync(string email, string? mobile, byte[] hash, byte[] salt,
        int algorithmId, int iterations, CancellationToken cancellationToken);

    Task<RegisterUserResult> RegisterTeacherAsync(string email, string? mobile, byte[] hash, byte[] salt,
        int algorithmId, int iterations, CancellationToken cancellationToken);

    Task<RegisterUserResult> CreateAdminAsync(string email, string? mobile, byte[] hash, byte[] salt,
        int algorithmId, int iterations, string roleCode, long? createdByUserId,
        CancellationToken cancellationToken);

    Task<InviteUserResult> InviteSchoolUserAsync(long invitedByUserId, Guid organizationUid, string email,
        string? mobile, string roleCode, string tokenHash, DateTime expiresOnUtc, string? ipAddress,
        string? userAgent, CancellationToken cancellationToken);

    Task<RegisterUserResult> SetPasswordFromInviteAsync(string tokenHash, byte[] hash, byte[] salt,
        int algorithmId, int iterations, string? ipAddress, CancellationToken cancellationToken);

    Task<UserLoginRow?> GetForLoginAsync(string loginIdentifier, CancellationToken cancellationToken);

    Task<LoginAttemptResult> RecordLoginAttemptAsync(long? userId, string loginIdentifier, string? ipAddress,
        string? userAgent, bool isSuccess, string? failureReason, CancellationToken cancellationToken);

    Task<int> UpdateLastLoginAsync(long userId, CancellationToken cancellationToken);

    Task<UserClaimSet> GetUserClaimsAsync(long userId, CancellationToken cancellationToken);

    Task<(UserProfileRow? Profile, UserClaimSet Claims)> GetUserByUidAsync(Guid userUid,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<PasswordHistoryRow>> GetPasswordHistoryAsync(long userId, int depth,
        CancellationToken cancellationToken);

    Task<ChangePasswordResult> ChangePasswordAsync(long userId, byte[] hash, byte[] salt, int algorithmId,
        int iterations, string? resetTokenHash, long? changedByUserId, CancellationToken cancellationToken);

    Task<ResetTokenResult> CreatePasswordResetTokenAsync(string email, string tokenHash,
        DateTime expiresOnUtc, string? ipAddress, string? userAgent, CancellationToken cancellationToken);

    Task<TokenValidationRow?> ValidatePasswordResetTokenAsync(string tokenHash,
        CancellationToken cancellationToken);

    Task<ProcResult> SaveOtpAsync(long userId, int channelId, string otpHash, string sentTo,
        DateTime expiresOnUtc, CancellationToken cancellationToken);

    Task<OtpVerifyResult> VerifyOtpAsync(long userId, int channelId, string otpHash,
        CancellationToken cancellationToken);

    /// <summary>
    /// Activates a user as the result of an approval, keyed by numeric id.
    /// </summary>
    /// <remarks>
    /// Reads the Uid and current RowVersion, then calls the same
    /// USP_UpdateUserStatus every other status change goes through — so role
    /// granting and token revocation keep exactly one implementation. The
    /// concurrency check is satisfied with the value just read, because here
    /// the server is the actor rather than an admin holding a stale screen.
    /// </remarks>
    Task<UpdateStatusResult> UpdateUserStatusForApprovalAsync(long userId, int newStatusId,
        long actionByUserId, CancellationToken cancellationToken);

    /// <summary>
    /// One account identity — its Uid, organisation, type and status.
    /// </summary>
    /// <remarks>
    /// 🔴 The Uid is the only key that crosses a database boundary in this system
    /// (decision 2.2). Anything in jp_app or jp_mdm that has to name an account
    /// resolves it through here rather than storing the bigint id.
    /// </remarks>
    Task<UserIdentityRow?> GetIdentityAsync(long userId, CancellationToken cancellationToken);

    Task<UpdateStatusResult> UpdateUserStatusAsync(Guid userUid, int newStatusId, int rowVersion,
        long actionByUserId, string? remarks, CancellationToken cancellationToken);

    Task<UnlockResult> UnlockUserAsync(Guid userUid, long actionByUserId, string? remarks,
        CancellationToken cancellationToken);

    Task<(IReadOnlyList<UserListRow> Items, long Total)> GetUserListAsync(UserListRequest request,
        Guid? organizationUid, CancellationToken cancellationToken);

    Task<ProcResult> AssignUserRoleAsync(Guid userUid, string roleCode, Guid? organizationUid,
        long assignedByUserId, CancellationToken cancellationToken);
}
