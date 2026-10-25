using System.Globalization;
using System.Net.Http.Json;
using System.Text.Json;
using JP.Domain.Address;
using JP.Infrastructure.Repositories;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Address;

/// <summary>
/// Google Places autocomplete, converted into our own address shape.
/// </summary>
/// <remarks>
/// 🔴 GOOGLE'S VOCABULARY STOPS HERE. Everything above this class sees
/// <see cref="ResolvedAddress"/> — our ids, our free text. Nothing downstream
/// knows what an "administrative_area_level_2" is, so replacing this provider
/// is replacing one class.
///
/// 🔒 THE KEY COMES FROM THE ENVIRONMENT, read per call rather than captured
/// at startup, so rotating it does not need a restart and so a process started
/// without one degrades instead of crashing.
///
/// ⚠️ EVERY FAILURE PATH RETURNS EMPTY OR NULL. A timeout, a quota refusal, a
/// malformed response and a network outage all end the same way: the client
/// falls back to the dropdowns. Somebody is mid-registration, and an exception
/// here is a lost signup.
/// </remarks>
internal sealed class GooglePlacesAddressLookupService : IAddressLookupService
{
    private const string AutocompleteUrl = "https://maps.googleapis.com/maps/api/place/autocomplete/json";
    private const string DetailsUrl = "https://maps.googleapis.com/maps/api/place/details/json";

    private readonly HttpClient _http;
    private readonly AddressLookupOptions _options;
    private readonly IMasterRepository _masters;
    private readonly ILogger<GooglePlacesAddressLookupService> _logger;

    public GooglePlacesAddressLookupService(
        HttpClient http,
        IOptions<AddressLookupOptions> options,
        IMasterRepository masters,
        ILogger<GooglePlacesAddressLookupService> logger)
    {
        _http = http;
        _options = options.Value;
        _masters = masters;
        _logger = logger;
    }

    private static string? Key =>
        Environment.GetEnvironmentVariable(AddressLookupOptions.ApiKeyEnvironmentVariable);

    public bool IsAvailable => !string.IsNullOrWhiteSpace(Key);

    public async Task<IReadOnlyList<AddressSuggestion>> SuggestAsync(
        string query, CancellationToken cancellationToken)
    {
        var key = Key;

        /*
          ⚠️ TWO CHARACTERS IS THE FLOOR, and it is about cost as much as
          usefulness: every keystroke is a billed request, and "a" matches the
          whole country.
        */
        if (string.IsNullOrWhiteSpace(key) || query is null || query.Trim().Length < 2)
        {
            return [];
        }

        var url = $"{AutocompleteUrl}?input={Uri.EscapeDataString(query.Trim())}"
            + $"&components=country:{Uri.EscapeDataString(_options.CountryBias)}"
            + $"&key={Uri.EscapeDataString(key)}";

        var root = await GetAsync(url, "autocomplete", cancellationToken).ConfigureAwait(false);

        if (root is null || !root.Value.TryGetProperty("predictions", out var predictions))
        {
            return [];
        }

        var items = new List<AddressSuggestion>();

        foreach (var p in predictions.EnumerateArray())
        {
            var placeId = Text(p, "place_id");

            if (string.IsNullOrWhiteSpace(placeId))
            {
                continue;
            }

            string? main = null;
            string? secondary = null;

            if (p.TryGetProperty("structured_formatting", out var sf))
            {
                main = Text(sf, "main_text");
                secondary = Text(sf, "secondary_text");
            }

            items.Add(new AddressSuggestion
            {
                PlaceId = placeId!,
                Description = Text(p, "description") ?? main ?? placeId!,
                MainText = main,
                SecondaryText = secondary,
            });
        }

        return items;
    }

    public async Task<ResolvedAddress?> ResolveAsync(string placeId, CancellationToken cancellationToken)
    {
        var key = Key;

        if (string.IsNullOrWhiteSpace(key) || string.IsNullOrWhiteSpace(placeId))
        {
            return null;
        }

        var url = $"{DetailsUrl}?place_id={Uri.EscapeDataString(placeId)}"
            + "&fields=address_component,geometry,formatted_address"
            + $"&key={Uri.EscapeDataString(key)}";

        var root = await GetAsync(url, "details", cancellationToken).ConfigureAwait(false);

        if (root is null || !root.Value.TryGetProperty("result", out var result))
        {
            return null;
        }

        return await ToResolvedAsync(result, placeId, cancellationToken).ConfigureAwait(false);
    }

    /// <summary>
    /// Google's components, matched against OUR masters.
    /// </summary>
    /// <remarks>
    /// 🔴 THE MATCHING ORDER IS STATE, THEN DISTRICT WITHIN THAT STATE, THEN
    /// TEHSIL WITHIN THAT DISTRICT, THEN CITY. Matching each level
    /// independently would let a place resolve to the Barwala of a district it
    /// is not in — Haryana has two, and that is exactly the bug the narrowing
    /// prevents.
    ///
    /// 🔴 NO MASTER ROW IS EVER CREATED FROM THIS. Masters are reference data
    /// (2.47) and have to stay reviewable; a table that grows itself from a
    /// third party's response is a table nobody can audit. What does not match
    /// becomes text and is REPORTED in <see cref="ResolvedAddress.Unmatched"/>,
    /// so the person is told rather than quietly given a shorter address.
    /// </remarks>
    private async Task<ResolvedAddress> ToResolvedAsync(
        JsonElement result, string placeId, CancellationToken cancellationToken)
    {
        string? stateName = null, districtName = null, tehsilName = null,
                cityName = null, areaName = null, pincode = null, route = null, number = null;

        if (result.TryGetProperty("address_components", out var components))
        {
            foreach (var c in components.EnumerateArray())
            {
                if (!c.TryGetProperty("types", out var types))
                {
                    continue;
                }

                var name = Text(c, "long_name");
                var set = types.EnumerateArray().Select(t => t.GetString()).ToHashSet(StringComparer.Ordinal);

                if (set.Contains("administrative_area_level_1")) stateName ??= name;
                else if (set.Contains("administrative_area_level_2")) districtName ??= name;
                else if (set.Contains("administrative_area_level_3")) tehsilName ??= name;
                else if (set.Contains("locality")) cityName ??= name;
                else if (set.Contains("sublocality") || set.Contains("sublocality_level_1")) areaName ??= name;
                else if (set.Contains("neighborhood")) areaName ??= name;
                else if (set.Contains("postal_code")) pincode ??= name;
                else if (set.Contains("route")) route ??= name;
                else if (set.Contains("street_number")) number ??= name;
            }
        }

        var unmatched = new List<string>();

        var stateId = await MatchAsync("STATE", null, stateName, cancellationToken).ConfigureAwait(false);
        if (stateName is not null && stateId is null) unmatched.Add($"state '{stateName}'");

        var districtId = stateId is null
            ? null
            : await MatchAsync("DISTRICT", stateId, districtName, cancellationToken).ConfigureAwait(false);
        if (districtName is not null && districtId is null) unmatched.Add($"district '{districtName}'");

        var tehsilId = districtId is null
            ? null
            : await MatchAsync("TEHSIL", districtId, tehsilName, cancellationToken).ConfigureAwait(false);
        if (tehsilName is not null && tehsilId is null) unmatched.Add($"tehsil '{tehsilName}'");

        /*
          City is looked up under the tehsil when we have one, under the
          district otherwise — the same either-parent rule USP_GetMaster
          implements, so the two agree by construction rather than by luck.
        */
        var cityParent = tehsilId ?? districtId;

        var cityId = cityParent is null
            ? null
            : await MatchAsync("CITY", cityParent, cityName, cancellationToken).ConfigureAwait(false);
        if (cityName is not null && cityId is null) unmatched.Add($"city '{cityName}'");

        decimal? lat = null, lng = null;

        if (result.TryGetProperty("geometry", out var geometry)
            && geometry.TryGetProperty("location", out var location))
        {
            if (location.TryGetProperty("lat", out var la) && la.TryGetDecimal(out var lad)) lat = lad;
            if (location.TryGetProperty("lng", out var ln) && ln.TryGetDecimal(out var lnd)) lng = lnd;
        }

        /*
          ⚠️ THE UNMATCHED CITY BECOMES THE AREA, which is the whole reason
          AreaOrVillage exists. A village Google knows and our masters do not is
          the common case in exactly the market this product sells to.
        */
        var area = areaName
            ?? (cityId is null ? cityName : null)
            ?? (tehsilId is null ? tehsilName : null);

        var line1 = string.Join(' ', new[] { number, route }.Where(x => !string.IsNullOrWhiteSpace(x)));

        return new ResolvedAddress
        {
            StateId = stateId,
            DistrictId = districtId,
            TehsilId = tehsilId,
            CityId = cityId,
            AreaOrVillage = Trim(area, 200),
            AddressLine1 = string.IsNullOrWhiteSpace(line1) ? null : Trim(line1, 250),
            Pincode = pincode,
            Latitude = Round(lat),
            Longitude = Round(lng),
            GooglePlaceId = placeId,
            FormattedAddress = Trim(Text(result, "formatted_address"), 500),
            Unmatched = unmatched,
        };
    }

    /// <summary>
    /// One master level, matched by name, case- and punctuation-insensitively.
    /// </summary>
    /// <remarks>
    /// ⚠️ EXACT-ISH, NOT FUZZY. "Gurgaon" and "Gurugram" are the same place and
    /// this will NOT match them, which is correct: a fuzzy match that is wrong
    /// puts a school in the wrong district silently, and the honest failure
    /// puts the name in <c>Unmatched</c> where somebody is asked to pick.
    /// Aliases, if they are ever wanted, belong in the master as rows — not in
    /// a similarity threshold here.
    /// </remarks>
    private async Task<int?> MatchAsync(
        string masterCode, int? parentId, string? name, CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(name))
        {
            return null;
        }

        /*
          ⚠️ THE Recognised FLAG IS CHECKED, NOT DISCARDED. A master code this
          service asks for that USP_GetMaster does not know is a typo in THIS
          file — and it would otherwise present as "Places never matches a
          tehsil", a bug hunted in the data instead of in the caller.
        */
        var (items, recognised) = await _masters
            .GetAsync(masterCode, parentId, cancellationToken).ConfigureAwait(false);

        if (!recognised)
        {
            _logger.LogError(
                "Address matching asked for master {MasterCode}, which USP_GetMaster does not recognise. "
                + "This is a bug in GooglePlacesAddressLookupService, not in the data.",
                masterCode);

            return null;
        }

        var wanted = Normalise(name);

        foreach (var item in items)
        {
            if (Normalise(item.Name) == wanted)
            {
                return item.Id;
            }
        }

        return null;
    }

    private static string Normalise(string? s) =>
        new((s ?? string.Empty).ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray());

    private async Task<JsonElement?> GetAsync(string url, string what, CancellationToken cancellationToken)
    {
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            cts.CancelAfter(TimeSpan.FromSeconds(_options.TimeoutSeconds));

            var doc = await _http.GetFromJsonAsync<JsonDocument>(url, cts.Token).ConfigureAwait(false);

            if (doc is null)
            {
                return null;
            }

            var root = doc.RootElement.Clone();

            /*
              🔴 GOOGLE RETURNS HTTP 200 WITH AN ERROR STATUS IN THE BODY.
              REQUEST_DENIED (a bad key) and OVER_QUERY_LIMIT both arrive as
              200, so checking the HTTP code alone reports a quota failure as a
              place with no results — and the symptom is "autocomplete stopped
              working" with nothing in the log.
            */
            var status = Text(root, "status");

            if (status is not null && status is not "OK" and not "ZERO_RESULTS")
            {
                _logger.LogWarning(
                    "Places {What} returned status {Status}: {Message}. Falling back to the manual cascade.",
                    what, status, Text(root, "error_message") ?? "(no message)");

                return null;
            }

            return root;
        }
        catch (Exception ex) when (ex is HttpRequestException or TaskCanceledException or JsonException)
        {
            /*
              ⚠️ NOT RE-THROWN, AND NOT LOGGED AS AN ERROR. Somebody is typing
              an address; the product's answer to a slow third party is the
              dropdowns, which work.
            */
            _logger.LogWarning(ex, "Places {What} failed. Falling back to the manual cascade.", what);

            return null;
        }
    }

    private static string? Text(JsonElement e, string property) =>
        e.TryGetProperty(property, out var v) && v.ValueKind == JsonValueKind.String ? v.GetString() : null;

    private static string? Trim(string? s, int max) =>
        string.IsNullOrWhiteSpace(s) ? null : s.Length <= max ? s : s[..max];

    /// <summary>decimal(9,6) is what the columns are — six places, about 11cm.</summary>
    private static decimal? Round(decimal? v) =>
        v is null ? null : Math.Round(v.Value, 6, MidpointRounding.AwayFromZero);
}
