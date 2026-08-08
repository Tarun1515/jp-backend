namespace JP.Core.Enums;

/// <summary>
/// Mirrors <c>m_sso_hash_algorithms</c>.
/// </summary>
/// <remarks>
/// The algorithm id is stored per credential row, not assumed globally. That
/// is what makes it possible to migrate to a different KDF later: new
/// passwords get the new id, existing ones keep verifying under the old one,
/// and nobody is locked out.
/// </remarks>
public enum PasswordHashAlgorithm
{
    Pbkdf2Sha256 = 1,
}
