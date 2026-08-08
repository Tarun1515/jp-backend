using System.Data;
using System.Data.Common;
using Dapper;
using JP.Core.Constants;
using JP.Core.Enums;
using JP.Core.Exceptions;
using Microsoft.Data.SqlClient;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Data;

/// <summary>
/// Base class for every repository in the solution.
/// </summary>
/// <remarks>
/// <para>
/// Note what is absent: there is no method here that accepts a SQL string.
/// Every helper takes a stored procedure name plus
/// <see cref="DynamicParameters"/>, and hardcodes
/// <see cref="CommandType.StoredProcedure"/>. "All data access via stored
/// procedures, never inline SQL" is therefore not a convention anyone has to
/// remember — a derived repository has no API through which to break it.
/// </para>
/// <para>
/// SQL errors raised deliberately by a procedure (THROW with a number of
/// 50000 or above) are translated into <see cref="BusinessRuleException"/>, so
/// a validation failure written in T-SQL reaches the client as a clean
/// business message instead of a 500.
/// </para>
/// <para>
/// A short retry runs for transient faults only — see
/// <see cref="TransientSqlErrorNumbers"/>. Nothing that represents a decision
/// the database made (duplicate key, foreign key, a procedure's own THROW) is
/// ever retried; repeating those would just fail again more slowly.
/// </para>
/// </remarks>
public abstract class BaseRepository
{
    /// <summary>
    /// SQL error numbers that are worth trying again.
    /// </summary>
    /// <remarks>
    /// <list type="bullet">
    ///   <item><c>1205</c> — chosen as deadlock victim. The canonical retry case:
    ///   the transaction was rolled back completely and re-running usually wins.</item>
    ///   <item><c>-2</c> — command timeout. See the caveat on
    ///   <see cref="IsTransient"/>; this one is not as safe as the others.</item>
    ///   <item><c>4060</c> — cannot open the database (often still starting up).</item>
    ///   <item><c>40197, 40501, 40613</c> — Azure SQL: service error, throttling,
    ///   database unavailable.</item>
    ///   <item><c>49918, 49919, 49920</c> — Azure SQL: cannot process request,
    ///   not enough resources, too busy.</item>
    /// </list>
    /// The Azure numbers are inert against a local SQL Server 2019 instance and
    /// are listed so a later move to Azure SQL needs no code change.
    /// </remarks>
    private static readonly HashSet<int> TransientSqlErrorNumbers =
    [
        1205,   // deadlock victim
        -2,     // timeout
        4060,   // cannot open database
        40197,  // service error processing request
        40501,  // service busy / throttling
        40613,  // database unavailable
        49918,  // cannot process request, not enough resources
        49919,  // cannot process create or update request
        49920,  // cannot process request, too many operations
    ];

    private readonly IDbConnectionFactory _connectionFactory;
    private readonly ILogger _logger;
    private readonly DatabaseOptions _options;

    protected BaseRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger logger)
    {
        ArgumentNullException.ThrowIfNull(databaseOptions);

        _connectionFactory = connectionFactory ?? throw new ArgumentNullException(nameof(connectionFactory));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _options = databaseOptions.Value;
    }

    /// <summary>Which database this repository talks to.</summary>
    protected abstract JpDatabase Database { get; }

    /// <summary>Command timeout in seconds. Override per repository if a report needs longer.</summary>
    protected virtual int CommandTimeoutSeconds => _options.CommandTimeoutSeconds;

    // -----------------------------------------------------------------------
    // Query helpers
    // -----------------------------------------------------------------------

    /// <summary>Runs a procedure returning many rows.</summary>
    protected Task<IReadOnlyList<T>> QueryAsync<T>(
        string storedProcedure,
        DynamicParameters? parameters = null,
        CancellationToken cancellationToken = default)
    {
        return RunAsync<IReadOnlyList<T>>(storedProcedure, async connection =>
        {
            var rows = await connection
                .QueryAsync<T>(Command(storedProcedure, parameters, cancellationToken))
                .ConfigureAwait(false);

            return rows.AsList();
        }, cancellationToken);
    }

    /// <summary>Runs a procedure returning at most one row.</summary>
    protected Task<T?> QueryFirstOrDefaultAsync<T>(
        string storedProcedure,
        DynamicParameters? parameters = null,
        CancellationToken cancellationToken = default)
    {
        return RunAsync(storedProcedure, connection =>
            connection.QueryFirstOrDefaultAsync<T>(Command(storedProcedure, parameters, cancellationToken)),
            cancellationToken);
    }

    /// <summary>
    /// Runs a procedure that must return exactly one row.
    /// </summary>
    /// <exception cref="NotFoundException">The procedure returned no rows.</exception>
    protected async Task<T> QuerySingleAsync<T>(
        string storedProcedure,
        DynamicParameters? parameters = null,
        CancellationToken cancellationToken = default)
    {
        var result = await QueryFirstOrDefaultAsync<T>(storedProcedure, parameters, cancellationToken)
            .ConfigureAwait(false);

        return result ?? throw new NotFoundException("The requested record was not found.");
    }

    /// <summary>
    /// Runs a procedure returning several result sets.
    /// </summary>
    /// <remarks>
    /// The reader is consumed inside <paramref name="read"/>, while the
    /// connection is still open. Do not let a <see cref="SqlMapper.GridReader"/>
    /// escape the callback.
    /// </remarks>
    protected Task<TResult> QueryMultipleAsync<TResult>(
        string storedProcedure,
        Func<SqlMapper.GridReader, Task<TResult>> read,
        DynamicParameters? parameters = null,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(read);

        return RunAsync(storedProcedure, async connection =>
        {
            await using var grid = await connection
                .QueryMultipleAsync(Command(storedProcedure, parameters, cancellationToken))
                .ConfigureAwait(false);

            return await read(grid).ConfigureAwait(false);
        }, cancellationToken);
    }

    // -----------------------------------------------------------------------
    // Write helpers
    // -----------------------------------------------------------------------

    /// <summary>Runs a procedure for its effect. Returns rows affected.</summary>
    /// <remarks>
    /// Output parameters are read back off the same <see cref="DynamicParameters"/>
    /// instance the caller passed in, using <c>parameters.Get&lt;T&gt;("@Name")</c>.
    /// </remarks>
    protected Task<int> ExecuteAsync(
        string storedProcedure,
        DynamicParameters? parameters = null,
        CancellationToken cancellationToken = default)
    {
        return RunAsync(storedProcedure, connection =>
            connection.ExecuteAsync(Command(storedProcedure, parameters, cancellationToken)),
            cancellationToken);
    }

    /// <summary>Runs a procedure returning a single scalar value.</summary>
    protected Task<T?> ExecuteScalarAsync<T>(
        string storedProcedure,
        DynamicParameters? parameters = null,
        CancellationToken cancellationToken = default)
    {
        return RunAsync(storedProcedure, connection =>
            connection.ExecuteScalarAsync<T>(Command(storedProcedure, parameters, cancellationToken)),
            cancellationToken);
    }

    // -----------------------------------------------------------------------
    // Plumbing
    // -----------------------------------------------------------------------

    private CommandDefinition Command(
        string storedProcedure,
        DynamicParameters? parameters,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(storedProcedure))
        {
            throw new ArgumentException("A stored procedure name is required.", nameof(storedProcedure));
        }

        return new CommandDefinition(
            commandText: storedProcedure,
            parameters: parameters,
            commandType: CommandType.StoredProcedure,
            commandTimeout: CommandTimeoutSeconds,
            cancellationToken: cancellationToken);
    }

    /// <summary>
    /// Opens a connection, runs the operation with a transient-fault retry, and
    /// translates deliberate SQL errors into domain exceptions.
    /// </summary>
    /// <remarks>
    /// A fresh connection is opened per attempt. Reusing a connection that has
    /// just faulted would retry through a broken pipe.
    /// </remarks>
    private async Task<TResult> RunAsync<TResult>(
        string storedProcedure,
        Func<DbConnection, Task<TResult>> operation,
        CancellationToken cancellationToken)
    {
        for (var attempt = 1; ; attempt++)
        {
            try
            {
                await using var connection = await _connectionFactory
                    .CreateOpenConnectionAsync(Database, cancellationToken)
                    .ConfigureAwait(false);

                return await operation(connection).ConfigureAwait(false);
            }
            // Transient. Checked FIRST so a deadlock or timeout never falls
            // through to the generic handlers below.
            catch (SqlException ex) when (IsTransient(ex)
                                          && attempt < _options.MaxRetryAttempts
                                          && !cancellationToken.IsCancellationRequested)
            {
                var delay = BackoffDelay(attempt);

                _logger.LogWarning(
                    "Transient SQL error {SqlErrorNumber} from '{StoredProcedure}' on '{Database}' " +
                    "(attempt {Attempt} of {MaxAttempts}). Retrying in {DelayMs} ms. {SqlMessage}",
                    ex.Number, storedProcedure, Database, attempt, _options.MaxRetryAttempts,
                    (int)delay.TotalMilliseconds, ex.Message);

                await Task.Delay(delay, cancellationToken).ConfigureAwait(false);
            }
            // 50000+ is the range THROW inside a procedure uses: a rule the
            // procedure enforced on purpose, with a message meant for the user.
            catch (SqlException ex) when (ex.Number >= 50000)
            {
                throw new BusinessRuleException(ex.Message);
            }
            // 2627 unique constraint, 2601 duplicate key in a unique index.
            catch (SqlException ex) when (ex.Number is 2627 or 2601)
            {
                throw new BusinessRuleException(
                    "A record with these details already exists.",
                    ErrorCodes.DuplicateRecord);
            }
            // 547 foreign key / check constraint violation.
            catch (SqlException ex) when (ex.Number == 547)
            {
                throw new BusinessRuleException(
                    "This operation references a record that does not exist, or is still in use.");
            }
            catch (SqlException ex)
            {
                // A genuine fault, or a transient one that exhausted its retries.
                // Wrapped so the procedure name reaches the log, which is the
                // single most useful detail when diagnosing one.
                if (IsTransient(ex))
                {
                    _logger.LogError(ex,
                        "Transient SQL error {SqlErrorNumber} from '{StoredProcedure}' on '{Database}' " +
                        "did not clear after {MaxAttempts} attempts.",
                        ex.Number, storedProcedure, Database, _options.MaxRetryAttempts);
                }

                throw new InvalidOperationException(
                    $"Stored procedure '{storedProcedure}' failed on database '{Database}' " +
                    $"(SQL error {ex.Number}).", ex);
            }
        }
    }

    /// <summary>
    /// Whether a SQL error is worth another attempt.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Safe because every write procedure in this system owns its own
    /// transaction: a failed attempt has rolled back completely, so re-running
    /// it starts from the same state the first attempt saw.
    /// </para>
    /// <para>
    /// <b>Caveat on error -2 (timeout).</b> A command timeout is raised by the
    /// client when it stops waiting; it does not cancel the batch on the
    /// server. If the procedure was merely slow rather than stuck, it may still
    /// be running — and committing — while the retry issues it a second time.
    /// The protections against that are elsewhere and must stay in place: the
    /// filtered unique indexes on business keys (a duplicate insert surfaces as
    /// 2627 rather than a second row), and the RowVersion check on updates.
    /// A procedure that can neither be made idempotent nor guarded by a unique
    /// index should override <see cref="DatabaseOptions.MaxRetryAttempts"/> to
    /// 1 for its repository.
    /// </para>
    /// </remarks>
    private static bool IsTransient(SqlException exception) =>
        TransientSqlErrorNumbers.Contains(exception.Number);

    /// <summary>
    /// Exponential backoff with jitter: ~200 ms, ~400 ms, ~800 ms.
    /// </summary>
    /// <remarks>
    /// The jitter matters more than the backoff. Without it, every request that
    /// deadlocked against the same rows waits an identical interval and they
    /// all collide again on the retry — the backoff synchronises the callers
    /// instead of separating them.
    /// </remarks>
    private TimeSpan BackoffDelay(int attempt)
    {
        var baseDelayMs = _options.RetryBaseDelayMs * Math.Pow(2, attempt - 1);

        // +/- 20%
        var jitterFactor = 1 + ((Random.Shared.NextDouble() * 0.4) - 0.2);

        return TimeSpan.FromMilliseconds(baseDelayMs * jitterFactor);
    }
}
