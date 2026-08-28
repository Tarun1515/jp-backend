using System.Net;
using JP.Core.Common;
using JP.Core.Constants;
using JP.Core.Exceptions;
using JP.Domain.Entitlements;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/// <summary>
/// The entitlement engine's surface: the admin plan × feature matrix, and the
/// consume path.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 NOTHING IN THE PRODUCT IS GATED BY THIS YET, AND THAT IS THE PLAN.
/// Every feature seeds FREE, no plan-feature mappings exist, and no business
/// endpoint calls the engine. Phase 4 writes the first real consume, with job
/// posting; Phase 6.5 sets the first non-free mode — by changing data, not by
/// deploying code (2.7).
/// </para>
/// <para>
/// Shipping the engine and the gating together would mean that on the day
/// something stops working, two new things are under suspicion at once.
/// </para>
/// <para>
/// ⚠️ EVERY ENDPOINT HERE IS ADMIN-ONLY (SETTINGS.MANAGE), including consume.
/// A school cannot spend its own quota over HTTP because nothing sells it
/// anything yet — the consume endpoint exists so the engine can be operated and
/// verified, not as a customer-facing action. Phase 4 will call
/// <c>IEntitlementService.ConsumeAsync</c> in-process from the job endpoint,
/// where the owner comes from the token (2.39) and never from a body.
/// </para>
/// <para>
/// 🔴 The engine never speaks about contact details. A subscription buys
/// capability — search, invites — never a teacher's phone number (2.56).
/// </para>
/// </remarks>
[ApiController]
[Route("api/entitlements")]
[Authorize]
public sealed class EntitlementsController : ControllerBase
{
    private readonly IEntitlementService _entitlements;

    public EntitlementsController(IEntitlementService entitlements)
    {
        _entitlements = entitlements;
    }

    /// <summary>Everything the plan × feature screen draws.</summary>
    [HttpGet("matrix")]
    [ProducesResponseType(typeof(Response<EntitlementMatrixDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetMatrix(CancellationToken cancellationToken)
    {
        var matrix = await _entitlements.GetMatrixAsync(User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(matrix));
    }

    /// <summary>Set a feature's gating mode and its kill switch.</summary>
    /// <remarks>
    /// ⚠️ Both in one call because the screen holds both, and because they are
    /// independent: switching a feature off must not disturb how it was gated,
    /// or restoring it depends on somebody remembering — mid-incident.
    ///
    /// 🔴 There is nothing to invalidate. The next consume reads the row.
    /// </remarks>
    [HttpPut("features/{featureId:int}/gating")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> SaveGating(
        int featureId, [FromBody] SaveFeatureGatingRequest request, CancellationToken cancellationToken)
    {
        await _entitlements.SaveFeatureGatingAsync(User, featureId, request, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success("Saved."));
    }

    /// <summary>Map a feature to a plan, or unmap it.</summary>
    /// <remarks>
    /// UNMAP is a soft delete and returns the cell to "no decision" — which the
    /// engine refuses on. That is the safe direction for a screen edited by
    /// hand: the destructive mis-click removes capability from one plan rather
    /// than granting it to everybody.
    /// </remarks>
    [HttpPut("plan-features")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> SavePlanFeature(
        [FromBody] SavePlanFeatureRequest request, CancellationToken cancellationToken)
    {
        await _entitlements.SavePlanFeatureAsync(User, request, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success("Saved."));
    }

    /// <summary>
    /// Decide and record, atomically. The engine's only decision method.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 There is no "may I?" endpoint. Check-then-consume across two calls
    /// lets two sessions both be told yes for the same last unit.
    /// </para>
    /// <para>
    /// ⚠️ A refusal becomes a non-2xx carrying its own Code (2.21/2.12), so the
    /// client branches on the code and never on message text. ALREADY_CONSUMED
    /// is the exception that proves the rule: it is a SUCCESS, returned 200
    /// with the code set, because a retry that is told "you already paid for
    /// this" and then treated as an error is how a customer gets charged twice.
    /// </para>
    /// </remarks>
    [HttpPost("consume")]
    [ProducesResponseType(typeof(Response<EntitlementDecision>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status409Conflict)]
    public async Task<IActionResult> Consume(
        [FromBody] ConsumeRequest request, CancellationToken cancellationToken)
    {
        var decision = await _entitlements
            .ConsumeAsAdminAsync(User, request, cancellationToken).ConfigureAwait(false);

        if (!decision.Allowed)
        {
            throw ToRefusal(decision);
        }

        /*
          🔴 Success WITH a code. ALREADY_CONSUMED lands here, not on the
          failure path — see ApiResponse.SuccessWithCode for why that
          distinction is load-bearing.
        */
        return Ok(ApiResponse.SuccessWithCode(decision, decision.Code, decision.Message ?? "Allowed."));
    }

    /// <summary>
    /// The engine's refusal codes, and the HTTP status each deserves.
    /// </summary>
    /// <remarks>
    /// <para>
    /// One place, because the statuses are not interchangeable and a caller
    /// branching on them must get the same answer from every endpoint. The
    /// generic <c>ProcResultExtensions</c> mapper cannot be reused here: it is
    /// internal to JP.Infrastructure, and its default of 400 would flatten
    /// three genuinely different situations into one.
    /// </para>
    /// <para>
    /// ⚠️ SUBSCRIPTION_MISSING is 403 rather than 500 on purpose. It IS our bug
    /// and it is logged at Error — but a 500 would be replaced by the global
    /// handler with INTERNAL_ERROR, and the client would lose the one code that
    /// tells it to say "contact us" instead of "upgrade your plan".
    /// </para>
    /// </remarks>
    private static Exception ToRefusal(EntitlementDecision decision)
    {
        var message = decision.Message ?? "That action is not available.";

        return decision.Code switch
        {
            // Operator decisions and account state: authenticated, not permitted.
            ErrorCodes.FeatureDisabled or ErrorCodes.SubscriptionInactive
                or ErrorCodes.SubscriptionMissing
                => new AppException(message, decision.Code, HttpStatusCode.Forbidden),

            // Retryable collisions.
            ErrorCodes.ConsumeConflict or ErrorCodes.PlanChanged
                => new AppException(message, decision.Code, HttpStatusCode.Conflict),

            // "Buy more" — the plan, or the month. Both 400, different codes,
            // and the UI shows a different upgrade prompt for each.
            _ => new BusinessRuleException(message, decision.Code ?? ErrorCodes.BusinessRuleViolated),
        };
    }

    /// <summary>Credits for one feature, on one account.</summary>
    [HttpPost("credits")]
    [ProducesResponseType(typeof(Response<long>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GrantCredits(
        [FromBody] GrantCreditsRequest request, CancellationToken cancellationToken)
    {
        var entryId = await _entitlements.GrantCreditsAsync(User, request, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(entryId));
    }

    /// <summary>
    /// Undo one entry without deleting it.
    /// </summary>
    /// <remarks>
    /// 🔴 A reversed consume FREES ITS REFERENCE, so the same action can be
    /// charged again. If we refunded a job posting, that job may legitimately
    /// be posted and charged again — the opposite would mean a refund
    /// permanently blocked the thing it refunded.
    /// </remarks>
    [HttpPost("entries/{entryId:long}/reverse")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> Reverse(
        long entryId, [FromBody] ReverseRequest? request, CancellationToken cancellationToken)
    {
        var code = await _entitlements
            .ReverseAsync(User, entryId, request?.Notes, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.SuccessWithCode("Reversed.", code, "Reversed."));
    }

    /// <summary>An owner's standing for one feature, recomputed from the ledger.</summary>
    [HttpGet("balance")]
    [ProducesResponseType(typeof(Response<EntitlementBalanceDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetBalance(
        [FromQuery] Guid ownerUid, [FromQuery] string featureCode, CancellationToken cancellationToken)
    {
        var balance = await _entitlements
            .GetBalanceAsAdminAsync(User, ownerUid, featureCode, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(balance));
    }

    /// <summary>The rows themselves. For support and for verification.</summary>
    [HttpGet("ledger")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<LedgerEntryDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetLedger(
        [FromQuery] Guid ownerUid,
        [FromQuery] string? featureCode,
        [FromQuery] int top,
        CancellationToken cancellationToken)
    {
        var rows = await _entitlements
            .GetLedgerAsAdminAsync(User, ownerUid, featureCode, top <= 0 ? 200 : top, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(rows));
    }
}

/// <summary>Body for a reversal. Notes are optional but strongly encouraged.</summary>
public sealed class ReverseRequest
{
    public string? Notes { get; set; }
}
