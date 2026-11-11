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
    /// <summary>
    /// The shortest query that may reach Google, in characters.
    /// </summary>
    /// <remarks>
    /// 🔴 RAISED FROM TWO TO THREE WHEN THE CLIENT'S OWN KEY WENT IN. Every
    /// request past this point is billed to them, and two letters still match
    /// most of the country — so the second character buys a worse list and a
    /// real cost.
    ///
    /// ⚠️ A CONSTANT, NOT A SETTING. A quota floor that an operator can lower
    /// in config is a quota floor somebody lowers at three in the morning to
    /// make a demo feel snappier. The per-IP window above it IS configurable,
    /// because that one is about traffic shape rather than about what we are
    /// willing to spend per keystroke.
    /// </remarks>
    internal const int MinimumQueryLength = 3;

    /*
      ----------------------------------------------------------------------------
      🔴 PLACES API (NEW), NOT THE LEGACY ONE — AND GOOGLE TOLD US SO IN WORDS
      ----------------------------------------------------------------------------
      SR-2 built this against `maps.googleapis.com/maps/api/place/*`. The first
      call made with the client's real key came back HTTP 200 with:

          REQUEST_DENIED: You're calling a legacy API, which is not enabled for
          your project. Switch to the Places API (New) or Routes API.

      The key was fine — it reached Google and got an authenticated refusal, not
      an auth error. Google simply does not enable the legacy endpoints on
      projects created now, so an implementation written against them cannot be
      turned on by any amount of configuration.

      ⚠️ AND THE SEAM BEHAVED EXACTLY AS DESIGNED WHILE THAT WAS TRUE: the
      warning was logged with Google's own sentence, the suggestion list came
      back empty, and the form fell through to the manual cascade. Nothing
      broke; it just did nothing. Which is why the log line matters more than
      the HTTP code here.

      ----------------------------------------------------------------------------
      ⚠️ THE KEY MOVES FROM THE QUERY STRING TO A HEADER, AND THAT IS A GAIN
      ----------------------------------------------------------------------------
      The legacy API took `&key=`; the new one takes `X-Goog-Api-Key`. A secret
      in a URL is a secret in every access log, proxy log and error report that
      ever records the request. A header is not. We would have wanted this
      change even if the legacy API still worked.
    */
    private const string AutocompleteUrl = "https://places.googleapis.com/v1/places:autocomplete";
    private const string DetailsUrlPrefix = "https://places.googleapis.com/v1/places/";

    /// <summary>
    /// The fields Place Details may return.
    /// </summary>
    /// <remarks>
    /// 🔴 REQUIRED BY THE NEW API, AND IT IS ALSO THE BILL. Places (New) refuses
    /// a details call with no field mask, and it prices the call by which
    /// fields are asked for — so this list is deliberately the four we parse
    /// and nothing else. Adding `*` here would work and would quietly move the
    /// call into a more expensive tier.
    /// </remarks>
    private const string DetailsFieldMask = "id,formattedAddress,addressComponents,location";

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
          ⚠️ THREE CHARACTERS IS THE FLOOR, raised from two when the client's
          own key went in. It is about cost as much as usefulness: every
          keystroke that reaches here is a BILLED request against somebody
          else's account, and two letters still match most of the country.

          🔴 IT IS ENFORCED HERE, NOT ONLY IN THE BROWSER. The client debounces
          and counts characters too, but that is a courtesy to the user's
          typing — it is not a control, because anyone can call
          /api/address/suggest directly. The floor that protects the quota has
          to be the one on this side of the wire.
        */
        if (string.IsNullOrWhiteSpace(key) || query is null || query.Trim().Length < MinimumQueryLength)
        {
            return [];
        }

        /*
          ⚠️ A POST WITH A JSON BODY. Autocomplete in Places (New) is a POST,
          and the country bias is `includedRegionCodes` rather than a
          `components=country:` string.
        */
        var request = new HttpRequestMessage(HttpMethod.Post, AutocompleteUrl)
        {
            Content = JsonContent.Create(new
            {
                input = query.Trim(),
                includedRegionCodes = new[] { _options.CountryBias },
            }),
        };

        var root = await CallAsync(request, key, "autocomplete", cancellationToken).ConfigureAwait(false);

        if (root is null || !root.Value.TryGetProperty("suggestions", out var suggestions))
        {
            return [];
        }

        var items = new List<AddressSuggestion>();

        foreach (var s in suggestions.EnumerateArray())
        {
            /*
              ⚠️ A suggestion is EITHER a placePrediction OR a queryPrediction.
              Only the first has a place id to resolve; a query prediction is a
              search phrase, which this product has nothing to do with.
            */
            if (!s.TryGetProperty("placePrediction", out var p))
            {
                continue;
            }

            var placeId = Text(p, "placeId");

            if (string.IsNullOrWhiteSpace(placeId))
            {
                continue;
            }

            string? main = null;
            string? secondary = null;

            if (p.TryGetProperty("structuredFormat", out var sf))
            {
                if (sf.TryGetProperty("mainText", out var mt)) main = Text(mt, "text");
                if (sf.TryGetProperty("secondaryText", out var st)) secondary = Text(st, "text");
            }

            string? description = null;
            if (p.TryGetProperty("text", out var t)) description = Text(t, "text");

            items.Add(new AddressSuggestion
            {
                PlaceId = placeId!,
                Description = description ?? main ?? placeId!,
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

        var request = new HttpRequestMessage(
            HttpMethod.Get,
            $"{DetailsUrlPrefix}{Uri.EscapeDataString(placeId)}");

        request.Headers.TryAddWithoutValidation("X-Goog-FieldMask", DetailsFieldMask);

        var root = await CallAsync(request, key, "details", cancellationToken).ConfigureAwait(false);

        /*
          ⚠️ THE PLACE IS THE WHOLE BODY NOW. The legacy API wrapped it in a
          `result` property; Places (New) returns the place itself, so there is
          no envelope to unwrap and no `result` to go missing.
        */
        return root is null
            ? null
            : await ToResolvedAsync(root.Value, placeId, cancellationToken).ConfigureAwait(false);
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

        /*
          ⚠️ `addressComponents` / `longText`, not `address_components` /
          `long_name`. Places (New) is camelCase throughout, and the TYPES
          inside are unchanged — which is why the matching rules below survived
          the port untouched.
        */
        if (result.TryGetProperty("addressComponents", out var components))
        {
            foreach (var c in components.EnumerateArray())
            {
                if (!c.TryGetProperty("types", out var types))
                {
                    continue;
                }

                var name = Text(c, "longText");
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

        /*
          ⚠️ `location.latitude` / `.longitude` at the top level. The legacy API
          nested it under `geometry` and spelled it `lat` / `lng`.
        */
        if (result.TryGetProperty("location", out var location))
        {
            if (location.TryGetProperty("latitude", out var la) && la.TryGetDecimal(out var lad)) lat = lad;
            if (location.TryGetProperty("longitude", out var ln) && ln.TryGetDecimal(out var lnd)) lng = lnd;
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

    /// <summary>
    /// One call to Places, with the key on the request rather than in the URL.
    /// </summary>
    /// <remarks>
    /// 🔴 THE KEY IS ADDED HERE AND NOWHERE ELSE, as the `X-Goog-Api-Key`
    /// header. Neither caller builds it into a URL, so it cannot reach an
    /// access log, a proxy log or an exception message that quotes the request
    /// line. The legacy implementation put it in the query string, which is
    /// how a key ends up somewhere nobody meant to put it.
    ///
    /// ⚠️ THE ERROR SHAPE CHANGED WITH THE API. The legacy endpoints answered
    /// HTTP 200 and hid the failure in a `status` field; Places (New) answers
    /// a real status code with `{ "error": { "code", "message", "status" } }`.
    /// BOTH are read below: the old shape because a project with the legacy
    /// API still enabled will keep producing it, and this method is the one
    /// place either can be noticed.
    /// </remarks>
    private async Task<JsonElement?> CallAsync(
        HttpRequestMessage request, string key, string what, CancellationToken cancellationToken)
    {
        try
        {
            using var cts = CancellationTokenSource.CreateLinkedTokenSource(cancellationToken);
            cts.CancelAfter(TimeSpan.FromSeconds(_options.TimeoutSeconds));

            using var _request = request;
            _request.Headers.TryAddWithoutValidation("X-Goog-Api-Key", key);

            using var response = await _http
                .SendAsync(_request, HttpCompletionOption.ResponseContentRead, cts.Token)
                .ConfigureAwait(false);

            using var doc = await response.Content
                .ReadFromJsonAsync<JsonDocument>(cts.Token)
                .ConfigureAwait(false);

            if (doc is null)
            {
                return null;
            }

            var root = doc.RootElement.Clone();

            /*
              🔴 THE NEW API'S REFUSAL, IN ITS OWN WORDS. Google's message names
              the actual cause — a legacy endpoint, a restricted key, billing —
              and it is the difference between "autocomplete returns nothing"
              and knowing why. It never contains the key.
            */
            if (!response.IsSuccessStatusCode)
            {
                var message = root.TryGetProperty("error", out var error)
                    ? Text(error, "message") ?? "(no message)"
                    : "(no body)";

                _logger.LogWarning(
                    "Places {What} refused with HTTP {Code}: {Message}. Falling back to the manual cascade.",
                    what, (int)response.StatusCode, message);

                return null;
            }

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
