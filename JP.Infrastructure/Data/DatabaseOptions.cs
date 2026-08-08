using System.ComponentModel.DataAnnotations;

namespace JP.Infrastructure.Data;

/// <summary>
/// Connection and resilience settings, bound from the <c>Database</c> section.
/// </summary>
/// <remarks>
/// Transport security lives here rather than inside each connection string so
/// there is one place to see — and one place to change — whether traffic to
/// SQL Server is encrypted, and whether an untrusted certificate is accepted.
/// Buried in three connection strings it is easy for a production deployment
/// to inherit a development setting unnoticed.
/// </remarks>
public sealed class DatabaseOptions
{
    public const string SectionName = "Database";

    /// <summary>
    /// Encrypt the connection. Defaults to <see langword="true"/>, matching
    /// Microsoft.Data.SqlClient 4.0+.
    /// </summary>
    public bool Encrypt { get; set; } = true;

    /// <summary>
    /// Accept the server's certificate without validating it.
    /// </summary>
    /// <remarks>
    /// <para>
    /// <b>Development only.</b> A local instance such as <c>localhost\TARUN</c>
    /// presents a self-signed certificate, which fails validation and makes
    /// every connection throw before it opens. Setting this to
    /// <see langword="true"/> keeps the traffic encrypted while skipping the
    /// trust check.
    /// </para>
    /// <para>
    /// Deliberately defaults to <see langword="false"/> so production has to
    /// opt in. Left on against a real server it defeats encryption's protection
    /// against a man-in-the-middle, since any certificate would be accepted.
    /// </para>
    /// </remarks>
    public bool TrustServerCertificate { get; set; }

    [Range(1, 300)]
    public int ConnectTimeoutSeconds { get; set; } = 15;

    [Range(1, 600)]
    public int CommandTimeoutSeconds { get; set; } = 30;

    /// <summary>
    /// Total attempts for a transient failure, including the first. 3 means
    /// the original call plus two retries.
    /// </summary>
    [Range(1, 10)]
    public int MaxRetryAttempts { get; set; } = 3;

    /// <summary>
    /// First backoff delay in milliseconds. Doubles per attempt:
    /// 200 → 400 → 800.
    /// </summary>
    [Range(10, 10_000)]
    public int RetryBaseDelayMs { get; set; } = 200;
}
