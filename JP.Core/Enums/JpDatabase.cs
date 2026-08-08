namespace JP.Core.Enums;

/// <summary>
/// Selects which of the three databases a repository call opens a connection to.
/// </summary>
/// <remarks>
/// Passing this explicitly on every call is what makes the "no cross-database
/// transaction" rule visible in code: a method can only ever be inside one of
/// these at a time. Multi-database writes are orchestrated by the service
/// layer, one committed transaction per database.
/// </remarks>
public enum JpDatabase
{
    /// <summary>Identity: users, credentials, tokens, roles, permissions.</summary>
    Sso = 1,

    /// <summary>Master data and the approval engine.</summary>
    Mdm = 2,

    /// <summary>Business data: schools, teachers, jobs, applications.</summary>
    App = 3,
}
