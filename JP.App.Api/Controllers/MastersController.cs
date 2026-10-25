using JP.Core.Common;
using JP.Domain.Masters;
using JP.Infrastructure.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace JP.App.Api.Controllers;

/// <summary>
/// Master data — the lists every dropdown in both apps is built from.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 CACHING. Masters change roughly never: a new subject is a deliberate
/// admin action, not a per-request fact. So these responses are cacheable for
/// an hour, which takes the bulk call off the critical path of every app load.
/// </para>
/// <para>
/// Contrast <c>/api/menus</c> in JP.Sso.Api, which is <c>no-store</c>. That one
/// is per-user and permission-dependent — caching it would show one person
/// another's navigation. The difference is not caution versus carelessness; it
/// is that one is public reference data and the other is an authorisation
/// result.
/// </para>
/// </remarks>
[ApiController]
[Route("api/masters")]
[Authorize]
public sealed class MastersController : ControllerBase
{
    /// <summary>One hour. Long enough to matter, short enough that a corrected
    /// master name reaches users the same working day.</summary>
    private const int CacheSeconds = 3600;

    private readonly IMasterService _service;

    public MastersController(IMasterService service)
    {
        _service = service;
    }

    /// <summary>Everything the app needs at load, in one call.</summary>
    [HttpGet("bulk")]
    [ResponseCache(Duration = CacheSeconds, Location = ResponseCacheLocation.Client)]
    public async Task<ActionResult<Response<MasterBundleDto>>> GetBundle(CancellationToken cancellationToken)
    {
        var bundle = await _service.GetBundleAsync(cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success(bundle));
    }

    /// <summary>
    /// One master list by key.
    /// </summary>
    /// <remarks>
    /// 🔴 <paramref name="masterKey"/> goes to <c>USP_GetMaster</c>, which
    /// matches it against a CASE it wrote itself. It is NEVER a table name, and
    /// there is deliberately no second whitelist here — one gate, in the
    /// procedure, so there is nothing to drift out of step. An unrecognised key
    /// returns an empty list.
    /// </remarks>
    [HttpGet("{masterKey}")]
    [ResponseCache(Duration = CacheSeconds, Location = ResponseCacheLocation.Client)]
    public async Task<ActionResult<Response<IReadOnlyList<MasterItemDto>>>> Get(
        string masterKey,
        [FromQuery] int? parentId,
        CancellationToken cancellationToken)
    {
        var items = await _service.GetAsync(masterKey, parentId, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success(items));
    }

    /// <summary>States in a country.</summary>
    [HttpGet("states")]
    [ResponseCache(Duration = CacheSeconds, Location = ResponseCacheLocation.Client)]
    public async Task<ActionResult<Response<IReadOnlyList<MasterItemDto>>>> GetStates(
        [FromQuery] int? countryId,
        CancellationToken cancellationToken)
    {
        var items = await _service.GetAsync("STATE", countryId, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success(items));
    }

    /// <summary>
    /// Districts in a state.
    /// </summary>
    /// <remarks>
    /// ⚠️ RETURNS AN EMPTY LIST TODAY, and that is correct behaviour rather
    /// than a bug. The district dataset has not been imported (decision 2.47).
    ///
    /// It must not 404 and must not error: the registration form is built to
    /// degrade to state-only selection, and it can only do that if this
    /// endpoint answers cleanly with nothing.
    /// </remarks>
    [HttpGet("districts")]
    [ResponseCache(Duration = CacheSeconds, Location = ResponseCacheLocation.Client)]
    public async Task<ActionResult<Response<IReadOnlyList<MasterItemDto>>>> GetDistricts(
        [FromQuery] int? stateId,
        CancellationToken cancellationToken)
    {
        var items = await _service.GetAsync("DISTRICT", stateId, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success(items));
    }

    /// <summary>
    /// Tehsils in a district — the optional level between district and town.
    /// </summary>
    /// <remarks>
    /// SR-1. Includes sub-tehsils, flagged in the data but not in this
    /// response: a person typing an address knows their place's name, not its
    /// revenue classification, and a list that omitted sub-tehsils would mean
    /// a school in Uklana cannot find Uklana.
    ///
    /// ⚠️ EMPTY FOR EVERY STATE EXCEPT HARYANA TODAY, and that is the same
    /// correct-degradation contract the districts endpoint has carried since
    /// 2.47: it answers cleanly with nothing, and the form hides the control.
    /// </remarks>
    [HttpGet("tehsils")]
    [ResponseCache(Duration = CacheSeconds, Location = ResponseCacheLocation.Client)]
    public async Task<ActionResult<Response<IReadOnlyList<MasterItemDto>>>> GetTehsils(
        [FromQuery] int? districtId,
        CancellationToken cancellationToken)
    {
        var items = await _service.GetAsync("TEHSIL", districtId, cancellationToken).ConfigureAwait(false);
        return Ok(ApiResponse.Success(items));
    }

    /// <summary>
    /// Towns in a tehsil, or in a district when no tehsil was chosen.
    /// </summary>
    /// <remarks>
    /// 🔴 TEHSIL WINS WHEN BOTH ARE SENT, and the reason is the cascade's own
    /// shape: tehsil is the NARROWER choice the user made most recently. Taking
    /// the district instead would silently widen a selection they deliberately
    /// narrowed.
    ///
    /// ⚠️ Both are optional because the tehsil step is optional (ADDRESS_DESIGN
    /// §2). A school that knows only its district must still reach a town.
    /// </remarks>
    [HttpGet("cities")]
    [ResponseCache(Duration = CacheSeconds, Location = ResponseCacheLocation.Client)]
    public async Task<ActionResult<Response<IReadOnlyList<MasterItemDto>>>> GetCities(
        [FromQuery] int? districtId,
        [FromQuery] int? tehsilId,
        CancellationToken cancellationToken)
    {
        var items = await _service
            .GetAsync("CITY", tehsilId ?? districtId, cancellationToken).ConfigureAwait(false);

        return Ok(ApiResponse.Success(items));
    }
}
