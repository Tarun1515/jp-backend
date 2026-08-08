using System.Security.Cryptography;
using System.Text;
using JP.Core.Constants;
using JP.Core.Enums;

namespace JP.Infrastructure.Security;

/// <summary>
/// PBKDF2-HMAC-SHA256 password hashing.
/// </summary>
/// <remarks>
/// <para>
/// 210,000 iterations, a 32-byte cryptographically random salt per password,
/// and a 64-byte derived key — matching the varbinary widths in
/// <c>t_sso_user_credentials</c> exactly.
/// </para>
/// <para>
/// Comparison goes through <see cref="CryptographicOperations.FixedTimeEquals"/>.
/// A plain <c>==</c> or <c>SequenceEqual</c> returns as soon as two bytes
/// differ, and that timing difference is enough to recover a hash byte by
/// byte over many requests.
/// </para>
/// <para>
/// <b>Input length is capped at <see cref="AppConstants.Password.MaxLength"/>.</b>
/// PBKDF2 cost scales with input size, and the login endpoint is public and
/// unauthenticated. Without a cap, a handful of requests carrying multi-megabyte
/// "passwords" would pin every core for as long as the attacker cared to keep
/// sending them — a denial of service that needs no credentials and no volume.
/// </para>
/// </remarks>
public sealed class PasswordService : IPasswordService
{
    private const PasswordHashAlgorithm CurrentAlgorithm = PasswordHashAlgorithm.Pbkdf2Sha256;

    public PasswordHashResult HashPassword(string password)
    {
        if (string.IsNullOrEmpty(password))
        {
            throw new ArgumentException("Password must not be empty.", nameof(password));
        }

        if (password.Length < AppConstants.Password.MinLength)
        {
            throw new ArgumentException(
                $"Password must be at least {AppConstants.Password.MinLength} characters.",
                nameof(password));
        }

        // Throws rather than truncating. Silently hashing a prefix would mean a
        // user's stored credential does not correspond to the password they
        // typed, and the mismatch would only surface at their next sign-in.
        if (password.Length > AppConstants.Password.MaxLength)
        {
            throw new ArgumentException(
                $"Password must be at most {AppConstants.Password.MaxLength} characters.",
                nameof(password));
        }

        var salt = RandomNumberGenerator.GetBytes(AppConstants.Password.SaltBytes);

        var hash = Rfc2898DeriveBytes.Pbkdf2(
            password: Encoding.UTF8.GetBytes(password),
            salt: salt,
            iterations: AppConstants.Password.Pbkdf2Iterations,
            hashAlgorithm: HashAlgorithmName.SHA256,
            outputLength: AppConstants.Password.HashBytes);

        return new PasswordHashResult(
            hash,
            salt,
            AppConstants.Password.Pbkdf2Iterations,
            CurrentAlgorithm);
    }

    public bool VerifyPassword(
        string password,
        byte[] storedHash,
        byte[] storedSalt,
        int iterations,
        PasswordHashAlgorithm algorithm)
    {
        ArgumentNullException.ThrowIfNull(storedHash);
        ArgumentNullException.ThrowIfNull(storedSalt);

        // Over-length input is rejected BEFORE any key derivation runs — that
        // ordering is the whole point of the check. Returning false rather than
        // throwing keeps the login path uniform: an attacker probing with a
        // 10 MB password gets the same generic failure as a wrong password,
        // having consumed no measurable CPU either way.
        if (password.Length > AppConstants.Password.MaxLength)
        {
            return false;
        }

        // Malformed credential row: fail closed rather than throwing, so a
        // corrupt row reads as "wrong password" instead of a 500 that tells an
        // attacker they found something interesting.
        if (string.IsNullOrEmpty(password) || storedHash.Length == 0 || storedSalt.Length == 0 || iterations <= 0)
        {
            return false;
        }

        // Guards against a tampered or corrupt Iterations column being used to
        // turn verification itself into the expensive operation.
        if (iterations > AppConstants.Password.MaxVerifyIterations)
        {
            return false;
        }

        if (algorithm != PasswordHashAlgorithm.Pbkdf2Sha256)
        {
            throw new NotSupportedException(
                $"Password hash algorithm '{algorithm}' is not supported by this build.");
        }

        // Derive to the stored length, not the current constant, so credentials
        // written under a different output size still verify.
        var computed = Rfc2898DeriveBytes.Pbkdf2(
            password: Encoding.UTF8.GetBytes(password),
            salt: storedSalt,
            iterations: iterations,
            hashAlgorithm: HashAlgorithmName.SHA256,
            outputLength: storedHash.Length);

        return CryptographicOperations.FixedTimeEquals(computed, storedHash);
    }

    public bool NeedsRehash(int iterations, PasswordHashAlgorithm algorithm)
    {
        return algorithm != CurrentAlgorithm
            || iterations < AppConstants.Password.Pbkdf2Iterations;
    }
}
