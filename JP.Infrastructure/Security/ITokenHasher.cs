namespace JP.Infrastructure.Security;

/// <summary>
/// A generated token: the plaintext to hand out, and the hash to store.
/// </summary>
/// <param name="PlainText">
/// Goes to the client, or into the email. Never persisted, never logged.
/// </param>
/// <param name="Hash">
/// Goes into <c>t_sso_user_tokens.TokenHash</c>. 64 hex characters, well
/// inside the varchar(128) column.
/// </param>
public sealed record SecureToken(string PlainText, string Hash);

/// <summary>
/// Generates and hashes the opaque tokens — refresh, password reset, email
/// verification, invite.
/// </summary>
/// <remarks>
/// Tokens are stored hashed for the same reason passwords are: a leaked
/// database backup must not hand over working credentials. Lookup is by hash,
/// so the plaintext exists only in transit.
/// <para>
/// A plain SHA-256 is the right tool here and PBKDF2 would be the wrong one.
/// These tokens are 64 bytes of cryptographic randomness, not user-chosen
/// secrets, so there is no dictionary to slow an attacker down against.
/// </para>
/// </remarks>
public interface ITokenHasher
{
    /// <summary>Generates a new random token and its hash.</summary>
    SecureToken CreateToken();

    /// <summary>Hashes a token so it can be looked up in the database.</summary>
    string Hash(string token);

    /// <summary>Constant-time comparison of a supplied token against a stored hash.</summary>
    bool Verify(string token, string storedHash);
}
