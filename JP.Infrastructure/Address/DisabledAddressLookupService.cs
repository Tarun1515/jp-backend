using JP.Domain.Address;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Address;

/// <summary>
/// The shipped default: no provider, and it says so.
/// </summary>
/// <remarks>
/// 🔴 THIS IS NOT A STUB. It is what runs until somebody deliberately
/// configures Places with a key, and the manual cascade beside it is a real,
/// verified path — not a degraded one.
///
/// ⚠️ IT ANSWERS, IT DOES NOT THROW. A caller asking for suggestions when the
/// provider is off gets an empty list, which the client already handles
/// because it is the same answer a search with no matches gives. Throwing
/// would make "no provider configured" an error the user sees mid-form.
///
/// ⚠️ AND IT LOGS ONCE, NOT PER KEYSTROKE. A disabled provider being asked is
/// normal, not a fault; logging every call would fill the log with a condition
/// somebody chose on purpose.
/// </remarks>
internal sealed class DisabledAddressLookupService : IAddressLookupService
{
    private readonly ILogger<DisabledAddressLookupService> _logger;
    private bool _logged;

    public DisabledAddressLookupService(ILogger<DisabledAddressLookupService> logger) =>
        _logger = logger;

    public bool IsAvailable => false;

    public Task<IReadOnlyList<AddressSuggestion>> SuggestAsync(
        string query, CancellationToken cancellationToken)
    {
        LogOnce();

        return Task.FromResult<IReadOnlyList<AddressSuggestion>>([]);
    }

    public Task<ResolvedAddress?> ResolveAsync(string placeId, CancellationToken cancellationToken)
    {
        LogOnce();

        return Task.FromResult<ResolvedAddress?>(null);
    }

    private void LogOnce()
    {
        if (_logged)
        {
            return;
        }

        _logged = true;

        _logger.LogInformation(
            "Address lookup is disabled ({Section}:Provider is not '{Provider}', or {EnvVar} is not set). "
            + "The manual State/District/Tehsil/City cascade is the only entry path, which is a supported configuration.",
            AddressLookupOptions.SectionName,
            AddressLookupOptions.ProviderGoogle,
            AddressLookupOptions.ApiKeyEnvironmentVariable);
    }
}
