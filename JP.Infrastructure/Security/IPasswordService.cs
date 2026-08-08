using JP.Core.Enums;

namespace JP.Infrastructure.Security;

/// <summary>The result of hashing a password, ready to persist.</summary>
/// <param name="Hash">64 bytes — <c>t_sso_user_credentials.PasswordHash varbinary(64)</c>.</param>
/// <param name="Salt">32 bytes — <c>t_sso_user_credentials.PasswordSalt varbinary(32)</c>.</param>
/// <param name="Iterations">Stored alongside the hash so verification can reproduce it.</param>
/// <param name="Algorithm">Stored alongside the hash so the KDF can change later.</param>
public sealed record PasswordHashResult(
    byte[] Hash,
    byte[] Salt,
    int Iterations,
    PasswordHashAlgorithm Algorithm);

/// <summary>Password hashing and verification.</summary>
public interface IPasswordService
{
    /// <summary>Hashes a new password with the current algorithm and cost.</summary>
    /// <exception cref="ArgumentException">
    /// The password is empty, shorter than
    /// <see cref="JP.Core.Constants.AppConstants.Password.MinLength"/>, or longer
    /// than <see cref="JP.Core.Constants.AppConstants.Password.MaxLength"/>.
    /// </exception>
    PasswordHashResult HashPassword(string password);

    /// <summary>
    /// Verifies a password against a stored credential row.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <paramref name="iterations"/> and <paramref name="algorithm"/> come from
    /// the stored row rather than from current configuration. That is what
    /// allows the work factor to be raised without invalidating every existing
    /// password.
    /// </para>
    /// <para>
    /// Returns <see langword="false"/> — never throws — for input longer than
    /// <see cref="JP.Core.Constants.AppConstants.Password.MaxLength"/>, and
    /// rejects it before any key derivation runs. Login must not become an
    /// amplification vector, and must not answer differently for an over-length
    /// password than for a wrong one.
    /// </para>
    /// </remarks>
    bool VerifyPassword(
        string password,
        byte[] storedHash,
        byte[] storedSalt,
        int iterations,
        PasswordHashAlgorithm algorithm);

    /// <summary>
    /// Whether a credential was hashed below current strength and should be
    /// re-hashed. Call after a successful login, while the plaintext is still
    /// in hand.
    /// </summary>
    bool NeedsRehash(int iterations, PasswordHashAlgorithm algorithm);
}
