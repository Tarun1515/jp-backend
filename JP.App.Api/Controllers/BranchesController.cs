using JP.Core.Common;
using JP.Domain.Schools;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/// <summary>
/// A school's campuses.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 EVERY ENDPOINT HERE IS SCOPE-RESOLVED, AND A BRANCH YOU CANNOT SEE IS A
/// 404 RATHER THAN A 403.
/// </para>
/// <para>
/// The school comes from the caller's membership; the visible branches come
/// from <c>dbo.fn_VisibleBranches</c> (2.53) — an owner sees every campus, a
/// branch HR sees only the ones they are linked to. Nothing in this controller
/// re-implements that rule, and nothing accepts a school id.
/// </para>
/// <para>
/// The 404 is deliberate and matches the document download (2.48): telling a
/// branch HR "403" for another campus confirms that the campus exists, which is
/// the disclosure the scoping was meant to prevent.
/// </para>
/// </remarks>
[ApiController]
[Route("api/branches")]
[Authorize]
public sealed class BranchesController : ControllerBase
{
    private readonly IBranchService _branches;

    public BranchesController(IBranchService branches)
    {
        _branches = branches;
    }

    /// <summary>The campuses this caller can see.</summary>
    /// <remarks>
    /// An owner gets all of them; a branch HR gets only their own. The
    /// difference is not a parameter — it is who is asking.
    /// </remarks>
    [HttpGet]
    [ProducesResponseType(typeof(Response<IReadOnlyList<BranchDto>>), StatusCodes.Status200OK)]
    public async Task<IActionResult> List(
        [FromQuery] string? search,
        [FromQuery] int? stateId,
        [FromQuery] bool includeInactive = false,
        CancellationToken cancellationToken = default)
    {
        var rows = await _branches
            .ListAsync(search, stateId, includeInactive, User, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(rows));
    }

    /// <summary>One campus. 404 if it is not one of yours.</summary>
    [HttpGet("{id:long}")]
    [ProducesResponseType(typeof(Response<BranchDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetById(long id, CancellationToken cancellationToken)
    {
        var branch = await _branches.GetByIdAsync(id, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success(branch));
    }

    /// <summary>
    /// Adds a campus.
    /// </summary>
    /// <remarks>
    /// ⚠️ A new campus is NOT automatically visible to a branch HR who created
    /// it — visibility comes from <c>t_app_school_user_branches</c>, and linking
    /// somebody is a separate act (2.53). An owner sees it immediately.
    /// </remarks>
    [HttpPost]
    [ProducesResponseType(typeof(Response<SaveBranchResponse>), StatusCodes.Status200OK)]
    public async Task<IActionResult> Create(
        [FromBody] SaveBranchRequest request, CancellationToken cancellationToken)
    {
        var result = await _branches.SaveAsync(null, request, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success(result, result.Message));
    }

    /// <summary>
    /// Updates a campus. RowVersion is required.
    /// </summary>
    /// <remarks>
    /// 🔴 The scope check happens before the update, so a branch HR sending
    /// another campus's id gets 404 — not a permission error, and not a silent
    /// no-op.
    /// </remarks>
    [HttpPut("{id:long}")]
    [ProducesResponseType(typeof(Response<SaveBranchResponse>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status409Conflict)]
    public async Task<IActionResult> Update(
        long id, [FromBody] SaveBranchRequest request, CancellationToken cancellationToken)
    {
        var result = await _branches.SaveAsync(id, request, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success(result, result.Message));
    }

    /// <summary>
    /// Removes a campus. Soft delete.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Refused, each with its own reason the UI can show:
    /// </para>
    /// <list type="bullet">
    ///   <item>the head office — every school keeps at least one campus, which
    ///   is the invariant Phases 4 and 5 are built on</item>
    ///   <item>a stale RowVersion</item>
    ///   <item>⚠️ from Phase 4: a campus with jobs or applications against it.
    ///   The check is already written into the procedure and is unreachable
    ///   until those tables exist (2.53).</item>
    /// </list>
    /// </remarks>
    [HttpDelete("{id:long}")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Delete(
        long id, [FromBody] DeleteBranchRequest request, CancellationToken cancellationToken)
    {
        await _branches.DeleteAsync(id, request, User, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success("Campus removed."));
    }
}
