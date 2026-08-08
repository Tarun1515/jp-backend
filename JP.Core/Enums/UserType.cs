namespace JP.Core.Enums;

/// <summary>
/// Mirrors <c>m_sso_user_types</c>.
/// </summary>
/// <remarks>
/// The numeric values are seeded database rows and are therefore contract.
/// Never renumber; add new members with new ids only.
/// </remarks>
public enum UserType
{
    Admin = 1,
    School = 2,
    Teacher = 3,
}
