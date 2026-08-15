using JP.Core.Constants;

namespace JP.Domain.Schools;

/*==============================================================================
  🔴 THE ONE PLACE RoleInSchool AND A ROLE CODE ARE TIED TOGETHER
==============================================================================*/

/// <summary>
/// The four things somebody can be to a school, and the jp_sso role that goes
/// with each.
/// </summary>
/// <remarks>
/// <para>
/// Two databases describe this person and they must not drift. jp_app's
/// <c>RoleInSchool</c> says what they ARE to the school — it drives the team
/// screen and who a job's notifications reach. jp_sso's role says what they may
/// DO, through its permissions. A Senior HR whose account was left on the
/// SCHOOL_VIEWER role is a person the team screen calls senior and the API
/// refuses at every turn.
/// </para>
/// <para>
/// 🔴 So the mapping lives here, once, and both writes read it. The API layer is
/// the only place it can live: no query may join the two databases (2.2), so
/// there is no constraint either side could enforce.
/// </para>
/// <para>
/// ⚠️ Owner is in the map because it is a real value that comes BACK from the
/// database. Nothing in this system may write it — see the rules in
/// <c>011_school_team.sql</c>.
/// </para>
/// </remarks>
public static class SchoolRoles
{
    public const byte Owner = 1;
    public const byte SeniorHr = 2;
    public const byte Hr = 3;
    public const byte Viewer = 4;

    /// <summary>The jp_sso role code that carries the permissions for a role.</summary>
    public static string? CodeFor(byte roleInSchool) => roleInSchool switch
    {
        Owner => AppConstants.RoleCodes.SchoolOwner,
        SeniorHr => AppConstants.RoleCodes.SeniorHr,
        Hr => AppConstants.RoleCodes.Hr,
        Viewer => AppConstants.RoleCodes.SchoolViewer,
        _ => null,
    };

    /// <summary>What a person is called on the screen.</summary>
    public static string NameFor(byte roleInSchool) => roleInSchool switch
    {
        Owner => "Owner",
        SeniorHr => "Senior HR",
        Hr => "HR",
        Viewer => "Viewer",
        _ => "Unknown",
    };

    /// <summary>
    /// Whether this is a role somebody may be given.
    /// </summary>
    /// <remarks>
    /// 🔴 Owner is excluded. A school has exactly one, it can never be demoted
    /// or deactivated (rule 1), and so granting a second one is permanent —
    /// two people who can never be removed from a school neither may still work
    /// at. Ownership moves; it does not accumulate. The procedures refuse this
    /// as well; this is here so the refusal does not need a round trip.
    /// </remarks>
    public static bool IsAssignable(byte roleInSchool) =>
        roleInSchool is SeniorHr or Hr or Viewer;
}

/*==============================================================================
  RESPONSES
==============================================================================*/

/// <summary>
/// A school's team: who is on it, what they can reach, and the campuses to
/// choose from.
/// </summary>
/// <remarks>
/// The campuses ride along rather than being a second call, because the branch
/// matrix is meaningless without them and the two must describe the same scope
/// — both are the CALLER's visible set, resolved by the same function.
/// </remarks>
public sealed record SchoolTeamDto
{
    /// <summary>
    /// 1 = a single campus, 2 = a group.
    /// </summary>
    /// <remarks>
    /// ⚠️ At 1 the whole campus-scope control disappears (decision 2.50). There
    /// is one campus, so "which campuses may they see" is a question with one
    /// answer, and asking it makes a simple school look like a complicated one.
    /// </remarks>
    public byte? GroupType { get; init; }

    public IReadOnlyList<TeamCampusDto> Campuses { get; init; } = [];

    public IReadOnlyList<SchoolTeamMemberDto> Members { get; init; } = [];
}

/// <summary>A campus, as the scope matrix needs it. Nothing else.</summary>
public sealed record TeamCampusDto
{
    public long BranchId { get; init; }
    public string BranchName { get; init; } = string.Empty;
    public bool IsHeadOffice { get; init; }
}

/// <summary>
/// One person on the team — half from jp_app, half from jp_sso.
/// </summary>
/// <remarks>
/// <para>
/// FullName, DesignationText, RoleInSchool and the campuses come from the
/// membership. Email and the account status come from jp_sso, joined in the
/// service because no query may join them (2.2).
/// </para>
/// <para>
/// ⚠️ FullName is nullable and often null: every membership provisioning
/// created has no name, because provisioning never had one and inventing one
/// was refused. The UI falls back to the email.
/// </para>
/// </remarks>
public sealed record SchoolTeamMemberDto
{
    public Guid UserUid { get; init; }

    public string? FullName { get; init; }

    /// <summary>Their sign-in address. The fallback identity when FullName is null.</summary>
    public string Email { get; init; } = string.Empty;

    public string? DesignationText { get; init; }

    public byte RoleInSchool { get; init; }
    public string RoleName { get; init; } = string.Empty;

    /// <summary>Owner: implicitly every campus, and not editable (rules 1 and 3).</summary>
    public bool IsOwner { get; init; }

    /// <summary>False once their access has been removed. The row stays; the access does not.</summary>
    public bool IsActive { get; init; }

    /// <summary>
    /// The account's own state in jp_sso — 2 is Active, 1 is still Pending.
    /// </summary>
    /// <remarks>
    /// An invited colleague who has not yet set a password is Pending, and the
    /// screen says "Invited" rather than showing them as a working account.
    /// </remarks>
    public int AccountStatusId { get; init; }

    public string AccountStatusCode { get; init; } = string.Empty;

    /// <summary>
    /// The campuses this person is scoped to, AS THE CALLER CAN SEE THEM.
    /// </summary>
    /// <remarks>
    /// 🔴 Filtered through the caller's own scope, so an HR at one campus does
    /// not learn the ids of campuses they were never given.
    /// </remarks>
    public IReadOnlyList<long> BranchIds { get; init; } = [];

    /// <summary>
    /// The TRUE number of campuses they are scoped to, filtered by nothing.
    /// </summary>
    /// <remarks>
    /// ⚠️ Deliberately allowed to exceed <see cref="BranchIds"/>. The screen
    /// says "1 campus, and 2 more you cannot see" rather than under-reporting a
    /// colleague's access, which would be a lie told with a straight face.
    /// </remarks>
    public int BranchCount { get; init; }

    public DateTime? LastLoginOnUtc { get; init; }
    public DateTime CreatedOnUtc { get; init; }
}

/// <summary>What an invitation produced.</summary>
public sealed record InviteTeamMemberResponse
{
    public Guid UserUid { get; init; }
    public string Email { get; init; } = string.Empty;
    public DateTime? InviteExpiresOnUtc { get; init; }

    /// <summary>
    /// True when that person was already on the team and nothing was created.
    /// </summary>
    /// <remarks>
    /// Not an error: re-inviting somebody is a reasonable thing to do when you
    /// cannot remember whether you already did. The screen says so instead of
    /// claiming an invitation went out.
    /// </remarks>
    public bool AlreadyOnTeam { get; init; }

    /// <summary>
    /// True when the account already existed and this attached it to the team.
    /// </summary>
    /// <remarks>
    /// ⚠️ This is the retry path for an invitation whose second half failed —
    /// the account was created in jp_sso and the membership never landed. No new
    /// invitation email goes out in that case, because the first one is still
    /// valid.
    /// </remarks>
    public bool ExistingAccountAttached { get; init; }
}

/*==============================================================================
  REQUESTS

  🔴 Not one of these carries a SchoolId or an OrganizationUid. Both come from
  the caller's token and their membership (2.39). A request that could name its
  own school could name somebody else's — and this is the endpoint set where
  that would hand over another school's team.
==============================================================================*/

public sealed record InviteTeamMemberRequest
{
    public string Email { get; init; } = string.Empty;

    /// <summary>
    /// What this person is called. Optional, and worth asking for.
    /// </summary>
    /// <remarks>
    /// The team list falls back to the email without it, and a list of email
    /// addresses is a list nobody can read.
    /// </remarks>
    public string? FullName { get; init; }

    public string? Mobile { get; init; }

    /// <summary>2 Senior HR · 3 HR · 4 Viewer. 🔴 Never 1 — see <see cref="SchoolRoles"/>.</summary>
    public byte RoleInSchool { get; init; }

    public string? DesignationText { get; init; }

    /// <summary>
    /// The campuses they will be able to see.
    /// </summary>
    /// <remarks>
    /// ⚠️ Empty means none, and that is a person who signs in and sees an empty
    /// school. Allowed — somebody may be added before their campus exists — but
    /// the screen warns before it saves.
    /// </remarks>
    public IReadOnlyList<long> BranchIds { get; init; } = [];
}

public sealed record SaveTeamMemberRoleRequest
{
    public byte RoleInSchool { get; init; }
    public string? FullName { get; init; }
    public string? DesignationText { get; init; }
}

/// <remarks>
/// ⚠️ FULL SET, NOT A DELTA — the same contract as every other bridge in this
/// API (2.53). Sending <c>[3]</c> when they have <c>[1, 3]</c> removes 1.
///
/// 🔴 With one exception that only applies to a caller who is not the owner:
/// campuses the CALLER cannot see are never removed, whatever this list says.
/// See the header of USP_SaveSchoolUserBranches.
/// </remarks>
public sealed record SaveTeamMemberBranchesRequest
{
    public IReadOnlyList<long> BranchIds { get; init; } = [];
}
