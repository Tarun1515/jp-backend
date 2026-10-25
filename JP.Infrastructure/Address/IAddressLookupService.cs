using JP.Domain.Address;

namespace JP.Infrastructure.Address;

/// <summary>
/// Address autocomplete and resolution, behind a seam.
/// </summary>
/// <remarks>
/// 🔴 THE SEAM EXISTS SO THE PRODUCT DOES NOT DEPEND ON GOOGLE.
///
/// Two implementations ship:
///
/// <list type="bullet">
/// <item><c>GooglePlacesAddressLookupService</c> — real autocomplete.</item>
/// <item><c>DisabledAddressLookupService</c> — answers "not available",
/// cleanly, every time.</item>
/// </list>
///
/// The second is not a stub for tests. It is the SHIPPED DEFAULT, and the
/// manual cascade is a first-class path that is verified with the switch OFF.
/// A deployment with no key must be fully usable, because the first one will
/// be.
///
/// ⚠️ <see cref="IsAvailable"/> IS PART OF THE CONTRACT, not an implementation
/// detail. The client needs to know whether to offer the search box at all —
/// offering a box that always returns nothing is worse than not offering it
/// (the same argument 2.47 makes about an empty dropdown).
/// </remarks>
public interface IAddressLookupService
{
    /// <summary>
    /// Whether a provider is configured and usable right now.
    /// </summary>
    bool IsAvailable { get; }

    /// <summary>
    /// Suggestions for a partial address.
    /// </summary>
    /// <remarks>
    /// Returns an EMPTY LIST rather than throwing when the provider is off,
    /// unreachable or slow. A failed lookup must degrade to the dropdowns, not
    /// to an error page — somebody is mid-registration.
    /// </remarks>
    Task<IReadOnlyList<AddressSuggestion>> SuggestAsync(
        string query, CancellationToken cancellationToken);

    /// <summary>
    /// One suggestion, resolved into our own shape.
    /// </summary>
    /// <returns>
    /// <c>null</c> when the provider is off or the place could not be fetched.
    /// </returns>
    Task<ResolvedAddress?> ResolveAsync(
        string placeId, CancellationToken cancellationToken);
}
