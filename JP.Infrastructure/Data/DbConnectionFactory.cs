using System.Data.Common;
using JP.Core.Constants;
using JP.Core.Enums;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Data;

/// <summary>
/// Builds the configured connection strings once at startup and hands out
/// connections from them.
/// </summary>
/// <remarks>
/// <para>
/// No password is ever stored in appsettings.json. For SQL authentication the
/// password is read from the <c>SQL_PASSWORD</c> environment variable and
/// injected here; the checked-in configuration holds only server, database and
/// options. Connection strings using <c>Integrated Security=true</c> — the
/// local development default against <c>localhost\TARUN</c> — need no password
/// and are used as-is.
/// </para>
/// <para>
/// Only the databases an application actually configures are built. JP.Sso.Api
/// deploys standalone and configures <c>Sso</c> alone; requiring it to carry
/// credentials for <c>jp_mdm</c> and <c>jp_app</c> that it never opens would
/// undo that separation. Asking for an unconfigured database fails with a
/// message naming the missing key.
/// </para>
/// </remarks>
public sealed class DbConnectionFactory : IDbConnectionFactory
{
    /// <summary>Environment variable holding the SQL login password.</summary>
    public const string SqlPasswordEnvironmentVariable = "SQL_PASSWORD";

    /// <summary>What SqlClient uses when no application name is supplied.</summary>
    private const string DefaultSqlClientApplicationName = ".NET SqlClient Data Provider";

    private static readonly IReadOnlyDictionary<JpDatabase, string> ConfigurationKeys =
        new Dictionary<JpDatabase, string>
        {
            [JpDatabase.Sso] = AppConstants.ConnectionNames.Sso,
            [JpDatabase.Mdm] = AppConstants.ConnectionNames.Mdm,
            [JpDatabase.App] = AppConstants.ConnectionNames.App,
        };

    private readonly IReadOnlyDictionary<JpDatabase, string> _connectionStrings;

    public DbConnectionFactory(
        IConfiguration configuration,
        IOptions<DatabaseOptions> databaseOptions,
        IHostEnvironment environment)
    {
        ArgumentNullException.ThrowIfNull(configuration);
        ArgumentNullException.ThrowIfNull(databaseOptions);
        ArgumentNullException.ThrowIfNull(environment);

        var options = databaseOptions.Value;
        var password = Environment.GetEnvironmentVariable(SqlPasswordEnvironmentVariable);
        var connectionStrings = new Dictionary<JpDatabase, string>();

        foreach (var (database, key) in ConfigurationKeys)
        {
            var raw = configuration.GetConnectionString(key);

            if (string.IsNullOrWhiteSpace(raw))
            {
                // Not configured for this application. Legitimate, and only a
                // problem if something later asks for this database.
                continue;
            }

            connectionStrings[database] = Build(raw, key, password, options, environment.ApplicationName);
        }

        if (connectionStrings.Count == 0)
        {
            throw new InvalidOperationException(
                "No database connection strings are configured. Add at least one of " +
                $"'{AppConstants.ConnectionNames.Sso}', '{AppConstants.ConnectionNames.Mdm}' or " +
                $"'{AppConstants.ConnectionNames.App}' under \"ConnectionStrings\" in appsettings.json.");
        }

        _connectionStrings = connectionStrings;
    }

    public DbConnection CreateConnection(JpDatabase database)
    {
        if (!_connectionStrings.TryGetValue(database, out var connectionString))
        {
            var key = ConfigurationKeys.TryGetValue(database, out var name) ? name : database.ToString();

            throw new InvalidOperationException(
                $"This application has no connection string for the '{database}' database. " +
                $"Add \"ConnectionStrings:{key}\" to its appsettings.json.");
        }

        return new SqlConnection(connectionString);
    }

    public async Task<DbConnection> CreateOpenConnectionAsync(
        JpDatabase database,
        CancellationToken cancellationToken = default)
    {
        var connection = CreateConnection(database);
        try
        {
            await connection.OpenAsync(cancellationToken).ConfigureAwait(false);
            return connection;
        }
        catch
        {
            // OpenAsync failed, but the SqlConnection object already exists and
            // holds a pool slot. Without this dispose a brief SQL outage leaks
            // one connection per failed attempt and exhausts the pool, so
            // nothing reconnects even after the server comes back.
            await connection.DisposeAsync().ConfigureAwait(false);
            throw;
        }
    }

    /// <summary>
    /// Validates one connection string, applies transport and identification
    /// settings, and injects the password when SQL authentication is used.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Encryption settings come from <see cref="DatabaseOptions"/> and are
    /// applied here rather than being written into each connection string, so
    /// the security posture is declared once and visibly.
    /// </para>
    /// <para>
    /// Throws at construction time — that is, at application startup — rather
    /// than on the first request that needs the database. A half-configured
    /// environment should refuse to boot.
    /// </para>
    /// </remarks>
    private static string Build(
        string raw,
        string key,
        string? password,
        DatabaseOptions options,
        string applicationName)
    {
        var builder = new SqlConnectionStringBuilder(raw);

        // ---- transport security ------------------------------------------
        // SqlClient 4.0+ defaults Encrypt=true. Against a local instance with a
        // self-signed certificate that fails validation and no connection ever
        // opens, so TrustServerCertificate must be an explicit, configured
        // decision — never a hardcoded one, or production inherits it.
        builder.Encrypt = options.Encrypt;
        builder.TrustServerCertificate = options.TrustServerCertificate;
        builder.ConnectTimeout = options.ConnectTimeoutSeconds;

        // ---- session identification --------------------------------------
        // Shows up in sys.dm_exec_sessions.program_name and in Profiler, so a
        // rogue query can be traced to the API that issued it. A value already
        // present in the connection string wins.
        if (string.IsNullOrWhiteSpace(builder.ApplicationName)
            || string.Equals(builder.ApplicationName, DefaultSqlClientApplicationName, StringComparison.Ordinal))
        {
            builder.ApplicationName = applicationName;
        }

        // ---- credentials --------------------------------------------------
        if (builder.IntegratedSecurity)
        {
            // Windows authentication — nothing to inject.
            return builder.ConnectionString;
        }

        if (string.IsNullOrEmpty(password))
        {
            throw new InvalidOperationException(
                $"Connection string '{key}' uses SQL authentication but the " +
                $"{SqlPasswordEnvironmentVariable} environment variable is not set. " +
                $"Set it with: $env:{SqlPasswordEnvironmentVariable} = \"your-password\"");
        }

        builder.Password = password;
        return builder.ConnectionString;
    }
}
