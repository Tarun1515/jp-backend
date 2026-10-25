namespace JP.Domain.Address;

/// <summary>
/// One suggestion while somebody is typing an address.
/// </summary>
/// <remarks>
/// Deliberately thin. A suggestion is a label and a token to fetch the real
/// thing with — nothing is stored from it, and nothing downstream may depend
/// on its shape, because the provider owns it.
/// </remarks>
public sealed record AddressSuggestion
{
    /// <summary>What the person reads in the list.</summary>
    public string Description { get; init; } = string.Empty;

    /// <summary>The provider's token for this place. Opaque to us.</summary>
    public string PlaceId { get; init; } = string.Empty;

    /// <summary>The bold part — the place's own name, where the provider gives one.</summary>
    public string? MainText { get; init; }

    /// <summary>The rest — district, state, country.</summary>
    public string? SecondaryText { get; init; }
}

/// <summary>
/// An address resolved into OUR shape, whichever path produced it.
/// </summary>
/// <remarks>
/// 🔴 THIS TYPE IS THE WHOLE POINT OF THE SEAM.
///
/// A row entered through Places autocomplete and a row entered through the
/// manual cascade must be indistinguishable once stored, apart from
/// <see cref="GooglePlaceId"/> and the coordinates being present on one. If
/// they differ, the product has two kinds of address, and every read written
/// afterwards has to know which it is looking at.
///
/// So the provider's response is converted HERE, once, into ids from our own
/// masters plus free text — and never leaks its own vocabulary any further in.
///
/// ⚠️ EVERY ID IS NULLABLE, INCLUDING THE STATE. A provider can return a place
/// in a state we have not seeded; that is a real answer, not an error. What we
/// could not match is kept as text in <see cref="AreaOrVillage"/> and
/// <see cref="FormattedAddress"/>, with the coordinates, so the address is
/// still complete and honest — it simply has no master row to filter on yet.
/// </remarks>
public sealed record ResolvedAddress
{
    public int? StateId { get; init; }

    public int? DistrictId { get; init; }

    public int? TehsilId { get; init; }

    public int? CityId { get; init; }

    /// <summary>
    /// The locality, when no master row fits — a village, a colony, a sector.
    /// </summary>
    /// <remarks>
    /// Never a filter the product promises to match on. It is shown, and
    /// searched as text. ADDRESS_DESIGN.md §2 says why this is not a master.
    /// </remarks>
    public string? AreaOrVillage { get; init; }

    public string? AddressLine1 { get; init; }

    public string? Pincode { get; init; }

    public decimal? Latitude { get; init; }

    public decimal? Longitude { get; init; }

    /// <summary>The provider's stable id, when a provider produced this.</summary>
    public string? GooglePlaceId { get; init; }

    /// <summary>The provider's own one-line rendering, kept for display.</summary>
    public string? FormattedAddress { get; init; }

    /// <summary>
    /// What the provider named that we could NOT match to a master row.
    /// </summary>
    /// <remarks>
    /// 🔒 SHOWN TO THE USER, NOT SWALLOWED. "We could not find the district
    /// 'Faridabad Division' in our list — please pick it below" is a sentence
    /// somebody can act on. Silently dropping it produces an address that
    /// looks complete and has lost a level.
    /// </remarks>
    public IReadOnlyList<string> Unmatched { get; init; } = [];
}
