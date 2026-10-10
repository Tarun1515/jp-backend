using System.Security.Claims;
using JP.Core.Constants;
using JP.Core.Enums;
using JP.Core.Exceptions;
using JP.Core.Extensions;
using JP.Domain.Offers;
using JP.Infrastructure.Repositories;

namespace JP.Infrastructure.Services;

/// <summary>Offer Lite. Phase 6A.</summary>
/// <remarks>
/// <para>
/// 🔴 TWO PERMISSIONS, AND THEY ARE NOT THE SAME ONE. OFFER.CREATE sends and
/// withdraws; OFFER.APPROVE confirms a hire — the act that turns "they said
/// yes" into "they work here". jp_sso's seed gives SENIOR_HR the first alone
/// and SCHOOL_OWNER both, which is the same shape as JOB.CREATE / JOB.PUBLISH
/// one subsystem over.
/// </para>
/// <para>
/// ⚠️ OFFER.APPROVE is ALSO the permission behind the role configured at
/// OFFER_APPROVAL level 1 (t_mdm_request_levels). A school that wants
/// Senior HR → Owner adds a second level row; 6A-0 proved the engine walks that
/// path, so it is configuration rather than code.
/// </para>
/// <para>
/// 🔴 NOTHING HERE COSTS ANYTHING, and nothing may be added that does. Offers
/// are not metered in this phase (2.64).
/// </para>
/// </remarks>
public interface IOfferService
{
    Task<SendOfferResultDto> SendAsync(
        ClaimsPrincipal caller, long applicationId, SendOfferRequest request,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<OfferDto>> GetForApplicationAsync(
        ClaimsPrincipal caller, long applicationId, CancellationToken cancellationToken);

    Task WithdrawAsync(
        ClaimsPrincipal caller, long offerId, WithdrawOfferRequest request,
        CancellationToken cancellationToken);

    Task ConfirmHireAsync(
        ClaimsPrincipal caller, long applicationId, ConfirmHireRequest request,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<MyOfferDto>> GetMyOffersAsync(
        ClaimsPrincipal caller, bool liveOnly, CancellationToken cancellationToken);

    Task RespondAsync(
        ClaimsPrincipal caller, long offerId, RespondToOfferRequest request,
        CancellationToken cancellationToken);
}

internal sealed class OfferService : IOfferService
{
    private readonly IOfferRepository _offers;
    private readonly IApplicationRepository _applications;
    private readonly ISchoolProfileService _schools;

    public OfferService(
        IOfferRepository offers,
        IApplicationRepository applications,
        ISchoolProfileService schools)
    {
        _offers = offers;
        _applications = applications;
        _schools = schools;
    }

    // ---- school side --------------------------------------------------------

    public async Task<SendOfferResultDto> SendAsync(
        ClaimsPrincipal caller, long applicationId, SendOfferRequest request,
        CancellationToken cancellationToken)
    {
        Require(caller, AppConstants.PermissionCodes.OfferCreate);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        var result = await _offers.SendAsync(
            schoolId, caller.GetUserUid(), applicationId, request, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        /*
          🔴 ALREADY_OFFERED IS A SUCCESS, and a race-only one.

          The procedure returns Status 1 with that code when the unique index
          refused a second live offer and the existing row was re-read (2.48).
          It cannot happen on an ordinary second click — the transition map
          refuses 7 → 7 first — so reaching here means two sessions genuinely
          collided, and the caller should be told the offer stands rather than
          be shown an error for something that worked.
        */
        result.EnsureSuccess();

        return new SendOfferResultDto
        {
            OfferId = result.Id ?? 0,
            Code = result.Code,
            Created = result.Code is null,
        };
    }

    public async Task<IReadOnlyList<OfferDto>> GetForApplicationAsync(
        ClaimsPrincipal caller, long applicationId, CancellationToken cancellationToken)
    {
        /*
          ⚠️ APPLICANT.VIEW, not OFFER.CREATE. Reading what was offered is part
          of reading the applicant — a Viewer who may see the candidate may see
          the offer that was made to them. Making a record they can already
          reach require the permission to CREATE one would be an accident of
          grouping, not a decision.
        */
        Require(caller, AppConstants.PermissionCodes.ApplicantView);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        return await _offers
            .GetForApplicationAsync(schoolId, caller.GetUserUid(), applicationId, cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task WithdrawAsync(
        ClaimsPrincipal caller, long offerId, WithdrawOfferRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        Require(caller, AppConstants.PermissionCodes.OfferCreate);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        var result = await _offers.WithdrawAsync(
            schoolId, caller.GetUserUid(), offerId, request.Reason, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();
    }

    public async Task ConfirmHireAsync(
        ClaimsPrincipal caller, long applicationId, ConfirmHireRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        /*
          🔴 OFFER.APPROVE, NOT OFFER.CREATE. Marking somebody hired is the
          school committing to a person — the last irreversible step in the
          machine (10 is terminal). SENIOR_HR can send an offer and cannot
          close it; the owner can.
        */
        Require(caller, AppConstants.PermissionCodes.OfferApprove);

        var schoolId = await _schools.ResolveSchoolIdAsync(caller, cancellationToken).ConfigureAwait(false);

        var result = await _offers.ConfirmHireAsync(
            schoolId, caller.GetUserUid(), applicationId, request.Remarks, caller.GetUserId(), cancellationToken)
            .ConfigureAwait(false);

        result.EnsureSuccess();
    }

    // ---- teacher side -------------------------------------------------------

    public async Task<IReadOnlyList<MyOfferDto>> GetMyOffersAsync(
        ClaimsPrincipal caller, bool liveOnly, CancellationToken cancellationToken)
    {
        RequireTeacher(caller);

        return await _offers.GetMyOffersAsync(caller.GetUserUid(), liveOnly, cancellationToken)
            .ConfigureAwait(false);
    }

    public async Task RespondAsync(
        ClaimsPrincipal caller, long offerId, RespondToOfferRequest request,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        RequireTeacher(caller);

        /*
          🔴 RESOLVED FROM THE TOKEN, never from the request. The procedure
          matches the offer on TeacherId, so another teacher's offer id resolves
          to nothing and answers NOT_FOUND rather than confirming it exists
          (2.6). There is no teacher id on the wire to forge.
        */
        var teacher = await _applications.ResolveTeacherAsync(caller.GetUserUid(), cancellationToken)
            .ConfigureAwait(false)
            ?? throw new ForbiddenException("Your account is not set up as a teacher profile yet.");

        var result = await _offers.RespondAsync(
            teacher.TeacherId, offerId, request.Accept, request.TeacherRemarks,
            caller.GetUserId(), cancellationToken).ConfigureAwait(false);

        result.EnsureSuccess();
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
    /// ⚠️ THE TYPE BEFORE THE PROFILE, so the refusal is honest — 3E's lesson.
    /// A school user hitting a teacher route must be told it is a teacher area,
    /// not told their teacher profile is missing.
    /// </summary>
    private static void RequireTeacher(ClaimsPrincipal caller)
    {
        if (caller.GetUserType() != UserType.Teacher)
        {
            throw new ForbiddenException("This is a teacher area. Your account is not a teacher account.");
        }
    }
}
