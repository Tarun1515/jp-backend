using JP.Core.Common;
using JP.Domain.Public;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/// <summary>
/// The public, unauthenticated surface. Phase 7A.
/// </summary>
/// <remarks>
/// <para>
/// 🔒 THE FIRST CONTROLLER IN THIS API WITHOUT <c>[Authorize]</c>, and its
/// absence is the design rather than an omission. Everything here is readable
/// by anyone, which is why what it does NOT return is the contract:
/// </para>
/// <para>
/// no teacher data of any kind · no application or saved-job count · no
/// school contact details · no plan, quota or entitlement · no incrementing
/// integer id. The raw-bytes sweep asserts that over the wire rather than
/// trusting this list.
/// </para>
/// <para>
/// 🔒 AND IT READS NO TOKEN, EVEN IF ONE IS SENT. No action here takes a
/// <c>ClaimsPrincipal</c> and the service has no accessor for one — so a
/// request carrying a valid Bearer token gets byte-identical JSON to an
/// anonymous one, which the verification proves rather than asserts.
/// </para>
/// <para>
/// ⚠️ Rate limited per IP by the global chained limiter
/// (<c>RateLimiting/PublicRateLimiting.cs</c>), not by an attribute — the same
/// shape and the same reason as 2.35.
/// </para>
/// <para>
/// 🔴 CACHE HEADERS PER ENDPOINT CLASS (2.81), and the job endpoints are
/// <c>no-store</c>: moderation has to take effect immediately, and a pulled
/// job served from a cache is exactly the failure 7B's round-trip test is
/// written to catch.
/// </para>
/// </remarks>
[ApiController]
[Route("api/public")]
[Produces("application/json")]
public sealed class PublicController : ControllerBase
{
    private readonly IPublicCatalogService _catalog;

    public PublicController(IPublicCatalogService catalog) => _catalog = catalog;

    /// <summary>The public job listing. Server-paged.</summary>
    /// <remarks>
    /// ⚠️ <c>no-store</c>. 2.81 weighed a 30-second cache and declined it for
    /// MVP: a job pulled by moderation would survive as a CARD for up to that
    /// long, and clicking it would 404 — better than serving its content, but
    /// still a wrong page, and the saving at MVP traffic is nil. It is the
    /// first thing to turn on when traffic justifies it.
    /// </remarks>
    [HttpGet("jobs")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<PublicJobCardDto>>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status429TooManyRequests)]
    public async Task<IActionResult> SearchJobs(
        [FromQuery] string? search = null,
        [FromQuery] int? subjectId = null,
        [FromQuery] int? cityId = null,
        [FromQuery] int? stateId = null,
        [FromQuery] int? classLevelId = null,
        [FromQuery] int pageNumber = 1,
        [FromQuery] int pageSize = 20,
        CancellationToken cancellationToken = default)
    {
        NoStore();

        var page = await _catalog.SearchJobsAsync(
            search, subjectId, cityId, stateId, classLevelId,
            pageNumber, pageSize, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Paged(page.Items, page.TotalRecords));
    }

    /// <summary>What the listing may be filtered by — reachable values only.</summary>
    /// <remarks>
    /// ⚠️ The filter MASTERS could be cached for an hour (2.81) — but these are
    /// counts of live jobs, not the masters themselves, and a count that is an
    /// hour stale sits beside a listing that is not. So it follows the listing:
    /// <c>no-store</c> in MVP.
    ///
    /// ⚠️ The city list is empty until the city master is seeded (G40), and the
    /// UI renders no city control when it is.
    /// </remarks>
    [HttpGet("jobs/filters")]
    [ProducesResponseType(typeof(Response<PublicJobFiltersDto>), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetFilters(CancellationToken cancellationToken)
    {
        NoStore();

        var filters = await _catalog.GetFiltersAsync(cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(filters));
    }

    /// <summary>One public job, or 404.</summary>
    /// <remarks>
    /// <para>
    /// 🔴 404 FOR EVERY REASON A JOB IS NOT PUBLIC — draft, expired, closed,
    /// soft-deleted, or pulled by moderation. The procedure's WHERE clause
    /// decides it (024); nothing here re-judges status, so there is no second
    /// rule to fall out of step with the first.
    /// </para>
    /// <para>
    /// ⚠️ The message never says WHY. "This job has expired" confirms the id is
    /// real, which on an anonymous endpoint is an enumeration oracle — 2.6's
    /// reasoning applied to a surface with no caller to protect.
    /// </para>
    /// <para>
    /// 🔴 <c>no-store</c> is load-bearing HERE above all: this is the endpoint
    /// whose staleness would show a pulled job's full content.
    /// </para>
    /// </remarks>
    [HttpGet("jobs/{jobUid:guid}")]
    [ProducesResponseType(typeof(Response<PublicJobDetailDto>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> GetJob(Guid jobUid, CancellationToken cancellationToken)
    {
        NoStore();

        var job = await _catalog.GetJobAsync(jobUid, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(job));
    }

    /// <summary>The FAQ page's content.</summary>
    /// <remarks>
    /// ⚠️ Five minutes (2.81). FAQs are admin-editable and carry no legal
    /// weight, so a five-minute lag is something an admin can be told about —
    /// unlike a job, where the lag would hide a moderation decision.
    /// </remarks>
    [HttpGet("faqs")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<PublicFaqDto>>), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetFaqs(CancellationToken cancellationToken)
    {
        Cacheable(300);

        var faqs = await _catalog.GetFaqsAsync(cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(faqs));
    }

    /// <summary>Designated content blocks, addressed by the key a template names.</summary>
    [HttpGet("content-blocks")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<PublicContentBlockDto>>), StatusCodes.Status200OK)]
    public async Task<IActionResult> GetContentBlocks(CancellationToken cancellationToken)
    {
        Cacheable(300);

        var blocks = await _catalog.GetContentBlocksAsync(cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(blocks));
    }

    /// <summary>The contact form.</summary>
    /// <remarks>
    /// <para>
    /// 🔴 ALWAYS 200 — INCLUDING WHEN NOTHING WAS WRITTEN.
    /// </para>
    /// <para>
    /// A filled honeypot gets the same response a real enquiry does and no row
    /// is created. Telling a bot it was detected teaches whoever wrote it to
    /// stop filling that field; telling it nothing keeps the trap working. The
    /// verification fills the honeypot and asserts both halves: 200, and no row.
    /// </para>
    /// <para>
    /// ⚠️ The visitor is NOT given a reference number. One would promise a
    /// ticketing system that does not exist; what they get is "we have it and
    /// will reply to this address", which is true.
    /// </para>
    /// </remarks>
    [HttpPost("contact")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status400BadRequest)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status429TooManyRequests)]
    public async Task<IActionResult> Contact(
        [FromBody] ContactEnquiryRequest request,
        CancellationToken cancellationToken)
    {
        NoStore();

        await _catalog.SubmitEnquiryAsync(request, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success<object?>(
            null, "Thank you — we have your message and will reply by email."));
    }

    /// <summary>
    /// 🔴 Moderation must take effect immediately (2.81, and 7B's round-trip
    /// test). Private as well as no-store: a shared proxy must not hold it
    /// either.
    /// </summary>
    private void NoStore()
    {
        Response.Headers.CacheControl = "no-store, no-cache, must-revalidate";
        Response.Headers.Pragma = "no-cache";
    }

    private void Cacheable(int seconds)
    {
        Response.Headers.CacheControl =
            $"public, max-age={seconds.ToString(System.Globalization.CultureInfo.InvariantCulture)}";
    }
}
