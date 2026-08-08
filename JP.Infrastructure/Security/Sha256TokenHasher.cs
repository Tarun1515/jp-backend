using System.Security.Cryptography;
using System.Text;
using JP.Core.Constants;

namespace JP.Infrastructure.Security;

/// <summary>SHA-256 implementation of <see cref="ITokenHasher"/>.</summary>
public sealed class Sha256TokenHasher : ITokenHasher
{
    public SecureToken CreateToken()
    {
        var bytes = RandomNumberGenerator.GetBytes(AppConstants.Tokens.RandomTokenBytes);

        // Base64Url: safe in a URL and in an email link without escaping, which
        // matters for password-reset and invite links.
        var plainText = Base64UrlEncode(bytes);

        return new SecureToken(plainText, Hash(plainText));
    }

    public string Hash(string token)
    {
        if (string.IsNullOrEmpty(token))
        {
            throw new ArgumentException("Token must not be empty.", nameof(token));
        }

        var hash = SHA256.HashData(Encoding.UTF8.GetBytes(token));
        return Convert.ToHexString(hash).ToLowerInvariant();
    }

    public bool Verify(string token, string storedHash)
    {
        if (string.IsNullOrEmpty(token) || string.IsNullOrEmpty(storedHash))
        {
            return false;
        }

        var computed = Encoding.UTF8.GetBytes(Hash(token));
        var stored = Encoding.UTF8.GetBytes(storedHash);

        return CryptographicOperations.FixedTimeEquals(computed, stored);
    }

    private static string Base64UrlEncode(byte[] bytes)
    {
        return Convert.ToBase64String(bytes)
            .TrimEnd('=')
            .Replace('+', '-')
            .Replace('/', '_');
    }
}
