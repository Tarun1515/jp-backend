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

    Task<UpdateStatusResult> UpdateUserStatusAsync(Guid userUid, int newStatusId, int rowVersion,
        long actionByUserId, string? remarks, CancellationToken cancellationToken);

    Task<UnlockResult> UnlockUserAsync(Guid userUid, long actionByUserId, string? remarks,
        CancellationToken cancellationToken);

    Task<(IReadOnlyList<UserListRow> Items, long Total)> GetUserListAsync(UserListRequest request,
        Guid? organizationUid, CancellationToken cancellationToken);

    Task<ProcResult> AssignUserRoleAsync(Guid userUid, string roleCode, Guid? organizationUid,
        long assignedByUserId, CancellationToken cancellationToken);
}
