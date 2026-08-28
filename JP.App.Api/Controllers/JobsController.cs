using JP.Core.Common;
using JP.Domain.Jobs;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/// <summary>
/// School-side job management.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 NO SchoolId ANYWHERE — not in a route, not in a query, not in a body, and
/// not in a response. It is resolved from the token's OrganizationUid on the
/// server and never leaves it (2.39).
/// </para>
/// <para>
/// ⚠️ BranchId DOES travel, in both directions, because a job belongs to a
/// campus the user chooses. It is validated against the caller's resolved
/// branch scope inside every procedure before it is used — and a campus they do
/// not hold answers 404, never 403, because "that campus is not yours" confirms
/// it exists (2.6).
/// </para>
/// <para>
/// 🔴 Publishing is where the entitlement is spent, and the spend and the
/// status change are ONE database transaction. There is no "check then publish"
/// pair of endpoints, deliberately — see <see cref="Publish"/>.
/// </para>
/// </remarks>
[ApiController]
[Route("api/jobs")]
[Authorize]
public sealed class JobsController : ControllerBase
{
    private readonly IJobService _jobs;

    public JobsController(IJobService jobs)
    {
        _jobs = jobs;
    }

    /// <summary>The school's own jobs, filtered by EFFECTIVE status.</summary>
    /// <remarks>
    /// ⚠️ <paramref name="statusId"/> = 3 (Expired) returns rows the database
    /// still stores as Active — expiry is derived from the closing date, not
    /// written by a nightly job. Each row carries both the stored and the
    /// effective status so the difference is visible rather than implied.
    /// </remarks>
    [HttpGet]
    [ProducesResponseType(typeof(Response<IReadOnlyList<JobListItemDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    public async Task<IActionResult> GetList(
        [FromQuery] int? statusId, [FromQuery] long? branchId, CancellationToken cancellationToken)
    {
        var jobs = await _jobs.GetListAsync(User, statusId, branchId, cancellationToken)
            .ConfigureAwait(false);

        return Ok(ApiResponse.Success(jobs));
    }

    [HttpGet("{jobId:long}")]
    [ProducesResponseType(typeof(Response<JobDetailDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetById(long jobId, CancellationToken cancellationToken)
    {
        var job = await _jobs.GetByIdAsync(User, jobId, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(job));
    }

    /// <summary>Create a draft, or edit an existing job.</summary>
    /// <remarks>
    /// A job is always born a Draft — there is no "create and publish" in one
    /// call, because publishing costs and creating does not.
    ///
    /// ⚠️ Once Active, the fields a teacher MATCHED on are locked: campus,
    /// subject, designation, qualification, employment type, location and the
    /// experience band. Terms — salary, timings, description, closing date —
    /// stay editable. Refused with JOB_FIELD_LOCKED.
    /// </remarks>
    [HttpPost]
    [ProducesResponseType(typeof(Response<long>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Save(
        [FromBody] SaveJobRequest request, CancellationToken cancellationToken)
    {
        var jobId = await _jobs.SaveAsync(User, request, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(jobId));
    }

    /// <summary>
    /// Draft to Active — and the entitlement spend, atomically.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 ONE CALL, ONE TRANSACTION. A refused consume leaves the job a Draft
    /// and returns the refusal's own Code; a failure after the consume rolls
    /// the ledger row back with it. There is deliberately no endpoint that
    /// checks entitlement separately — two calls with a gap between them is
    /// exactly the window this design exists to close.
    /// </para>
    /// <para>
    /// ⚠️ A 200 can carry <c>ALREADY_CONSUMED</c>: re-publishing a job that was
    /// closed is free, because the ledger's reference is the job's own Uid and
    /// it is genuinely the same job. Branch on the status first, then the code.
    /// </para>
    /// </remarks>
    [HttpPost("{jobId:long}/publish")]
    [ProducesResponseType(typeof(Response<PublishJobResultDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status403Forbidden)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status409Conflict)]
    public async Task<IActionResult> Publish(long jobId, CancellationToken cancellationToken)
    {
        var result = await _jobs.PublishAsync(User, jobId, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.SuccessWithCode(result, result.Code,
            result.Consumed ? "Published." : "Published — nothing was charged."));
    }

    /// <summary>
    /// Close a published job.
    /// </summary>
    /// <remarks>
    /// ⚠️ An EXPIRED job can be closed, and that is the normal case — the row
    /// is still Active and only its date has passed. A Draft cannot: it was
    /// never open, and "closing" it would mean discarding it, which is a
    /// different action wearing the same word.
    /// </remarks>
    [HttpPost("{jobId:long}/close")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Close(long jobId, CancellationToken cancellationToken)
    {
        await _jobs.CloseAsync(User, jobId, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success("Closed."));
    }
}
