using System.Data;
using Dapper;
using JP.Core.Constants;
using JP.Core.Enums;
using JP.Domain.Users;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

/// <summary>
/// Every jp_sso procedure that touches a user, credential, OTP or lockout.
/// </summary>
/// <remarks>
/// Internal by design — its return types carry password hashes, and nothing
/// outside this assembly may hold one. AuthService is the public boundary.
/// </remarks>
internal sealed class UserRepository : BaseRepository, IUserRepository
{
    public UserRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<UserRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.Sso;

    // -----------------------------------------------------------------------
    // Registration
    // -----------------------------------------------------------------------

    public Task<RegisterSchoolResult> RegisterSchoolAsync(
        string email, string? mobile, byte[] hash, byte[] salt, int algorithmId, int iterations,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@Email", email, DbType.String, size: 150);
        p.Add("@Mobile", mobile, DbType.AnsiString, size: 15);
        p.Add("@PasswordHash", hash, DbType.Binary, size: 64);
        p.Add("@PasswordSalt", salt, DbType.Binary, size: 32);
        p.Add("@HashAlgorithmId", algorithmId, DbType.Int32);
        p.Add("@Iterations", iterations, DbType.Int32);

        return QuerySingleAsync<RegisterSchoolResult>("USP_RegisterSchoolUser", p, cancellationToken);
    }

    public Task<RegisterUserResult> RegisterTeacherAsync(
        string email, string? mobile, byte[] hash, byte[] salt, int algorithmId, int iterations,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@Email", email, DbType.String, size: 150);
        p.Add("@Mobile", mobile, DbType.AnsiString, size: 15);
        p.Add("@PasswordHash", hash, DbType.Binary, size: 64);
        p.Add("@PasswordSalt", salt, DbType.Binary, size: 32);
        p.Add("@HashAlgorithmId", algorithmId, DbType.Int32);
        p.Add("@Iterations", iterations, DbType.Int32);

        return QuerySingleAsync<RegisterUserResult>("USP_RegisterTeacherUser", p, cancellationToken);
    }

    public Task<RegisterUserResult> CreateAdminAsync(
        string email, string? mobile, byte[] hash, byte[] salt, int algorithmId, int iterations,
        string roleCode, long? createdByUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@Email", email, DbType.String, size: 150);
        p.Add("@Mobile", mobile, DbType.AnsiString, size: 15);
        p.Add("@PasswordHash", hash, DbType.Binary, size: 64);
        p.Add("@PasswordSalt", salt, DbType.Binary, size: 32);
        p.Add("@HashAlgorithmId", algorithmId, DbType.Int32);
        p.Add("@Iterations", iterations, DbType.Int32);
        p.Add("@RoleCode", roleCode, DbType.AnsiString, size: 50);
        p.Add("@CreatedByUserId", createdByUserId, DbType.Int64);

        return QuerySingleAsync<RegisterUserResult>("USP_CreateAdminUser", p, cancellationToken);
    }

    public Task<InviteUserResult> InviteSchoolUserAsync(
        long invitedByUserId, Guid organizationUid, string email, string? mobile, string roleCode,
        string tokenHash, DateTime expiresOnUtc, string? ipAddress, string? userAgent,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@InvitedByUserId", invitedByUserId, DbType.Int64);
        p.Add("@OrganizationUid", organizationUid, DbType.Guid);
        p.Add("@Email", email, DbType.String, size: 150);
        p.Add("@Mobile", mobile, DbType.AnsiString, size: 15);
        p.Add("@RoleCode", roleCode, DbType.AnsiString, size: 50);
        p.Add("@TokenHash", tokenHash, DbType.AnsiString, size: 128);
        p.Add("@TokenExpiresOn", expiresOnUtc, DbType.DateTime2);
        p.Add("@IpAddress", ipAddress, DbType.AnsiString, size: 45);
        p.Add("@UserAgent", userAgent, DbType.String, size: 400);

        return QuerySingleAsync<InviteUserResult>("USP_InviteSchoolUser", p, cancellationToken);
    }

    public Task<RegisterUserResult> SetPasswordFromInviteAsync(
        string tokenHash, byte[] hash, byte[] salt, int algorithmId, int iterations,
        string? ipAddress, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@TokenHash", tokenHash, DbType.AnsiString, size: 128);
        p.Add("@PasswordHash", hash, DbType.Binary, size: 64);
        p.Add("@PasswordSalt", salt, DbType.Binary, size: 32);
        p.Add("@HashAlgorithmId", algorithmId, DbType.Int32);
        p.Add("@Iterations", iterations, DbType.Int32);
        p.Add("@IpAddress", ipAddress, DbType.AnsiString, size: 45);

        return QuerySingleAsync<RegisterUserResult>("USP_SetPasswordFromInvite", p, cancellationToken);
    }

    // -----------------------------------------------------------------------
    // Login
    // -----------------------------------------------------------------------

    /// <summary>
    /// Null when the identifier matches nothing. The caller must treat that
    /// exactly like a wrong password — including in the time it takes.
    /// </summary>
    public Task<UserLoginRow?> GetForLoginAsync(string loginIdentifier, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@LoginIdentifier", loginIdentifier, DbType.String, size: 150);

        return QueryFirstOrDefaultAsync<UserLoginRow>("USP_GetUserForLogin", p, cancellationToken);
    }

    public Task<LoginAttemptResult> RecordLoginAttemptAsync(
        long? userId, string loginIdentifier, string? ipAddress, string? userAgent,
        bool isSuccess, string? failureReason, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserId", userId, DbType.Int64);
        p.Add("@LoginIdentifier", loginIdentifier, DbType.String, size: 150);
        p.Add("@IpAddress", ipAddress, DbType.AnsiString, size: 45);
        p.Add("@UserAgent", userAgent, DbType.String, size: 400);
        p.Add("@IsSuccess", isSuccess, DbType.Boolean);
        p.Add("@FailureReason", failureReason, DbType.AnsiString, size: 50);

        return QuerySingleAsync<LoginAttemptResult>("USP_RecordLoginAttempt", p, cancellationToken);
    }

    public Task<int> UpdateLastLoginAsync(long userId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserId", userId, DbType.Int64);

        return ExecuteAsync("USP_UpdateLastLogin", p, cancellationToken);
    }

    /// <summary>Two result sets: role codes, then permission codes.</summary>
    public Task<UserClaimSet> GetUserClaimsAsync(long userId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserId", userId, DbType.Int64);

        return QueryMultipleAsync("USP_GetUserClaims", async grid =>
        {
            var roles = (await grid.ReadAsync<string>().ConfigureAwait(false)).AsList();
            var permissions = (await grid.ReadAsync<string>().ConfigureAwait(false)).AsList();

            return new UserClaimSet { Roles = roles, Permissions = permissions };
        }, p, cancellationToken);
    }

    /// <summary>Three result sets: profile, roles, permissions.</summary>
    public Task<(UserProfileRow? Profile, UserClaimSet Claims)> GetUserByUidAsync(
        Guid userUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);

        return QueryMultipleAsync("USP_GetUserByUid", async grid =>
        {
            var profile = await grid.ReadFirstOrDefaultAsync<UserProfileRow>().ConfigureAwait(false);
            var roles = (await grid.ReadAsync<string>().ConfigureAwait(false)).AsList();
            var permissions = (await grid.ReadAsync<string>().ConfigureAwait(false)).AsList();

            return (profile, new UserClaimSet { Roles = roles, Permissions = permissions });
        }, p, cancellationToken);
    }

    // -----------------------------------------------------------------------
    // Password
    // -----------------------------------------------------------------------

    public async Task<IReadOnlyList<PasswordHistoryRow>> GetPasswordHistoryAsync(
        long userId, int depth, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserId", userId, DbType.Int64);
        p.Add("@Depth", depth, DbType.Int32);

        return await QueryAsync<PasswordHistoryRow>("USP_GetPasswordHistory", p, cancellationToken)
            .ConfigureAwait(false);
    }

    public Task<ChangePasswordResult> ChangePasswordAsync(
        long userId, byte[] hash, byte[] salt, int algorithmId, int iterations,
        string? resetTokenHash, long? changedByUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserId", userId, DbType.Int64);
        p.Add("@PasswordHash", hash, DbType.Binary, size: 64);
        p.Add("@PasswordSalt", salt, DbType.Binary, size: 32);
        p.Add("@HashAlgorithmId", algorithmId, DbType.Int32);
        p.Add("@Iterations", iterations, DbType.Int32);
        p.Add("@ResetTokenHash", resetTokenHash, DbType.AnsiString, size: 128);
        p.Add("@ChangedByUserId", changedByUserId, DbType.Int64);

        return QuerySingleAsync<ChangePasswordResult>("USP_ChangePassword", p, cancellationToken);
    }

    public Task<ResetTokenResult> CreatePasswordResetTokenAsync(
        string email, string tokenHash, DateTime expiresOnUtc, string? ipAddress, string? userAgent,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@Email", email, DbType.String, size: 150);
        p.Add("@TokenHash", tokenHash, DbType.AnsiString, size: 128);
        p.Add("@ExpiresOn", expiresOnUtc, DbType.DateTime2);
        p.Add("@IpAddress", ipAddress, DbType.AnsiString, size: 45);
        p.Add("@UserAgent", userAgent, DbType.String, size: 400);

        return QuerySingleAsync<ResetTokenResult>("USP_CreatePasswordResetToken", p, cancellationToken);
    }

    public Task<TokenValidationRow?> ValidatePasswordResetTokenAsync(
        string tokenHash, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@TokenHash", tokenHash, DbType.AnsiString, size: 128);

        return QueryFirstOrDefaultAsync<TokenValidationRow>(
            "USP_ValidatePasswordResetToken", p, cancellationToken);
    }

    // -----------------------------------------------------------------------
    // OTP
    // -----------------------------------------------------------------------

    public Task<ProcResult> SaveOtpAsync(
        long userId, int channelId, string otpHash, string sentTo, DateTime expiresOnUtc,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserId", userId, DbType.Int64);
        p.Add("@OtpChannelId", channelId, DbType.Int32);
        p.Add("@OtpHash", otpHash, DbType.AnsiString, size: 128);
        p.Add("@SentTo", sentTo, DbType.String, size: 150);
        p.Add("@ExpiresOn", expiresOnUtc, DbType.DateTime2);

        return QuerySingleAsync<ProcResult>("USP_SaveOtp", p, cancellationToken);
    }

    public Task<OtpVerifyResult> VerifyOtpAsync(
        long userId, int channelId, string otpHash, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserId", userId, DbType.Int64);
        p.Add("@OtpChannelId", channelId, DbType.Int32);
        p.Add("@OtpHash", otpHash, DbType.AnsiString, size: 128);

        return QuerySingleAsync<OtpVerifyResult>("USP_VerifyOtp", p, cancellationToken);
    }

    // -----------------------------------------------------------------------
    // Administration
    // -----------------------------------------------------------------------

    public Task<UserIdentityRow?> GetIdentityAsync(long userId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserId", userId, DbType.Int64);

        return QueryFirstOrDefaultAsync<UserIdentityRow>("USP_GetUserIdentity", p, cancellationToken);
    }

    public async Task<UpdateStatusResult> UpdateUserStatusForApprovalAsync(
        long userId, int newStatusId, long actionByUserId, CancellationToken cancellationToken)
    {
        // One reader of USP_GetUserIdentity, not two.
        var identity = await GetIdentityAsync(userId, cancellationToken).ConfigureAwait(false);

        if (identity is null)
        {
            return new UpdateStatusResult
            {
                Status = 0,
                Code = ErrorCodes.NotFound,
                Message = "That account was not found.",
            };
        }

        /*
          🔴 ALREADY IN THE TARGET STATE IS SUCCESS, NOT A FAILURE.

          USP_UpdateUserStatus rejects a no-op transition with
          BUSINESS_RULE_VIOLATED — correct for an admin pressing a button
          twice, wrong here.

          This path exists for retries. The cross-database orchestration has no
          distributed transaction, so the recovery for "user activated, school
          not created" is to run it again — and if that re-run treated the
          already-Active user as a failure, it would stop at step 1 and NEVER
          reach the provisioning that was the whole reason for retrying. The
          orphan would be permanent.

          Checked on the status just read rather than by matching the
          procedure's message, which is display text and not a contract.
        */
        if (identity.StatusId == newStatusId)
        {
            return new UpdateStatusResult
            {
                Status = 1,
                Code = null,
                Message = "The account was already active.",
            };
        }

        return await UpdateUserStatusAsync(
            identity.UserUid, newStatusId, identity.RowVersion, actionByUserId,
            "Activated by approval.", cancellationToken).ConfigureAwait(false);
    }

    public Task<UpdateStatusResult> UpdateUserStatusAsync(
        Guid userUid, int newStatusId, int rowVersion, long actionByUserId, string? remarks,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@NewStatusId", newStatusId, DbType.Int32);
        p.Add("@RowVersion", rowVersion, DbType.Int32);
        p.Add("@ActionByUserId", actionByUserId, DbType.Int64);
        p.Add("@Remarks", remarks, DbType.String, size: 500);

        return QuerySingleAsync<UpdateStatusResult>("USP_UpdateUserStatus", p, cancellationToken);
    }

    public Task<UnlockResult> UnlockUserAsync(
        Guid userUid, long actionByUserId, string? remarks, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@ActionByUserId", actionByUserId, DbType.Int64);
        p.Add("@Remarks", remarks, DbType.String, size: 500);

        return QuerySingleAsync<UnlockResult>("USP_UnlockUser", p, cancellationToken);
    }

    /// <summary>
    /// Two result sets: the page, then the total before paging.
    /// </summary>
    /// <remarks>
    /// <paramref name="organizationUid"/> is resolved by the SERVICE from the
    /// caller's token — never from the request. Null means "no scoping", which
    /// only an admin ever gets.
    /// </remarks>
    public Task<(IReadOnlyList<UserListRow> Items, long Total)> GetUserListAsync(
        UserListRequest request, Guid? organizationUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserTypeId", request.UserTypeId, DbType.Int32);
        p.Add("@StatusId", request.StatusId, DbType.Int32);
        p.Add("@OrganizationUid", organizationUid, DbType.Guid);
        p.Add("@Search", request.Search, DbType.String, size: 150);

        // DateOnly -> DateTime with DbType.Date: the procedure's parameters are
        // `date`, and this avoids relying on provider-level DateOnly support.
        p.Add("@FromDate", request.FromDate?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        p.Add("@ToDate", request.ToDate?.ToDateTime(TimeOnly.MinValue), DbType.Date);

        p.Add("@SortBy", request.SortBy, DbType.AnsiString, size: 30);
        p.Add("@SortDirection", request.SortDirection, DbType.AnsiString, size: 4);
        p.Add("@PageNumber", request.PageNumber, DbType.Int32);
        p.Add("@PageSize", request.PageSize, DbType.Int32);

        return QueryMultipleAsync("USP_GetUserList", async grid =>
        {
            var items = (await grid.ReadAsync<UserListRow>().ConfigureAwait(false)).AsList();
            var total = await grid.ReadFirstOrDefaultAsync<long>().ConfigureAwait(false);

            return ((IReadOnlyList<UserListRow>)items, total);
        }, p, cancellationToken);
    }

    public Task<ProcResult> AssignUserRoleAsync(
        Guid userUid, string roleCode, Guid? organizationUid, long assignedByUserId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@RoleCode", roleCode, DbType.AnsiString, size: 50);
        p.Add("@OrganizationUid", organizationUid, DbType.Guid);
        p.Add("@AssignedByUserId", assignedByUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_AssignUserRole", p, cancellationToken);
    }
}
