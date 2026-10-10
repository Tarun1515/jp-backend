using JP.Core.Common;
using JP.Domain.Offers;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/// <summary>
/// Offer Lite — the school's side.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 NO SchoolId ANYWHERE. Resolved from the token's OrganizationUid on every
/// request and never returned (2.39). Every read and write is branch-scoped
/// through <c>fn_VisibleBranches</c>, and anything outside that scope answers
/// 404 rather than 403 (2.6).
/// </para>
/// <para>
/// 🔴 THE OFFER AND THE APPLICATION MOVE TOGETHER. Every write here is one
/// transaction across two tables — the offer row and the application's status
/// with its history. The generic status endpoint deliberately refuses the offer
/// stages, so these routes are the only way to reach them.
/// </para>
/// <para>
/// ⚠️ NOTHING ON THESE ROUTES COSTS ANYTHING. There is no entitlement call
/// anywhere in offers; the consuming action is the job publish (2.64).
/// </para>
/// </remarks>
[ApiController]
[Route("api")]
[Authorize]
[Produces("application/json")]
public sealed class OffersController : ControllerBase
{
    private readonly IOfferService _offers;

    public OffersController(IOfferService offers)
    {
        _offers = offers;
    }

    /// <summary>
    /// Every offer this application has ever had, oldest first.
    /// </summary>
    /// <remarks>
    /// 🔴 A LIST, NOT A ROW. A second offer after a decline is allowed
    /// (016's header argues the case), so the trail is the answer to "what did
    /// we offer this person, and what happened". Returning only the live one
    /// would hide exactly the history that decision was justified by.
    /// </remarks>
    [HttpGet("applicants/{applicationId:long}/offers")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<OfferDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetForApplication(long applicationId, CancellationToken cancellationToken)
    {
        var offers = await _offers.GetForApplicationAsync(User, applicationId, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(offers));
    }

    /// <summary>
    /// Make an offer. Requires OFFER.CREATE.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The application must be at Selected — or at OfferDeclined, when this is a
    /// second offer after a decline. The transition map decides, not this
    /// controller and not the procedure's own opinion.
    /// </para>
    /// <para>
    /// ⚠️ <c>ALREADY_OFFERED</c> comes back on a 200 with <c>created: false</c>.
    /// It means a genuine race lost: the unique index refused the second live
    /// offer and the one that exists was re-read (2.48). An ordinary second
    /// click cannot produce it — the map refuses 7 → 7 long before the insert.
    /// </para>
    /// </remarks>
    [HttpPost("applicants/{applicationId:long}/offers")]
    [ProducesResponseType(typeof(Response<SendOfferResultDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Send(
        long applicationId, [FromBody] SendOfferRequest request, CancellationToken cancellationToken)
    {
        var result = await _offers.SendAsync(User, applicationId, request, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(result));
    }

    /// <summary>
    /// Pull an offer back. Requires OFFER.CREATE.
    /// </summary>
    /// <remarks>
    /// 🔴 ONLY A LIVE OFFER CAN BE WITHDRAWN. One the teacher has already
    /// accepted answers OFFER_NOT_LIVE — pulling it would rewrite what they
    /// were told, and undoing that is a conversation rather than a button.
    /// The application returns to Selected, so the next offer is the ordinary
    /// path rather than a special case.
    /// </remarks>
    [HttpPost("offers/{offerId:long}/withdraw")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Withdraw(
        long offerId, [FromBody] WithdrawOfferRequest request, CancellationToken cancellationToken)
    {
        await _offers.WithdrawAsync(User, offerId, request, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success("Offer withdrawn."));
    }

    /// <summary>
    /// Confirm the teacher actually started. Requires OFFER.APPROVE.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 A DIFFERENT PERMISSION FROM SENDING, deliberately. SENIOR_HR can make
    /// an offer and cannot close it; the owner can. Hiring is the school
    /// committing to a person, and it is terminal.
    /// </para>
    /// <para>
    /// ⚠️ SEPARATE FROM ACCEPTANCE, also deliberately. Collapsing the two would
    /// record people as hired who accepted and never arrived — which is the
    /// number a school will one day be asked to stand behind.
    /// </para>
    /// </remarks>
    [HttpPost("applicants/{applicationId:long}/hire")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> ConfirmHire(
        long applicationId, [FromBody] ConfirmHireRequest request, CancellationToken cancellationToken)
    {
        await _offers.ConfirmHireAsync(User, applicationId, request, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success("Marked as hired."));
    }
}

/// <summary>
/// Offer Lite — the teacher's side.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 TeacherFacingName THROUGHOUT, and the school's withdrawal reason is not
/// in this projection at all — the same line 017 draws for a rejection reason.
/// Absent, not nulled.
/// </para>
/// <para>
/// 🔴 ACCEPTING ONE OFFER DOES NOT TOUCH THE TEACHER'S OTHER APPLICATIONS.
/// 018's header has the argument in full; the short version is that nobody
/// asked for the others to be abandoned, and mass-closing them would revoke
/// other schools' contact access (2.56) through a path nobody designed.
/// </para>
/// </remarks>
[ApiController]
[Route("api/teacher/offers")]
[Authorize]
[Produces("application/json")]
public sealed class TeacherOffersController : ControllerBase
{
    private readonly IOfferService _offers;

    public TeacherOffersController(IOfferService offers)
    {
        _offers = offers;
    }

    /// <summary>The teacher's offers. <paramref name="liveOnly"/> keeps just the open ones.</summary>
    [HttpGet]
    [ProducesResponseType(typeof(Response<IReadOnlyList<MyOfferDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetMine(
        [FromQuery] bool liveOnly, CancellationToken cancellationToken)
    {
        var offers = await _offers.GetMyOffersAsync(User, liveOnly, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(offers));
    }

    /// <summary>
    /// Accept or decline, with optional remarks the school will read.
    /// </summary>
    /// <remarks>
    /// ⚠️ An offer that is no longer open answers OFFER_NOT_LIVE with a message
    /// naming which of the three happened — answered already, or withdrawn by
    /// the school. Usually a second tab rather than a race, and "invalid" would
    /// tell somebody nothing about what to do next.
    /// </remarks>
    [HttpPost("{offerId:long}/respond")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Respond(
        long offerId, [FromBody] RespondToOfferRequest request, CancellationToken cancellationToken)
    {
        await _offers.RespondAsync(User, offerId, request, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(request?.Accept == true ? "Offer accepted." : "Offer declined."));
    }
}
