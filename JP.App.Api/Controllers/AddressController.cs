using JP.Core.Common;
using JP.Domain.Address;
using JP.Infrastructure.Address;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/// <summary>
/// Address autocomplete, behind the provider seam.
/// </summary>
/// <remarks>
/// 🔴 ANONYMOUS, BECAUSE REGISTRATION IS ANONYMOUS. A school typing its
/// address has no account yet. That makes this the product's seventh
/// unauthenticated route, and it is rate limited for the same reason the
/// contact form is (7A): an open endpoint that costs money per call is an open
/// endpoint somebody will spend your money through. The limit lives in the
/// CHAINED GLOBAL limiter (PublicRateLimiting.AddressLookupPerIp), not in a
/// named policy attribute — this API has no named policies, and an attribute
/// naming one that does not exist fails at startup.
///
/// ⚠️ IT NEVER 404s OR 500s WHEN THE PROVIDER IS OFF. Suggestions come back as
/// an empty list and <c>available: false</c> tells the client to show the
/// dropdowns instead. Somebody is mid-form; a broken search box must not read
/// as a broken site.
/// </remarks>
[ApiController]
[Route("api/address")]
[AllowAnonymous]
public sealed class AddressController : ControllerBase
{
    private readonly IAddressLookupService _lookup;

    public AddressController(IAddressLookupService lookup) => _lookup = lookup;

    /// <summary>
    /// Whether address search is available at all.
    /// </summary>
    /// <remarks>
    /// The client asks once and decides whether to render the search box. The
    /// same reasoning as 2.47's empty dropdowns: a control that can never
    /// produce a result is worse than no control.
    /// </remarks>
    [HttpGet("availability")]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status200OK)]
    public IActionResult Availability() =>
        Ok(ApiResponse.Success<object>(new { available = _lookup.IsAvailable }));

    /// <summary>Suggestions for a partial address.</summary>
    [HttpGet("suggest")]
    [ProducesResponseType(typeof(Response<IReadOnlyList<AddressSuggestion>>), StatusCodes.Status200OK)]
    public async Task<IActionResult> Suggest(
        [FromQuery] string? q, CancellationToken cancellationToken)
    {
        var items = await _lookup.SuggestAsync(q ?? string.Empty, cancellationToken);

        return Ok(ApiResponse.Success(items));
    }

    /// <summary>
    /// One suggestion, resolved into our own address shape.
    /// </summary>
    /// <remarks>
    /// 🔴 THE RESPONSE IS OUR SHAPE, NOT GOOGLE'S — ids from our masters plus
    /// free text, identical to what the manual cascade produces. That is the
    /// seam's entire purpose: a row entered either way is indistinguishable
    /// once stored.
    ///
    /// <c>unmatched</c> names what the provider returned that our masters do
    /// not contain, so the form can say "we could not find that district,
    /// please pick it below" instead of quietly dropping a level.
    /// </remarks>
    [HttpGet("resolve")]
    [ProducesResponseType(typeof(Response<ResolvedAddress>), StatusCodes.Status200OK)]
    [ProducesResponseType(typeof(Response<object>), StatusCodes.Status404NotFound)]
    public async Task<IActionResult> Resolve(
        [FromQuery] string? placeId, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(placeId))
        {
            return Ok(ApiResponse.Success<ResolvedAddress?>(null, "No place was given."));
        }

        var resolved = await _lookup.ResolveAsync(placeId, cancellationToken);

        return resolved is null
            ? Ok(ApiResponse.Success<ResolvedAddress?>(null, "That place could not be resolved. Please use the dropdowns."))
            : Ok(ApiResponse.Success(resolved));
    }
}
