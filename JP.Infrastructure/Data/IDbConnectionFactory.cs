using System.Data.Common;
using JP.Core.Enums;

namespace JP.Infrastructure.Data;

/// <summary>
/// Hands out connections to one of the three databases.
/// </summary>
/// <remarks>
/// Each call opens a connection to exactly one database. There is deliberately
/// no API here for spanning two of them: a transaction that crossed a database
/// boundary would need MSDTC and would couple the three deployments together.
/// Cross-database work is orchestrated in the service layer instead, one
/// committed transaction per database.
/// </remarks>
public interface IDbConnectionFactory
{
    /// <summary>Creates and opens a connection. The caller disposes it.</summary>
    Task<DbConnection> CreateOpenConnectionAsync(JpDatabase database, CancellationToken cancellationToken = default);

    /// <summary>Creates a closed connection. Prefer <see cref="CreateOpenConnectionAsync"/>.</summary>
    DbConnection CreateConnection(JpDatabase database);
}
