using System.Globalization;
using System.Security.Claims;
using JP.Core.Constants;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Schools;
using JP.Infrastructure.Email;
using JP.Infrastructure.Repositories;
using JP.Infrastructure.Security;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Services;

public interface ISchoolTeamService
{
    Task<SchoolTeamDto> GetTeamAsync(ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<InviteTeamMemberResponse> InviteAsync(InviteTeamMemberRequest request, ClaimsPrincipal caller,
        string? ipAddress, string? userAgent, CancellationToken cancellationToken);

    Task SaveRoleAsync(Guid targetUserUid, SaveTeamMemberRoleRequest request, ClaimsPrincipal caller,
        CancellationToken cancellationToken);

    Task SaveBranchesAsync(Guid targetUserUid, SaveTeamMemberBranchesRequest request, ClaimsPrincipal caller,
        CancellationToken cancellationToken);

    Task DeactivateAsync(Guid targetUserUid, ClaimsPrincipal caller, CancellationToken cancellationToken);
}

/// <summary>
/// A school's team — the one feature in this API that writes to two databases.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 THERE IS NO DISTRIBUTED TRANSACTION HERE EITHER (2.2, 2.48).
/// </para>
/// <para>
/// An invitation creates an account in jp_sso and a membership in jp_app. Step 1
/// can succeed and step 2 fail, and what that leaves behind is specific: a
/// person with a working account, a working invitation email, and no membership.
/// They set a password, sign in, and every school screen refuses them.
/// </para>
/// <para>
/// The same three properties as the approval orchestrator make it survivable:
/// </para>
/// <list type="number">
///   <item>
///     <b>Ordering.</b> The account first, the membership second. Reversed, a
///     failure would leave a membership pointing at an account that does not
///     exist — invisible from both sides and impossible to clean up from the UI.
///     This way the failure is reachable: the person exists and can say so.
///   </item>
///   <item>
///     <b>Idempotency.</b> USP_ProvisionSchoolUser keys on (SchoolId, UserUid)
///     and this service turns a DUPLICATE_EMAIL from step 1 into a lookup of the
///     account it already created. So RETRYING THE INVITE IS THE FIX, and it is
///     a fix the school can apply themselves.
///   </item>
///   <item>
///     <b>Loud failure.</b> A step-2 failure logs at Error with the email, the
///     Uid and the school, and the caller is told the account exists and the
///     invite should be retried. It never reports an invitation as sent when the
///     colleague cannot get in.
///   </item>
/// </list>
/// <para>
/// ⚠️ Everything that can be checked BEFORE the account is created is checked
/// before the account is created — the role, the address, the campuses. An
/// account created for a request that was never valid is the worst kind of
/// orphan: nobody is waiting for it, so nobody reports it.
/// </para>
/// </remarks>
internal sealed class SchoolTeamService : ISchoolTeamService
{
    private readonly ISchoolTeamRepository _team;
    private readonly ISchoolProfileService _schools;
    private readonly IUserRepository _users;
    private readonly ITokenRepository _tokens;
    private readonly ITokenHasher _tokenHasher;
    private readonly IEmailDispatchQueue _email;
    private readonly AuthOptions _options;
    private readonly ILogger<SchoolTeamService> _logger;

    public SchoolTeamService(
        ISchoolTeamRepository team,
        ISchoolProfileService schools,
        IUserRepository users,
        ITokenRepository tokens,
        ITokenHasher tokenHasher,
        IEmailDispatchQueue email,
        IOptions<AuthOptions> options,
        ILogger<SchoolTeamService> logger)
    {
        _team = team;
        _schools = schools;
        _users = users;
        _tokens = tokens;
        _tokenHasher = tokenHasher;
        _email = email;
        _options = options.Value;
        _logger = logger;
    }

    /// <summary>
    /// The team, joined across two databases in memory.
    /// </summary>
    /// <remarks>
    /// The membership and the campus scope come from jp_app; the email address
    /// and the account's own status come from jp_sso. No query may join them
    /// (2.2), so this is where the two halves meet.
    ///
    /// ⚠️ A member whose jp_sso row cannot be read still appears, with an empty
    /// email. Dropping them would hide somebody who has access to the school,
    /// which is the opposite of what a team screen is for.
    /// </remarks>
    public async Task<SchoolTeamDto> GetTeamAsync(ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        var organizationUid = caller.RequireOrganizationUid();

        // The profile carries GroupType and the caller's own visible campuses,
        // resolved by the same function the team's links pass through — so the
        // matrix and its columns cannot describe different scopes.
        var profile = await _schools.GetProfileAsync(caller, cancellationToken).ConfigureAwait(false);

        var rows = await _team.GetTeamAsync(profile.SchoolId, caller.GetUserUid(), cancellationToken)
            .ConfigureAwait(false);

        var accounts = await _users
            .GetUsersByUidsAsync(rows.Members.Select(m => m.UserUid).ToList(), organizationUid, cancellationToken)
            .ConfigureAwait(false);

        var byUid = accounts.ToDictionary(a => a.UserUid);
        var branchesByMember = rows.Branches
            .GroupBy(b => b.SchoolUserId)
            .ToDictionary(g => g.Key, g => (IReadOnlyList<long>)g.Select(x => x.BranchId).ToList());

        var members = rows.Members.Select(m =>
        {
            byUid.TryGetValue(m.UserUid, out var account);

            if (account is null)
            {
                _logger.LogWarning(
                    "School {SchoolId} has a member {UserUid} with no readable account in jp_sso for " +
                    "organisation {OrganizationUid}. They are listed without an email address.",
                    profile.SchoolId, m.UserUid, organizationUid);
            }

            return new SchoolTeamMemberDto
            {
                UserUid = m.UserUid,
                FullName = m.FullName,
                Email = account?.Email ?? string.Empty,
                DesignationText = m.DesignationText,
                RoleInSchool = m.RoleInSchool,
                RoleName = SchoolRoles.NameFor(m.RoleInSchool),
                IsOwner = m.RoleInSchool == SchoolRoles.Owner,
                IsActive = m.Is_Active == 1,
                AccountStatusId = account?.StatusId ?? 0,
                AccountStatusCode = account?.StatusCode ?? string.Empty,
                BranchIds = branchesByMember.TryGetValue(m.SchoolUserId, out var ids) ? ids : [],
                BranchCount = m.BranchCount,
                LastLoginOnUtc = account?.LastLoginOn,
                CreatedOnUtc = m.CreatedOn,
            };
        }).ToList();

        return new SchoolTeamDto
        {
            GroupType = profile.GroupType,
            Campuses = profile.Branches
                .Select(b => new TeamCampusDto
                {
                    BranchId = b.BranchId,
                    BranchName = b.BranchName,
                    IsHeadOffice = b.IsHeadOffice,
                })
                .ToList(),
            Members = members,
        };
    }

    public async Task<InviteTeamMemberResponse> InviteAsync(
        InviteTeamMemberRequest request, ClaimsPrincipal caller, string? ipAddress, string? userAgent,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);
        ArgumentNullException.ThrowIfNull(caller);

        var organizationUid = caller.RequireOrganizationUid();
        var invitedByUserId = caller.GetUserId();
        var callerUid = caller.GetUserUid();

        var profile = await _schools.GetProfileAsync(caller, cancellationToken).ConfigureAwait(false);
        var email = (request.Email ?? string.Empty).Trim().ToLowerInvariant();

        /*
          ---- EVERYTHING CHECKABLE, BEFORE ANYTHING IS CREATED ----------------

          🔴 These are all checked again inside the procedures, which is where
          they are enforced. They are here as well so that an invalid request
          never gets as far as creating an account in jp_sso — a step this
          service cannot roll back.
        */
        if (email.Length == 0)
        {
            throw new BusinessRuleException(
                "An email address is needed — that is where the invitation goes.",
                ErrorCodes.ValidationFailed);
        }

        if (!SchoolRoles.IsAssignable(request.RoleInSchool))
        {
            throw new BusinessRuleException(
                request.RoleInSchool == SchoolRoles.Owner
                    ? "A school has exactly one owner and it cannot be given away by invitation. Invite them as " +
                      "Senior HR — they will be able to do everything except manage the owner."
                    : "Choose a role: Senior HR, HR or Viewer.",
                ErrorCodes.ValidationFailed);
        }

        var visible = profile.Branches.Select(b => b.BranchId).ToHashSet();
        var requested = (request.BranchIds ?? []).Distinct().ToList();

        if (requested.Any(id => !visible.Contains(id)))
        {
            throw new BusinessRuleException(
                "One of those campuses is not one you can assign.",
                ErrorCodes.ValidationFailed);
        }

        var roleCode = SchoolRoles.CodeFor(request.RoleInSchool)!;

        // ---- STEP 1: jp_sso — the account, its role and its invite token ----
        var token = _tokenHasher.CreateToken();
        var expiresOn = DateTime.UtcNow.AddDays(_options.InviteValidityDays);

        Guid newUserUid;
        var existingAccountAttached = false;

        var invite = await _users.InviteSchoolUserAsync(
            invitedByUserId, organizationUid, email,
            string.IsNullOrWhiteSpace(request.Mobile) ? null : request.Mobile.Trim(),
            roleCode, token.Hash, expiresOn, ipAddress, userAgent, cancellationToken).ConfigureAwait(false);

        if (invite.Succeeded)
        {
            newUserUid = invite.UserUid ?? Guid.Empty;
        }
        else if (string.Equals(invite.Code, ErrorCodes.DuplicateEmail, StringComparison.Ordinal))
        {
            /*
              🔴 THE RETRY PATH.

              The address already has an account. Two very different reasons:

                - a previous invitation created it and the membership write then
                  failed. This is the case that has to be recoverable, and
                  retrying the invite is how a school recovers it themselves.

                - the address belongs to somebody else entirely — another
                  school's staff, or a teacher. The lookup is organisation-scoped,
                  so it returns nothing and we refuse.

              ⚠️ No new invitation email goes out on this path. A second token
              cannot be issued for an existing account through
              USP_InviteSchoolUser, and claiming to have sent one would be a
              lie. The response says the account was attached, and the colleague
              can use "forgot password" if the first email is gone.
            */
            var existing = await _users.GetUserByEmailAsync(email, organizationUid, cancellationToken)
                .ConfigureAwait(false);

            if (existing is null)
            {
                throw new BusinessRuleException(
                    "An account already exists with this email address, and it is not part of your school. " +
                    "If this is your colleague, they should sign in with the account they already have.",
                    ErrorCodes.DuplicateEmail);
            }

            newUserUid = existing.UserUid;
            existingAccountAttached = true;

            _logger.LogWarning(
                "Invitation for {Email} found an existing account {UserUid} in organisation {OrganizationUid}. " +
                "Attaching it to school {SchoolId} — this is the retry path for an invitation whose membership " +
                "write failed.",
                email, existing.UserUid, organizationUid, profile.SchoolId);
        }
        else
        {
            // Anything else — a bad address, a role this organisation may not
            // use, an inviter who does not belong here — is the procedure's
            // decision, with its own message.
            invite.EnsureSuccess();
            throw new InvalidOperationException("Unreachable: EnsureSuccess throws for a failed result.");
        }

        // ---- STEP 2: jp_app — the membership and the campus scope -----------
        ProvisionSchoolUserResult provisioned;

        try
        {
            provisioned = await _team.ProvisionMemberAsync(
                profile.SchoolId, callerUid, newUserUid, request.RoleInSchool,
                request.FullName, request.DesignationText, requested, invitedByUserId, cancellationToken)
                .ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            /*
              🔴 PARTIAL COMPLETION. The loud half of the contract.

              Everything needed to finish it by hand or by retry is in this one
              line: who, where, and which school.
            */
            _logger.LogError(
                ex,
                "🔴 PARTIAL COMPLETION. An account exists for {Email} ({UserUid}) in organisation " +
                "{OrganizationUid} but the membership write for school {SchoolId} threw. That person can set a " +
                "password and will then be refused by every school screen. Retrying the invitation attaches the " +
                "existing account.",
                email, newUserUid, organizationUid, profile.SchoolId);

            throw new BusinessRuleException(
                "The account was created but adding it to your team failed. Send the invitation again — it will " +
                "attach the account that already exists rather than making a second one.");
        }

        if (!provisioned.Succeeded)
        {
            _logger.LogError(
                "🔴 PARTIAL COMPLETION. An account exists for {Email} ({UserUid}) but the membership write for " +
                "school {SchoolId} failed with {Code} — {Message}. Retrying the invitation attaches the " +
                "existing account.",
                email, newUserUid, profile.SchoolId, provisioned.Code, provisioned.Message);

            throw ProcResultExtensions.ToException(provisioned.Code, provisioned.Message);
        }

        var alreadyOnTeam = string.Equals(provisioned.Code, "ALREADY_A_MEMBER", StringComparison.Ordinal);

        // ---- STEP 3: the email. Last, and never fatal. ----------------------
        //
        // The membership exists and the account works; a notification that
        // could not be queued is not a reason to tell the school their
        // invitation failed. Queued rather than sent inline (2.33).
        if (!existingAccountAttached && !alreadyOnTeam)
        {
            await QueueInvitationEmailAsync(
                request, profile, caller, email, token.PlainText, requested, cancellationToken)
                .ConfigureAwait(false);
        }

        return new InviteTeamMemberResponse
        {
            UserUid = newUserUid,
            Email = email,
            InviteExpiresOnUtc = existingAccountAttached ? null : expiresOn,
            AlreadyOnTeam = alreadyOnTeam,
            ExistingAccountAttached = existingAccountAttached,
        };
    }

    public async Task SaveRoleAsync(
        Guid targetUserUid, SaveTeamMemberRoleRequest request, ClaimsPrincipal caller,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        /*
          ⚠️ The jp_sso role is NOT updated here, and that is a gap rather than a
          decision — see G24. Changing RoleInSchool changes what the team screen
          says about somebody without changing what they may do, and the two
          drifting apart is exactly what SchoolRoles exists to prevent.

          It is left out because doing it properly means a second cross-database
          write with the same partial-failure shape as the invite, and getting
          that wrong would leave a person holding two roles at once — which is
          worse than holding an old one. Recorded, not hidden.
        */
        var result = await _team
            .SaveRoleAsync(schoolId, caller.GetUserUid(), targetUserUid, request, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();
    }

    public async Task SaveBranchesAsync(
        Guid targetUserUid, SaveTeamMemberBranchesRequest request, ClaimsPrincipal caller,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        var result = await _team
            .SaveBranchesAsync(schoolId, caller.GetUserUid(), targetUserUid, request.BranchIds ?? [],
                caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();
    }

    /// <summary>
    /// Removes somebody's access, then kills their sessions.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 THE ORDER IS THE SAFETY. The membership goes inactive first, because
    /// that is the authoritative gate: <c>fn_IsSchoolMember</c> and
    /// <c>fn_VisibleBranches</c> both require it, so every school endpoint
    /// refuses them from that moment whether or not the second step works.
    /// </para>
    /// <para>
    /// ⚠️ The token revocation is therefore NOT fatal. Without it they keep a
    /// signed JWT until it expires — and every request it authenticates is
    /// refused anyway. Logged as a warning so it is visible, not raised as an
    /// error that would tell the school the removal failed when it did not.
    /// </para>
    /// </remarks>
    public async Task DeactivateAsync(
        Guid targetUserUid, ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        var organizationUid = caller.RequireOrganizationUid();
        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        var result = await _team
            .DeactivateAsync(schoolId, caller.GetUserUid(), targetUserUid, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();

        try
        {
            var (profile, _) = await _users.GetUserByUidAsync(targetUserUid, cancellationToken)
                .ConfigureAwait(false);

            // Belt and braces on a destructive cross-database write: jp_app has
            // already confirmed they are this school's member, and this confirms
            // the account is this organisation's before anything is revoked.
            if (profile is null || profile.OrganizationUid != organizationUid)
            {
                _logger.LogWarning(
                    "Removed {UserUid} from school {SchoolId}, but their jp_sso account could not be confirmed as " +
                    "belonging to organisation {OrganizationUid}. Sessions were NOT revoked; they expire on their own.",
                    targetUserUid, schoolId, organizationUid);

                return;
            }

            var revoked = await _tokens
                .RevokeAllUserTokensAsync(profile.UserId, null, caller.GetUserId(), cancellationToken)
                .ConfigureAwait(false);

            _logger.LogInformation(
                "Removed {UserUid} from school {SchoolId}. {Count} session token(s) revoked.",
                targetUserUid, schoolId, revoked.RevokedCount);
        }
        catch (Exception ex)
        {
            _logger.LogWarning(
                ex,
                "Removed {UserUid} from school {SchoolId}, but revoking their sessions threw. Their access is " +
                "already gone — every school endpoint checks the membership — and the token expires by itself.",
                targetUserUid, schoolId);
        }
    }

    /// <summary>
    /// The invitation email — who invited them, which school, and what they will
    /// be able to do.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 THIS IS THE FIRST THING A NEW HR PERSON SEES OF THIS PRODUCT.
    /// </para>
    /// <para>
    /// "You have been invited to join a workspace" tells somebody nothing they
    /// can act on, and reads like every phishing email they have been trained to
    /// delete. Four facts decide whether this link gets clicked, and all four
    /// are assembled here:
    /// </para>
    /// <list type="bullet">
    ///   <item>WHO invited them — by name, and by the address it came from</item>
    ///   <item>WHICH school — theirs, by name, never "an organisation"</item>
    ///   <item>WHAT they will be able to do — in the words of the job, not permission codes</item>
    ///   <item>WHICH campuses — because at a group, "the school" is ambiguous</item>
    /// </list>
    /// <para>
    /// ⚠️ The rationale lives here rather than in the template because HTML
    /// comments in a template are DELIVERED — the 3G verification found this
    /// note sitting in the recipient's mailbox, under the word "workspace".
    /// </para>
    /// <para>
    /// 🔴 The plaintext token appears here and nowhere else; only its hash was
    /// stored. That is the whole reason the link cannot be regenerated later and
    /// why the retry path cannot send a second one.
    /// </para>
    /// </remarks>
    private async Task QueueInvitationEmailAsync(
        InviteTeamMemberRequest request, SchoolProfileDto profile, ClaimsPrincipal caller,
        string email, string plainToken, IReadOnlyList<long> branchIds,
        CancellationToken cancellationToken)
    {
        try
        {
            var portal = _options.PortalBaseUrlFor((int)Core.Enums.UserType.School);
            var inviteUrl = $"{portal}/auth/accept-invite?token={Uri.EscapeDataString(plainToken)}";

            /*
              Who invited them. The name if the school has recorded one, and the
              address either way — "Priya Sharma (priya@…)" is checkable by
              somebody deciding whether this email is real, and a bare address is
              still better than "an administrator".

              ⚠️ Neither is in the JWT: the token carries ids, a type, a status
              and permissions, and no personal detail at all. So both are read
              here — the address from jp_sso, the name from the inviter's own
              membership row. Two extra queries on an operation a school performs
              a handful of times, in exchange for an email somebody will trust.
            */
            var inviterIdentity = await _users.GetIdentityAsync(caller.GetUserId(), cancellationToken)
                .ConfigureAwait(false);

            var team = await _team.GetTeamAsync(profile.SchoolId, caller.GetUserUid(), cancellationToken)
                .ConfigureAwait(false);

            var inviterName = team.Members
                .FirstOrDefault(m => m.UserUid == caller.GetUserUid())?.FullName;

            var inviterEmail = inviterIdentity?.Email ?? string.Empty;

            var inviterLine = string.IsNullOrWhiteSpace(inviterName)
                ? inviterEmail
                : $"{inviterName} ({inviterEmail})";

            var campusNames = profile.Branches
                .Where(b => branchIds.Contains(b.BranchId))
                .Select(b => b.BranchName)
                .ToList();

            /*
              ⚠️ A group school with named campuses gets a sentence about them;
              a single-campus school gets nothing, because "you will be able to
              see: Main Campus" is noise when there is only one.
            */
            var campusLine = profile.GroupType == 1 || campusNames.Count == 0
                ? string.Empty
                : campusNames.Count == profile.Branches.Count
                    ? " You will see every campus."
                    : $" You will see: {string.Join(", ", campusNames)}.";

            _email.Enqueue(new EmailDispatchRequest(
                TemplateName: "school-invite",
                Recipient: email,
                Subject: $"{profile.SchoolName} has added you to their hiring team",
                Tokens: new Dictionary<string, string>
                {
                    ["InviterLine"] = inviterLine,
                    ["SchoolName"] = profile.SchoolName,
                    ["RoleName"] = SchoolRoles.NameFor(request.RoleInSchool),
                    ["Capabilities"] = CapabilitiesFor(request.RoleInSchool),
                    ["CampusLine"] = campusLine,
                    ["InviteUrl"] = inviteUrl,
                    ["ValidityDays"] = _options.InviteValidityDays.ToString(CultureInfo.InvariantCulture),
                }));
        }
        catch (Exception ex)
        {
            _logger.LogWarning(
                ex,
                "{Email} was added to school {SchoolId} but their invitation email could not be queued. " +
                "They can still set a password through 'forgot password'.",
                email, profile.SchoolId);
        }
    }

    /// <summary>
    /// What the role means, in the words of the job rather than permission codes.
    /// </summary>
    /// <remarks>
    /// Somebody deciding whether to click a link in an email does not know what
    /// APPLICANT.SHORTLIST is, and should not have to.
    /// </remarks>
    private static string CapabilitiesFor(byte roleInSchool) => roleInSchool switch
    {
        SchoolRoles.SeniorHr =>
            "You will be able to post jobs, review everyone who applies, shortlist and reject, and make offers.",
        SchoolRoles.Hr =>
            "You will be able to post jobs, review everyone who applies, and shortlist or reject them.",
        SchoolRoles.Viewer =>
            "You will be able to see the school's jobs and the people who have applied, without making changes.",
        _ => "You will be able to see the school's jobs and applicants.",
    };
}
