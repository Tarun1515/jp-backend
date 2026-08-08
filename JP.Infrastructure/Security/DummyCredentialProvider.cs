using JP.Core.Constants;
using JP.Core.Enums;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Security;

/// <summary>A decoy credential to verify against when no real one exists.</summary>
public sealed record DummyCredential(byte[] Hash, byte[] Salt, int Iterations, PasswordHashAlgorithm Algorithm);

/// <summary>Supplies the decoy credential used to make login constant-time.</summary>
public interface IDummyCredentialProvider
{
    DummyCredential Credential { get; }
}

/// <summary>
/// Defends the login endpoint against user enumeration by timing.
/// </summary>
/// <remarks>
/// <para>
/// Without this, login leaks account existence through the clock. An unknown
/// address returns in about 2 ms because no key derivation runs; a known one
/// takes roughly 200 ms because 210,000 PBKDF2 iterations do. That gap is
/// stable, easy to measure remotely, and lets an attacker enumerate which
/// addresses have accounts without ever guessing a password.
/// </para>
/// <para>
/// The generic "invalid credentials" message does nothing about it. The
/// message is identical either way; the timing is not.
/// </para>
/// <para>
/// So the not-found path verifies against this decoy instead, with the same
/// iteration count, and discards the result. Both paths then do the same work.
/// </para>
/// <para>
/// Generated once at startup from a random value when configuration does not
/// supply one, which is preferable: a generated decoy always uses the CURRENT
/// iteration count, so raising the work factor cannot leave the decoy cheaper
/// than the real thing — which would reopen the very gap it closes.
/// </para>
/// </remarks>
public sealed class DummyCredentialProvider : IDummyCredentialProvider
{
    public DummyCredential Credential { get; }

    public DummyCredentialProvider(
        IOptions<AuthOptions> options,
        IPasswordService passwordService,
        ILogger<DummyCredentialProvider> logger)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(passwordService);
        ArgumentNullException.ThrowIfNull(logger);

        var configured = TryReadFromConfiguration(options.Value, logger);

        if (configured is not null)
        {
            Credential = configured;
            logger.LogInformation("Login decoy credential loaded from configuration.");
            return;
        }

        // Hash of a fresh GUID: no password can match it, and nobody — including
        // this process a moment later — knows the input.
        var result = passwordService.HashPassword(Guid.NewGuid().ToString("N"));

        Credential = new DummyCredential(
            result.Hash, result.Salt, result.Iterations, result.Algorithm);

        logger.LogInformation(
            "Login decoy credential generated at startup with {Iterations} iterations.",
            result.Iterations);
    }

    private static DummyCredential? TryReadFromConfiguration(AuthOptions options, ILogger logger)
    {
        if (string.IsNullOrWhiteSpace(options.DummyPasswordHashBase64)
            || string.IsNullOrWhiteSpace(options.DummyPasswordSaltBase64))
        {
            return null;
        }

        try
        {
            var hash = Convert.FromBase64String(options.DummyPasswordHashBase64);
            var salt = Convert.FromBase64String(options.DummyPasswordSaltBase64);

            // Wrong widths would make the decoy derivation cheaper than the real
            // one and reopen the timing gap, so fall back rather than accept it.
            if (hash.Length != AppConstants.Password.HashBytes
                || salt.Length != AppConstants.Password.SaltBytes)
            {
                logger.LogWarning(
                    "Configured login decoy credential has the wrong size ({HashLength}/{SaltLength} bytes, "
                    + "expected {ExpectedHash}/{ExpectedSalt}). Generating one instead.",
                    hash.Length, salt.Length,
                    AppConstants.Password.HashBytes, AppConstants.Password.SaltBytes);

                return null;
            }

            return new DummyCredential(
                hash, salt, AppConstants.Password.Pbkdf2Iterations, PasswordHashAlgorithm.Pbkdf2Sha256);
        }
        catch (FormatException)
        {
            logger.LogWarning("Configured login decoy credential is not valid base64. Generating one instead.");
            return null;
        }
    }
}
