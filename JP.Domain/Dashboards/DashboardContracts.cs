namespace JP.Domain.Dashboards;

/*==============================================================================
  WHAT A DASHBOARD IS ALLOWED TO SAY

  🔴 THERE IS NO JOB COUNT AND NO APPLICATION COUNT IN THIS FILE, AND THAT IS
  THE POINT OF PHASE 3I.

  Jobs are Phase 4 and applications are Phase 5. Neither table exists. A tile
  showing "0 open jobs" would be a measurement of something that cannot be
  measured, and a tile showing 12 would be the mockup these types replaced
  (G6). The screens render an empty state describing what the section WILL be,
  and this contract has nowhere to put a number that would make that a lie.

  ⚠️ When Phase 4 lands, adding counts here is a deliberate act — not a field
  that quietly starts being populated.
==============================================================================*/

/// <summary>The plan an account is on, joined across two databases.</summary>
/// <remarks>
/// The subscription lives in jp_app and the plan in jp_mdm; neither can join to
/// the other (2.2), so the API reads both and puts them together here.
///
/// ⚠️ Every field is nullable-ish on purpose: an account with NO subscription is
/// a real state, and the screen says so rather than crashing. 3B found seven
/// organisations holding a plan they should not have had, and the repair left
/// exactly this possibility behind.
/// </remarks>
public sealed record PlanSummaryDto
{
    /// <summary>False when the account has no subscription row at all.</summary>
    public bool HasSubscription { get; init; }

    public string? PlanName { get; init; }
    public string? PlanCode { get; init; }
    public decimal? Price { get; init; }

    /// <summary>Null means it does not expire — which is what both free plans are.</summary>
    public DateTime? EndsOnUtc { get; init; }

    public DateTime? StartsOnUtc { get; init; }

    /// <summary>
    /// 🔴 Reaches this DTO only because the procedure aliases
    /// <c>Is_Active AS IsActive</c> (2.61). Without the alias it is silently
    /// false and the screen reports a live plan as lapsed.
    /// </summary>
    public bool IsActive { get; init; }
}

/// <summary>The school's dashboard: only what exists today.</summary>
public sealed record SchoolDashboardDto
{
    public string SchoolName { get; init; } = string.Empty;
    public bool IsVerified { get; init; }
    public bool IsSuspended { get; init; }

    /// <summary>1 = a single campus, 2 = a group. Null when never declared (2.10).</summary>
    public byte? GroupType { get; init; }

    public int BranchCount { get; init; }

    /// <summary>The head office, which every school has by construction (2.51).</summary>
    public DashboardCampusDto? HeadOffice { get; init; }

    public PlanSummaryDto Plan { get; init; } = new();

    public int TeamMemberCount { get; init; }

    /// <summary>
    /// A few colleagues, most recent first — enough to recognise the team.
    /// </summary>
    /// <remarks>
    /// ⚠️ Deliberately a SHORT list. The dashboard is not the team screen; it is
    /// the reason to visit it.
    /// </remarks>
    public IReadOnlyList<DashboardTeamMemberDto> Team { get; init; } = [];
}

public sealed record DashboardCampusDto
{
    public long BranchId { get; init; }
    public string BranchName { get; init; } = string.Empty;

    /// <summary>
    /// Where it is, in words the screen can print.
    /// </summary>
    /// <remarks>
    /// ⚠️ Resolved by the API from the state master, because the CITY dataset
    /// has not been imported (2.47) and a city id would resolve to nothing.
    /// Null when the school never recorded a state.
    /// </remarks>
    public string? Location { get; init; }
}

public sealed record DashboardTeamMemberDto
{
    public Guid UserUid { get; init; }
    public string? FullName { get; init; }
    public string Email { get; init; } = string.Empty;
    public string RoleName { get; init; } = string.Empty;
    public bool IsOwner { get; init; }

    /// <summary>False until they have signed in at least once — the "Invited" state (2.58).</summary>
    public bool HasArrived { get; init; }
}

/// <summary>The teacher's dashboard.</summary>
/// <remarks>
/// 🔴 The completeness NUMBER is here; the wording around it is not. The screen
/// reuses the meter built in 3H, which names one next step and never prints
/// "0%" as a verdict (2.60). A second completeness display would be a second
/// rule to keep in step, and the day they disagree one of them is wrong.
/// </remarks>
public sealed record TeacherDashboardDto
{
    public string FullName { get; init; } = string.Empty;

    /// <summary>
    /// ⚠️ A BADGE, NOT A GATE (2.9). A teacher's account is Active from signup
    /// and everything works unverified; this only says whether the badge is on.
    /// </summary>
    public bool IsVerified { get; init; }

    public DateTime? VerifiedOnUtc { get; init; }
    public bool IsSuspended { get; init; }

    public byte ProfileCompletionPercent { get; init; }

    /// <summary>True once a resume is on file — the thing that lifts the 75% cap.</summary>
    public bool HasResume { get; init; }

    public int SubjectCount { get; init; }
    public int ExperienceCount { get; init; }

    /// <summary>Derived server-side and never computed by a client (2.54).</summary>
    public int? TotalExperienceMonths { get; init; }

    public int DocumentCount { get; init; }
    public int VerifiedDocumentCount { get; init; }

    public PlanSummaryDto Plan { get; init; } = new();
}
