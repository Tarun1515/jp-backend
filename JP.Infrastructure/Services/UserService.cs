using System.Globalization;
using System.Security.Claims;
using JP.Core.Constants;
using JP.Core.Enums;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Common;
using JP.Domain.Users;
using JP.Infrastructure.Email;
using JP.Infrastructure.Repositories;
using JP.Infrastructure.Security;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Services;

public interface IUserService
{
    Task<InviteUserResponse> InviteAsync(InviteUserRequest request, ClaimsPrincipal caller,
        string? ipAddress, string? userAgent, CancellationToken cancellationToken);

    Task<PagedResult<UserListItemResponse>> GetListAsync(UserListRequest request, ClaimsPrincipal caller,
        CancellationToken cancellationToken);

    Task UpdateStatusAsync(Guid userUid, UpdateUserStatusRequest request, ClaimsPrincipal caller,
        CancellationToken cancellationToken);

    Task UnlockAsync(Guid userUid, UnlockUserRequest request, ClaimsPrincipal caller,
        CancellationToken cancellationToken);
}

internal sealed class UserService : IUserService
{
    private readonly IUserRepository _users;
    private readonly ITokenHasher _tokenHasher;
    private readonly IEmailDispatchQueue _email;
    private readonly AuthOptions _options;
    private readonly ILogger<UserService> _logger;

    public UserService(
        IUserRepository users,
        ITokenHasher tokenHasher,
        IEmailDispatchQueue email,
        IOptions<AuthOptions> options,
        ILogger<UserService> logger)
    {
        _users = users;
        _tokenHasher = tokenHasher;
        _email = email;
        _options = options.Value;
        _logger = logger;
    }

    /// <summary>
    /// Invites a colleague into the CALLER'S organisation.
    /// </summary>
    /// <remarks>
    /// The tenant comes from <c>RequireOrganizationUid()</c> — the JWT claim —
    /// and InviteUserRequest has no organisation field at all, so there is
    /// nothing in the payload to tamper with. The procedure independently
    /// verifies the inviter belongs to that organisation, so a forged token
    /// claim alone would still not be enough.
    /// </remarks>
    public async Task<InviteUserResponse> InviteAsync(
        InviteUserRequest request, ClaimsPrincipal caller, string? ipAddress, string? userAgent,
        CancellationToken cancellationToken)
    {
        var organizationUid = caller.RequireOrganizationUid();
        var invitedBy = caller.GetUserId();

        var token = _tokenHasher.CreateToken();
        var expiresOn = DateTime.UtcNow.AddDays(_options.InviteValidityDays);
        var email = (request.Email ?? string.Empty).Trim().ToLowerInvariant();

        var result = (await _users.InviteSchoolUserAsync(
            invitedBy, organizationUid, email,
            string.IsNullOrWhiteSpace(request.Mobile) ? null : request.Mobile.Trim(),
            request.RoleCode, token.Hash, expiresOn, ipAddress, userAgent,
            cancellationToken).ConfigureAwait(false)).EnsureSuccess();

        // An invite is always a colleague joining a SCHOOL team, so it always lands
        // in the school app — UserType 2 — whoever sent it.
        var inviteUrl = $"{_options.PortalBaseUrlFor((int)UserType.School)}/auth/accept-invite?token={Uri.EscapeDataString(token.PlainText)}";

        // Only the hash was stored. This is the one and only appearance of the
        // plaintext token, and it goes straight into the email.
        _email.Enqueue(new EmailDispatchRequest(
            "password-reset", email, "You have been invited to the Teacher Recruitment Portal",
            new Dictionary<string, string>
            {
                ["UserName"] = email,
                ["ResetUrl"] = inviteUrl,
                ["ValidityMinutes"] = (_options.InviteValidityDays * 24 * 60)
                    .ToString(CultureInfo.InvariantCulture),
            }));

        return new InviteUserResponse
        {
            UserUid = result.UserUid ?? Guid.Empty,
            Email = email,
            InviteExpiresOnUtc = expiresOn,
        };
    }

    /// <summary>
    /// Lists users, scoped to whoever is asking.
    /// </summary>
    /// <remarks>
    /// An admin sees every account. Anyone else is pinned to their own
    /// organisation, from the token. UserListRequest carries no organisation
    /// field, so this cannot be widened from the query string.
    /// </remarks>
    public async Task<PagedResult<UserListItemResponse>> GetListAsync(
        UserListRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        var isAdmin = caller.GetUserType() == UserType.Admin;
        Guid? organizationUid = isAdmin ? null : caller.RequireOrganizationUid();

        var (rows, total) = await _users.GetUserListAsync(request, organizationUid, cancellationToken)
            .ConfigureAwait(false);

        var items = rows.Select(r => new UserListItemResponse
        {
            UserUid = r.UserUid,
            UserTypeId = r.UserTypeId,
            UserTypeName = r.UserTypeName,
            StatusId = r.StatusId,
            StatusCode = r.StatusCode,
            StatusName = r.StatusName,
            Email = r.Email,
            Mobile = r.Mobile,
            IsEmailVerified = r.IsEmailVerified,
            IsMobileVerified = r.IsMobileVerified,
            OrganizationUid = r.OrganizationUid,
            LastLoginOnUtc = r.LastLoginOn,
            FailedAttemptCount = r.FailedAttemptCount,
            CreatedOnUtc = r.CreatedOn,
            RowVersion = r.RowVersion,
        }).ToList();

        return new PagedResult<UserListItemResponse>(items, total, request.PageNumber, request.PageSize);
    }

    public async Task UpdateStatusAsync(
        Guid userUid, UpdateUserStatusRequest request, ClaimsPrincipal caller,
        CancellationToken cancellationToken)
    {
        if (caller.GetUserType() != UserType.Admin)
        {
            throw new ForbiddenException("Only an administrator can change an account's status.");
        }

        var result = (await _users.UpdateUserStatusAsync(
            userUid, request.NewStatusId, request.RowVersion, caller.GetUserId(), request.Remarks,
            cancellationToken).ConfigureAwait(false)).EnsureSuccess();

        _logger.LogInformation(
            "Account {UserUid} moved to status {StatusId} by {ActorUid}. {RevokedTokenCount} token(s) revoked, role granted: {RoleGranted}.",
            userUid, request.NewStatusId, caller.GetUserUid(), result.RevokedTokenCount, result.RoleGranted);
    }

    public async Task UnlockAsync(
        Guid userUid, UnlockUserRequest request, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        if (caller.GetUserType() != UserType.Admin)
        {
            throw new ForbiddenException("Only an administrator can unlock an account.");
        }

        var result = (await _users.UnlockUserAsync(
            userUid, caller.GetUserId(), request.Remarks, cancellationToken).ConfigureAwait(false))
            .EnsureSuccess();

        _logger.LogInformation(
            "Account {UserUid} unlocked by {ActorUid}. {LockoutsCleared} lockout(s) cleared, status restored to {RestoredStatusId}.",
            userUid, caller.GetUserUid(), result.LockoutsCleared,
            result.RestoredStatusId?.ToString(CultureInfo.InvariantCulture) ?? "unchanged");
    }
}
