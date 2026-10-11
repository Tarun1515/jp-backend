using System.Net;
using System.Security.Claims;
using JP.Core.Constants;
using JP.Core.Enums;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Invites;
using JP.Domain.Teachers;
using JP.Infrastructure.Repositories;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Services;

/// <summary>Teacher search and invitations. Phase 6B.</summary>
/// <remarks>
/// <para>
/// 🔴 THIS CLASS IS WHERE THE ENTITLEMENT ENGINE MEETS ITS FIRST TWO REAL
/// CONSUMERS OF EITHER MODE.
/// </para>
/// <para>
/// TEACHER_SEARCH is the engine's first BOOLEAN consumer: included or not, and
/// it writes nothing to the ledger — not even on success. TEACHER_INVITE is
/// METERED, referenced by the invitation's own Uid so a retry resolves to
/// ALREADY_CONSUMED instead of charging twice.
/// </para>
/// <para>
/// ⚠️ EVERY GATING READ HERE GOES THROUGH <see cref="IEntitlementRepository"/>,
/// never <c>IMasterService</c> (2.64). The masters are cached for an hour,
/// which is correct for subjects and boards and catastrophic for a kill switch:
/// a feature switched off would keep working for up to an hour, on an unknown
/// number of instances. The same rule the job publish follows.
/// </para>
/// <para>
/// 🔒 AND NONE OF IT TOUCHES CONTACT. A plan buys the capability to search and
/// to invite. It has never bought, and must never buy, a teacher's phone
/// number — 2.56 is LOCKED on exactly that sentence. The search projection has
/// no contact column in the SQL, the DTO is guarded at startup, and this class
/// never calls the contact read.
/// </para>
/// </remarks>
public interface IInviteService
{
    Task<(IReadOnlyList<TeacherSearchResultDto> Rows, long Total)> SearchAsync(
        ClaimsPrincipal caller, TeacherSearchFilter filter, CancellationToken cancellationToken);

    Task<SendInviteResultDto> SendAsync(
        ClaimsPrincipal caller, SendInviteRequest request, CancellationToken cancellationToken);

    Task<IReadOnlyList<SchoolInviteDto>> GetForSchoolAsync(
        ClaimsPrincipal caller, int? inviteStatusId, CancellationToken cancellationToken);

    Task<IReadOnlyList<MyInviteDto>> GetMineAsync(
        ClaimsPrincipal caller, bool openOnly, CancellationToken cancellationToken);

    Task MarkViewedAsync(ClaimsPrincipal caller, long inviteId, CancellationToken cancellationToken);

    Task RespondAsync(
        ClaimsPrincipal caller, long inviteId, RespondToInviteRequest request,
        CancellationToken cancellationToken);
}

internal sealed class InviteService : IInviteService
{
    private const string SearchFeature = "TEACHER_SEARCH";
    private const string InviteFeature = "TEACHER_INVITE";

    private readonly IInviteRepository _invites;
    private readonly ISchoolProfileService _schools;
    private readonly IEntitlementRepository _catalog;
    private readonly ISubscriptionRepository _subscriptions;
    private readonly ILogger<InviteService> _logger;

    public InviteService(
        IInviteRepository invites,
        ISchoolProfileService schools,
        IEntitlementRepository catalog,
        ISubscriptionRepository subscriptions,
        ILogger<InviteService> logger)
    {
        _invites = invites;
        _schools = schools;
        _catalog = catalog;
        _subscriptions = subscriptions;
        _logger = logger;
    }

    // ---- search -------------------------------------------------------------

    /// <summary>
    /// 🔒 Find teachers. Gated on TEACHER_SEARCH, and it returns no contact
    /// details for anybody, under any plan.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 THE BOOLEAN GATE IS A READ, NOT A PURCHASE. There is nothing to
    /// charge for a search, so the engine's Boolean mode answers "included or
    /// not" and writes nothing — see 013. That is also why this method does not
    /// go through the consume procedure at all: the decision is a resolution,
    /// and inventing a ledger row to represent a search would bury every row
    /// that actually changes a balance.
    /// </para>
    /// <para>
    /// ⚠️ THE CHECK IS STILL CENTRALISED. The mode and the mapping come from
    /// the entitlement catalogue — the same resolution the consume path uses —
    /// rather than from a flag on a screen or a role. One place decides
    /// entitlement, even when the answer costs nothing.
    /// </para>
    /// </remarks>
    public async Task<(IReadOnlyList<TeacherSearchResultDto> Rows, long Total)> SearchAsync(
        ClaimsPrincipal caller, TeacherSearchFilter filter, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(filter);

        Require(caller, AppConstants.PermissionCodes.TeacherSearchView);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);
        var ownerUid = caller.RequireOrganizationUid();

        await RequireFeatureAsync(ownerUid, SearchFeature, cancellationToken).ConfigureAwait(false);

        return await _invites.SearchTeachersAsync(schoolId, filter, cancellationToken).ConfigureAwait(false);
    }

    // ---- invites ------------------------------------------------------------

    public async Task<SendInviteResultDto> SendAsync(
        ClaimsPrincipal caller, SendInviteRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        Require(caller, AppConstants.PermissionCodes.TeacherInviteSend);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        // 🔴 The subscription's owner for a school is the ORGANISATION (2.51).
        var ownerUid = caller.RequireOrganizationUid();

        /*
          ⚠️ THE RETRY IS FOR PLAN_CHANGED ONLY, exactly as on publish. The
          gating read happens outside the procedure's transaction, so a plan
          edited in between is possible; the procedure detects it and this
          re-resolves once rather than charging against a plan nobody is on.
        */
        for (var attempt = 1; ; attempt++)
        {
            var resolution = await ResolveAsync(ownerUid, InviteFeature, cancellationToken)
                .ConfigureAwait(false);

            var row = await _invites.SendAsync(
                schoolId, caller.GetUserUid(), request, ownerUid,
                resolution.Resolution.FeatureId, (byte)resolution.Resolution.GatingModeId,
                (byte)(resolution.Resolution.HasMapping ? 1 : 0),
                (byte)(resolution.Resolution.IsIncluded ? 1 : 0),
                resolution.Resolution.QuotaPerPeriod, resolution.PlanId,
                caller.GetUserId(), cancellationToken).ConfigureAwait(false);

            if (row.Code == ErrorCodes.PlanChanged && attempt < 2)
            {
                _logger.LogInformation(
                    "Invite send re-resolving after a plan change for organisation {OwnerUid}.", ownerUid);

                continue;
            }

            if (!row.Succeeded)
            {
                throw ProcResultExtensions.ToException(row.Code, row.Message);
            }

            /*
              ⚠️ ALREADY_INVITED and ALREADY_CONSUMED both arrive on a SUCCESS,
              and they mean different things: the first is "an invitation is
              already waiting with this teacher", the second is "this exact
              invitation was already counted". Neither is an error and neither
              charged anything.
            */
            return new SendInviteResultDto
            {
                InviteId = row.Id ?? 0,
                Code = row.Code,
                Created = row.Code is null,
                Consumed = row.Consumed == 1,
                Source = row.SourceId,
            };
        }
    }

    public async Task<IReadOnlyList<SchoolInviteDto>> GetForSchoolAsync(
        ClaimsPrincipal caller, int? inviteStatusId, CancellationToken cancellationToken)
    {
        /*
          ⚠️ TEACHER_SEARCH.VIEW, not the invite permission. Reading the outbox
          is part of looking at the recruitment side; sending is the act that
          costs and that is gated separately.

          🔴 AND NO ENTITLEMENT CHECK. A school whose plan stopped including
          search must still be able to see the invitations it already sent —
          hiding its own history would be using entitlement to erase a record,
          which is not what a plan sells.
        */
        Require(caller, AppConstants.PermissionCodes.TeacherSearchView);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        return await _invites
            .GetForSchoolAsync(schoolId, caller.GetUserUid(), inviteStatusId, cancellationToken)
            .ConfigureAwait(false);
    }

    // ---- the teacher's side -------------------------------------------------

    public async Task<IReadOnlyList<MyInviteDto>> GetMineAsync(
        ClaimsPrincipal caller, bool openOnly, CancellationToken cancellationToken)
    {
        RequireTeacher(caller);

        return await _invites.GetMineAsync(caller.GetUserUid(), openOnly, cancellationToken)
            .ConfigureAwait(false);
    }

    /// <summary>
    /// The teacher opened it.
    /// </summary>
    /// <remarks>
    /// 🔒 UNLOCKS NOTHING. Reading a message is not answering it — the whole
    /// difference between Viewed and Accepted, and the reason
    /// <c>fn_TeacherContactUnlocked</c> names one id and not two.
    /// </remarks>
    public async Task MarkViewedAsync(
        ClaimsPrincipal caller, long inviteId, CancellationToken cancellationToken)
    {
        RequireTeacher(caller);

        var result = await _invites.MarkViewedAsync(caller.GetUserUid(), inviteId, cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();
    }

    /// <summary>
    /// 🔒 The teacher accepts or passes. ACCEPTING IS CONSENT PATH 2 (2.56).
    /// </summary>
    public async Task RespondAsync(
        ClaimsPrincipal caller, long inviteId, RespondToInviteRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        RequireTeacher(caller);

        /*
          🔴 THE TEACHER IS THE TOKEN, not a parameter. The procedure matches
          the invitation on the caller's own UserUid, so another teacher's
          invite id resolves to nothing and answers NOT_FOUND rather than
          confirming it exists (2.6).
        */
        var result = await _invites.RespondAsync(
            caller.GetUserUid(), inviteId, request.Accept, request.TeacherRemarks,
            caller.GetUserId(), cancellationToken).ConfigureAwait(false);

        result.EnsureSuccess();
    }

    // ---- entitlement --------------------------------------------------------

    /// <summary>
    /// Resolve a feature for this owner's current plan.
    /// </summary>
    /// <remarks>
    /// 🔴 <see cref="IEntitlementRepository"/>, NEVER <c>IMasterService</c>
    /// (2.64). The master cache is an hour deep; a kill switch that takes an
    /// hour to land is not a switch.
    /// </remarks>
    private async Task<(EntitlementResolution Resolution, int PlanId)> ResolveAsync(
        Guid ownerUid, string featureCode, CancellationToken cancellationToken)
    {
        var subscription = await _subscriptions.GetCurrentAsync(ownerUid, cancellationToken)
            .ConfigureAwait(false);

        if (subscription is null)
        {
            // Every account holds a plan from the moment it exists (2F, G21).
            // No row means provisioning is broken, not that this school is in a
            // normal state.
            _logger.LogError(
                "ENTITLEMENT INTEGRITY: organisation {OwnerUid} has no subscription row; "
                + "cannot resolve {FeatureCode}.", ownerUid, featureCode);

            throw new AppException(
                "This account has no subscription on file. Please contact support.",
                ErrorCodes.SubscriptionMissing, HttpStatusCode.Forbidden);
        }

        var resolution = await _catalog
            .ResolveAsync(featureCode, subscription.PlanId, cancellationToken).ConfigureAwait(false);

        if (resolution is null || !resolution.IsActive)
        {
            _logger.LogInformation(
                "{FeatureCode} is unavailable (missing or switched off) for organisation {OwnerUid}.",
                featureCode, ownerUid);

            throw new AppException(
                "That feature is currently switched off.",
                ErrorCodes.FeatureDisabled, HttpStatusCode.Forbidden);
        }

        return (resolution, subscription.PlanId);
    }

    /// <summary>
    /// A read-only gate for a feature that costs nothing to use.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 THE BOOLEAN RULE, IN ONE PLACE: a mapping that exists AND includes
    /// the feature is a yes; anything else is a no. A MISSING mapping is a NO —
    /// absence of a row is absence of a decision, and reading "nobody said
    /// anything" as "yes" grants capability nobody sold (013's header).
    /// </para>
    /// <para>
    /// ⚠️ FREE short-circuits before the mapping is consulted, because in FREE
    /// mode the mode IS the grant. That is why TEACHER_SEARCH works today with
    /// no plan mapping at all, and why flipping it to Boolean changes the
    /// answer immediately.
    /// </para>
    /// </remarks>
    private async Task RequireFeatureAsync(
        Guid ownerUid, string featureCode, CancellationToken cancellationToken)
    {
        var (resolution, _) = await ResolveAsync(ownerUid, featureCode, cancellationToken)
            .ConfigureAwait(false);

        // FREE (1): the mode is the grant.
        if (resolution.GatingModeId == 1)
        {
            return;
        }

        if (resolution.HasMapping && resolution.IsIncluded)
        {
            return;
        }

        _logger.LogInformation(
            "{FeatureCode} is not included in the plan for organisation {OwnerUid}; refusing.",
            featureCode, ownerUid);

        throw new AppException(
            "Your plan does not include this.",
            ErrorCodes.PlanLacksFeature, HttpStatusCode.Forbidden);
    }

    // ---- guards -------------------------------------------------------------

    private static void Require(ClaimsPrincipal caller, string permission)
    {
        if (!caller.HasPermission(permission))
        {
            throw new ForbiddenException("You do not have permission to do that.");
        }
    }

    /// <summary>
    /// ⚠️ THE TYPE BEFORE THE PROFILE, so the refusal is honest (3E's lesson).
    /// </summary>
    private static void RequireTeacher(ClaimsPrincipal caller)
    {
        if (caller.GetUserType() != UserType.Teacher)
        {
            throw new ForbiddenException("This is a teacher area. Your account is not a teacher account.");
        }
    }
}
