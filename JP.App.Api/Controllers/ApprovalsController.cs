using JP.Core.Common;
using JP.Domain.Approvals;
using JP.Domain.Common;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/// <summary>
/// The approval engine's HTTP surface.
/// </summary>
/// <remarks>
/// 🔴 Nothing here reads an organisation, a school or a user id from the route,
/// the query string or the body. Every one of those comes from the caller's
/// token inside the service (decision 2.39). The controller's only job on that
/// front is to hand <c>User</c> down.
/// </remarks>
[ApiController]
[Route("api/approvals")]
[Authorize]
public sealed class ApprovalsController : ControllerBase
{
    private readonly IApprovalService _approvals;

    public ApprovalsController(IApprovalService approvals)
    {
        _approvals = approvals;
    }

    /// <summary>Submit a request for approval.</summary>
    /// <remarks>
    /// Idempotent. Submitting the same entity twice returns the existing
    /// request with <c>alreadyPending = true</c> rather than creating a second
    /// — a double-clicked form is not an error.
    /// </remarks>
    [HttpPost("submit")]
    [ProducesResponseType(typeof(Response<SubmitApprovalResponse>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    public async Task<IActionResult> Submit(
        [FromBody] SubmitApprovalRequest request,
        CancellationToken cancellationToken)
    {
        var result = await _approvals
            .SubmitAsync(request, User, HttpContext.Connection.RemoteIpAddress?.ToString(), cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(result, result.Message));
    }

    /// <summary>
    /// The approval queue, paged and oldest first.
    /// </summary>
    /// <remarks>
    /// An admin sees every organisation; anyone else is pinned to their own by
    /// the service. There is no parameter that changes which.
    /// </remarks>
    [HttpGet]
    [ProducesResponseType(typeof(Response<IReadOnlyList<ApprovalRequestListItemDto>>), StatusCodes.Status200OK)]
    public async Task<IActionResult> List(
        [FromQuery] ApprovalRequestFilter filter,
        CancellationToken cancellationToken)
    {
        var page = await _approvals.ListAsync(filter, User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Paged(page.Items, page.TotalRecords));
    }

    /// <summary>One request, with its payload, documents, trail and payments.</summary>
    [HttpGet("{id:long}")]
    [ProducesResponseType(typeof(Response<ApprovalRequestDetailDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetById(long id, CancellationToken cancellationToken)
    {
        var detail = await _approvals.GetByIdAsync(id, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success(detail));
    }

    /// <summary>
    /// Approve, reject, or ask for a resubmission.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Permission-gated per request type inside the service:
    /// <c>VERIFICATION.SCHOOL</c> or <c>VERIFICATION.TEACHER</c>.
    /// </para>
    /// <para>
    /// 🔴 Read <c>orchestrationCompleted</c> on the response, not just the HTTP
    /// status. A 200 means the APPROVAL committed. If the cross-database work
    /// that follows it failed, this returns 200 with
    /// <c>orchestrationCompleted = false</c> and an <c>orchestrationError</c> —
    /// because the approval genuinely did happen and cannot be un-happened, and
    /// reporting a 500 would suggest it had not.
    /// </para>
    /// </remarks>
    [HttpPost("{id:long}/action")]
    [ProducesResponseType(typeof(Response<ProcessActionResponse>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status409Conflict)]
    public async Task<IActionResult> Action(
        long id,
        [FromBody] ProcessActionRequest request,
        CancellationToken cancellationToken)
    {
        var result = await _approvals
            .ProcessActionAsync(id, request, User, HttpContext.Connection.RemoteIpAddress?.ToString(), cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(result, result.Message));
    }

    /// <summary>Resubmit after a resubmission was requested. Requestor only.</summary>
    [HttpPost("{id:long}/resubmit")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> Resubmit(
        long id,
        [FromBody] ResubmitRequest request,
        CancellationToken cancellationToken)
    {
        await _approvals
            .ResubmitAsync(id, request, User, HttpContext.Connection.RemoteIpAddress?.ToString(), cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success("Your request has been resubmitted for review."));
    }

    /// <summary>
    /// Runs the cross-database work again for an approval that already
    /// completed.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 THE RECOVERY FOR A PARTIAL COMPLETION.
    /// </para>
    /// <para>
    /// When <c>/action</c> returns <c>orchestrationCompleted = false</c>, the
    /// approval is committed and the work after it is not. Before this existed
    /// the only fix was a DBA calling <c>USP_ProvisionSchoolFromApproval</c> by
    /// hand — a school that had paid and could not sign in, waiting on
    /// somebody's database access.
    /// </para>
    /// <para>
    /// Safe to call repeatedly: every step is idempotent, so a retry either
    /// finishes the missing work or reports the same failure again. It does not
    /// re-approve anything — the approval is untouched, and only its follow-on
    /// effects are repeated.
    /// </para>
    /// <para>
    /// Returns the same shape as <c>/action</c>, so a caller has one thing to
    /// read in both places: <c>orchestrationCompleted</c>.
    /// </para>
    /// </remarks>
    [HttpPost("{id:long}/retry-orchestration")]
    [ProducesResponseType(typeof(Response<ProcessActionResponse>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> RetryOrchestration(long id, CancellationToken cancellationToken)
    {
        var result = await _approvals
            .RetryOrchestrationAsync(id, User, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(result, result.Message));
    }

    /// <summary>
    /// Approvals that completed but whose downstream work never did.
    /// </summary>
    /// <remarks>
    /// <para>
    /// The reconciliation report. An empty list is the healthy answer and the
    /// expected one — this endpoint exists so that the unhealthy answer is
    /// visible to an admin rather than only to whoever thinks to run a query.
    /// </para>
    /// <para>
    /// ⚠️ Teacher verifications are excluded at the source. They provision
    /// nothing by design (decision 2.9), so every approved one would appear
    /// here for ever and bury the real orphans.
    /// </para>
    /// </remarks>
    [HttpGet("orphaned")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<OrphanedApprovalDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> Orphaned(
        [FromQuery] int sinceDays = 90,
        CancellationToken cancellationToken = default)
    {
        var rows = await _approvals.GetOrphanedAsync(sinceDays, User, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(rows));
    }

    /// <summary>Pending counts per request type, for the dashboard badges.</summary>
    [HttpGet("counts")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<PendingCountDto>>), StatusCodes.Status200OK)]
    public async Task<IActionResult> Counts(CancellationToken cancellationToken)
    {
        var counts = await _approvals.GetPendingCountsAsync(User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success(counts));
    }
}
