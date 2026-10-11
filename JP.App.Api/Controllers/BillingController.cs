using JP.Core.Common;
using JP.Domain.Billing;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/// <summary>
/// Billing, manual first. Phase 6.5.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 THE GATEWAY IS NOT HERE, and nothing pretends otherwise. Money arrives by
/// NEFT, cheque or cash and an admin confirms it. There is no "pay now" route
/// and no stub endpoint waiting to be filled in — a fake gateway button is the
/// mockup-era failure this project exists to avoid (2.62: if something is not
/// yet possible, the control says when, and if it is not allowed the control is
/// not there at all).
/// </para>
/// <para>
/// 🔴 THE VERIFY ROUTE IS THE SEAM (MONETIZATION_DESIGN 6.5-A). When a gateway
/// arrives, its callback endpoint calls the SAME
/// <see cref="IBillingService.VerifyAndActivateAsync"/> — with a signature and a
/// replay window of its own, because authentication is this layer's problem and
/// not the service's. The business rule is written once.
/// </para>
/// <para>
/// 🔒 Contact details appear on no shape this controller returns, for any plan,
/// any role and any payment state. A payment buys CAPABILITY and never a
/// teacher's phone number or email (2.56, LOCKED).
/// </para>
/// <para>
/// ⚠️ The account-facing routes take NO owner parameter. The owner comes from
/// the token — the organisation for a school, the user for a teacher (2.39,
/// 2.51) — so there is nothing for a caller to tamper with. The admin routes
/// take an owner explicitly and are gated on PAYMENT.VERIFY.
/// </para>
/// </remarks>
[ApiController]
[Route("api/billing")]
[Authorize]
[Produces("application/json")]
public sealed class BillingController : ControllerBase
{
    private readonly IBillingService _billing;

    public BillingController(IBillingService billing) => _billing = billing;

    // =====================================================================
    //  The account's own side
    // =====================================================================

    /// <summary>The plans this kind of account can be on.</summary>
    /// <remarks>
    /// ⚠️ Scoped to the caller's user type from the token — a teacher cannot ask
    /// for school plans because there is no parameter for it (2.39).
    ///
    /// ⚠️ Today this returns one plan: the free one. Paid tiers are not seeded,
    /// because pricing is not finalised and a number we ship gets quoted back
    /// (008_seed_plans.sql). The mechanism is complete and the content is data
    /// (2.7).
    /// </remarks>
    [HttpGet("plans")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<PlanDto>>), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetPlans(CancellationToken cancellationToken)
    {
        var plans = await _billing.GetCatalogAsync(User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(plans));
    }

    /// <summary>What the account is on, and what it has used of it.</summary>
    /// <remarks>
    /// 🔴 <c>inForce</c> is not <c>isActive</c>: a paid plan past its end date is
    /// still an ACTIVE row and reads as the free baseline (6.5-C). Both are
    /// returned so the screen can say which it is showing.
    ///
    /// ⚠️ A null payload is a real state — an account with no subscription row
    /// at all — and the screen renders it rather than crashing (3B).
    /// </remarks>
    [HttpGet("my-plan")]
    [ProducesResponseType(typeof(Response<CurrentPlanDto>), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetMyPlan(CancellationToken cancellationToken)
    {
        var plan = await _billing.GetCurrentPlanAsync(User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(plan));
    }

    /// <summary>Asks to move to a plan. Grants nothing.</summary>
    /// <remarks>
    /// 🔴 PENDING CHANGES NOTHING. This records an intention; the active
    /// subscription rules until an admin verifies a payment. The verification
    /// proves the ledger and the refusals are identical across this state.
    ///
    /// ⚠️ 404 covers both "no such plan" and "that plan is not for your user
    /// type" — a refusal must not confirm that something exists (2.6).
    /// </remarks>
    [HttpPost("plan-change")]
    [ProducesResponseType(typeof(Response<PlanChangeRequestedDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status409Conflict)]
    public async Task<IActionResult> RequestPlanChange(
        [FromBody] RequestPlanChangeRequest request,
        CancellationToken cancellationToken)
    {
        var result = await _billing.RequestPlanChangeAsync(User, request, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(
            result,
            "We have recorded your request. Pay by NEFT, cheque or cash and an administrator "
            + "will confirm it."));
    }

    /// <summary>Every subscription this account has held.</summary>
    [HttpGet("my-history")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<SubscriptionHistoryDto>>), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetMyHistory(CancellationToken cancellationToken)
    {
        var history = await _billing.GetMyHistoryAsync(User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(history));
    }

    // =====================================================================
    //  The admin side — PAYMENT.VERIFY
    // =====================================================================

    /// <summary>Payments awaiting confirmation.</summary>
    /// <remarks>
    /// 🔒 PAYMENT.VERIFY, held by SUPER_ADMIN alone. The service checks it; the
    /// verification forces the negative with a school owner and a teacher.
    /// </remarks>
    [HttpGet("payments/pending")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<PendingPaymentDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetPendingPayments(
        [FromQuery] int pageNumber = 1,
        [FromQuery] int pageSize = 25,
        CancellationToken cancellationToken = default)
    {
        var page = await _billing
            .GetPendingPaymentsAsync(User, pageNumber, pageSize, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Paged(page.Items, page.TotalRecords));
    }

    /// <summary>One payment, with the expected amount beside it.</summary>
    [HttpGet("payments/{paymentId:long}")]
    [ProducesResponseType(typeof(Response<PaymentDetailDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetPayment(long paymentId, CancellationToken cancellationToken)
    {
        var payment = await _billing.GetPaymentAsync(User, paymentId, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(payment));
    }

    /// <summary>
    /// 🔴 THE SEAM: records that money arrived and activates the plan.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The amount is recorded as given — no price enforcement. A school that
    /// transferred less HAS paid that amount, and refusing to record it would
    /// make the real state of the world unrepresentable (6.5-B). What IS
    /// required is a remark when the amount differs from the quoted price, and
    /// that rule lives in the service because the gateway caller arriving later
    /// has nobody to ask for one.
    /// </para>
    /// <para>
    /// ⚠️ IDEMPOTENT, AND SAFE TO RETRY. Verification and activation are in two
    /// databases with no distributed transaction (2.2, 2.48), so a partial
    /// failure is a state the system will reach — and the recovery is calling
    /// this route again. <c>activationCompleted</c> reports the truth about the
    /// handoff rather than smoothing it over; the payment is never rolled back,
    /// because the money really did arrive.
    /// </para>
    /// </remarks>
    [HttpPost("payments/{paymentId:long}/verify")]
    [ProducesResponseType(typeof(Response<VerifyPaymentResultDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> VerifyPayment(
        long paymentId,
        [FromBody] VerifyPaymentRequest request,
        CancellationToken cancellationToken)
    {
        var result = await _billing
            .VerifyAndActivateAsync(User, paymentId, request, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(result, result.Message));
    }

    /// <summary>One account's subscription history, for the admin detail screen.</summary>
    [HttpGet("owners/{ownerUid:guid}/history")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<SubscriptionHistoryDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetOwnerHistory(Guid ownerUid, CancellationToken cancellationToken)
    {
        var history = await _billing.GetHistoryForOwnerAsync(User, ownerUid, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(history));
    }
}
