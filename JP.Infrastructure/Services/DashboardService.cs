using System.Security.Claims;
using JP.Core.Enums;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Dashboards;
using JP.Domain.Schools;
using JP.Infrastructure.Repositories;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Services;

public interface IDashboardService
{
    Task<SchoolDashboardDto> GetSchoolAsync(ClaimsPrincipal caller, CancellationToken cancellationToken);

    Task<TeacherDashboardDto> GetTeacherAsync(ClaimsPrincipal caller, CancellationToken cancellationToken);
}

/// <summary>
/// The two dashboards, composed from what already exists.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 THIS SERVICE ADDS ONE READ AND REUSES EVERYTHING ELSE.
/// </para>
/// <para>
/// The school's profile (2.57), its team (2.58) and the teacher's profile
/// (2.60) already return every tile on both screens except the plan, so those
/// are called rather than reimplemented — one place decides what a school's
/// verified badge means, and it is not here.
/// </para>
/// <para>
/// The plan is the one genuinely missing piece, and it needs both databases:
/// the subscription is in jp_app and the plan's name is in jp_mdm, which cannot
/// join (2.2). Composing it server-side costs one round trip instead of three
/// from the browser, and keeps "which Uid owns a subscription" — the
/// organisation for a school, the user for a teacher — in one place.
/// </para>
/// <para>
/// ⚠️ THERE IS NO JOB OR APPLICATION COUNT, deliberately. Those tables arrive in
/// Phases 4 and 5. A zero would be a measurement of something unmeasurable, and
/// a number would be the mockup this phase deleted (G6).
/// </para>
/// </remarks>
internal sealed class DashboardService : IDashboardService
{
    /// <summary>How many colleagues the dashboard shows before sending you to the team screen.</summary>
    private const int TeamPreviewSize = 4;

    /// <summary>m_sso_user_status. Active — the "they have arrived" check is last-login, not this.</summary>
    private const int UserStatusActive = 2;

    private readonly ISchoolProfileService _schools;
    private readonly ISchoolTeamService _team;
    private readonly ITeacherProfileService _teachers;
    private readonly ISubscriptionRepository _subscriptions;
    private readonly IPlanRepository _plans;
    private readonly IMasterService _masters;
    private readonly ILogger<DashboardService> _logger;

    public DashboardService(
        ISchoolProfileService schools,
        ISchoolTeamService team,
        ITeacherProfileService teachers,
        ISubscriptionRepository subscriptions,
        IPlanRepository plans,
        IMasterService masters,
        ILogger<DashboardService> logger)
    {
        _schools = schools;
        _team = team;
        _teachers = teachers;
        _subscriptions = subscriptions;
        _plans = plans;
        _masters = masters;
        _logger = logger;
    }

    public async Task<SchoolDashboardDto> GetSchoolAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        // Both of these resolve the school from the caller's membership and
        // refuse a non-school account with a message written for them (2.57).
        var profile = await _schools.GetProfileAsync(caller, cancellationToken).ConfigureAwait(false);
        var team = await _team.GetTeamAsync(caller, cancellationToken).ConfigureAwait(false);

        /*
          🔴 The subscription is owned by the ORGANISATION for a school (2.51),
          and the organisation comes from the token — never from a request.
        */
        var plan = await GetPlanAsync(caller.RequireOrganizationUid(), cancellationToken)
            .ConfigureAwait(false);

        var head = profile.Branches.FirstOrDefault(b => b.IsHeadOffice);

        return new SchoolDashboardDto
        {
            SchoolName = profile.SchoolName,
            IsVerified = profile.IsVerified,
            IsSuspended = profile.IsSuspended,
            GroupType = profile.GroupType,
            BranchCount = profile.BranchCount,

            HeadOffice = head is null
                ? null
                : new DashboardCampusDto
                {
                    BranchId = head.BranchId,
                    BranchName = head.BranchName,
                    Location = await LocationOfAsync(head, cancellationToken).ConfigureAwait(false),
                },

            Plan = plan,

            TeamMemberCount = team.Members.Count(m => m.IsActive),

            Team = team.Members
                .Where(m => m.IsActive)
                // Owner first, then whoever joined most recently — the order
                // somebody scans a team in.
                .OrderByDescending(m => m.IsOwner)
                .ThenByDescending(m => m.CreatedOnUtc)
                .Take(TeamPreviewSize)
                .Select(m => new DashboardTeamMemberDto
                {
                    UserUid = m.UserUid,
                    FullName = m.FullName,
                    Email = m.Email,
                    RoleName = m.RoleName,
                    IsOwner = m.IsOwner,

                    // ⚠️ NOT the account status. An invited account is created
                    // ACTIVE with no credential (2.58), so status cannot tell an
                    // arrived colleague from one who never opened the email. A
                    // null last-login can.
                    HasArrived = m.LastLoginOnUtc is not null,
                })
                .ToList(),
        };
    }

    public async Task<TeacherDashboardDto> GetTeacherAsync(
        ClaimsPrincipal caller, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(caller);

        if (caller.GetUserType() != UserType.Teacher)
        {
            // The same lesson as 3E: refuse for the right reason. A school
            // reaching this would otherwise fall through to "no profile found",
            // which is written for a teacher and nonsense for them.
            throw new ForbiddenException("This is a teacher area. Your account is not a teacher account.");
        }

        var profile = await _teachers.GetProfileAsync(caller, cancellationToken).ConfigureAwait(false);

        // 🔴 A teacher's subscription is owned by the USER, not an organisation
        // — teachers belong to none (2.51).
        var plan = await GetPlanAsync(caller.GetUserUid(), cancellationToken).ConfigureAwait(false);

        return new TeacherDashboardDto
        {
            FullName = profile.FullName,
            IsVerified = profile.IsVerified,
            VerifiedOnUtc = profile.VerifiedOn,
            IsSuspended = profile.IsSuspended,

            ProfileCompletionPercent = profile.ProfileCompletionPercent,
            HasResume = !string.IsNullOrWhiteSpace(profile.ResumePath),

            SubjectCount = profile.SubjectIds.Count,
            ExperienceCount = profile.Experiences.Count,
            TotalExperienceMonths = profile.TotalExperienceMonths,

            DocumentCount = profile.Documents.Count,
            VerifiedDocumentCount = profile.Documents.Count(d => d.IsVerified),

            Plan = plan,
        };
    }

    /// <summary>
    /// The plan, read across two databases.
    /// </summary>
    /// <remarks>
    /// ⚠️ NO SUBSCRIPTION IS A STATE, NOT A FAILURE. It returns
    /// <c>HasSubscription = false</c> and the screen says "no plan on file"
    /// rather than breaking — which is the honest rendering of an account 3B's
    /// repair could have left without one.
    /// </remarks>
    private async Task<PlanSummaryDto> GetPlanAsync(Guid ownerUid, CancellationToken cancellationToken)
    {
        var subscription = await _subscriptions.GetCurrentAsync(ownerUid, cancellationToken)
            .ConfigureAwait(false);

        if (subscription is null)
        {
            _logger.LogWarning(
                "Owner {OwnerUid} has no subscription row. The dashboard will say so; provisioning is " +
                "supposed to create one for every account (2.52).",
                ownerUid);

            return new PlanSummaryDto { HasSubscription = false };
        }

        // The name lives in jp_mdm. This is the join no query may write (2.2).
        var plan = await _plans.GetByIdAsync(subscription.PlanId, cancellationToken).ConfigureAwait(false);

        if (plan is null)
        {
            _logger.LogError(
                "Subscription {SubscriptionId} points at plan {PlanId}, which does not exist in jp_mdm. " +
                "The dashboard will show the subscription without a name.",
                subscription.SubscriptionId, subscription.PlanId);
        }

        return new PlanSummaryDto
        {
            HasSubscription = true,
            PlanName = plan?.Name,
            PlanCode = plan?.PlanCode,
            Price = plan?.Price,
            StartsOnUtc = subscription.StartsOn,
            EndsOnUtc = subscription.EndsOn,

            // 🔴 Only correct because the procedure aliases Is_Active (2.61).
            IsActive = subscription.IsActive,
        };
    }

    /// <summary>
    /// Where a campus is, in words.
    /// </summary>
    /// <remarks>
    /// 🔴 THE STATE, NOT THE CITY — and that is not a shortcut. The city dataset
    /// has not been imported (2.47), so every school's CityId is null and
    /// resolving one would print nothing. This reads the state master and falls
    /// back to the PIN code, so the tile always says something true.
    /// </remarks>
    private async Task<string?> LocationOfAsync(BranchDto branch, CancellationToken cancellationToken)
    {
        var parts = new List<string>();

        if (branch.StateId is { } stateId)
        {
            var states = await _masters.GetAsync("STATE", null, cancellationToken).ConfigureAwait(false);
            var state = states.FirstOrDefault(s => s.Id == stateId);

            if (state is not null)
            {
                parts.Add(state.Name);
            }
        }

        if (!string.IsNullOrWhiteSpace(branch.Pincode))
        {
            parts.Add(branch.Pincode);
        }

        return parts.Count == 0 ? null : string.Join(" · ", parts);
    }
}
