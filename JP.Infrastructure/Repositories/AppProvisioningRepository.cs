using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

internal sealed class ProvisionTeacherResult : ProcResult
{
    public Guid? TeacherUid { get; set; }
}

internal interface IAppProvisioningRepository
{
    Task<ProvisionTeacherResult> ProvisionTeacherProfileAsync(
        Guid userUid, string? fullName, int planId, CancellationToken cancellationToken);
}

/// <summary>
/// The jp_app writes that follow an account being created in jp_sso.
/// </summary>
/// <remarks>
/// <para>
/// ⚠️ Separate from <see cref="ProvisioningRepository"/>, which serves
/// JP.App.Api and provisions a school from an approval. This one is used by
/// JP.Sso.Api at signup.
/// </para>
/// <para>
/// 🔴 THIS IS WHY JP.Sso.Api NOW HAS AN App CONNECTION STRING.
/// </para>
/// <para>
/// Decision 2D established the rule when JP.App.Api gained an Sso connection:
/// an API that orchestrates across databases needs a connection to every
/// database it orchestrates, not just its own. The identity API now orchestrates
/// exactly one cross-database step — creating the profile that must exist from
/// the moment a teacher account does — so it gets the same treatment.
/// </para>
/// <para>
/// The alternative was an HTTP call from JP.Sso.Api to JP.App.Api after signup.
/// That trades a connection string for a service-to-service dependency on the
/// registration path: a slow or restarting App API would then make signups fail
/// or hang, which is a far worse failure than the one being fixed.
/// </para>
/// </remarks>
internal sealed class AppProvisioningRepository : BaseRepository, IAppProvisioningRepository
{
    public AppProvisioningRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<AppProvisioningRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.App;

    /// <summary>
    /// Creates a teacher's profile and their free plan, in one transaction.
    /// </summary>
    /// <remarks>
    /// Idempotent on <paramref name="userUid"/>: called twice, the second call
    /// returns Code = ALREADY_PROVISIONED with Status = 1 rather than throwing.
    /// That is what makes it safe to call from a retry, a repair job, or a
    /// first sign-in.
    /// </remarks>
    public Task<ProvisionTeacherResult> ProvisionTeacherProfileAsync(
        Guid userUid,
        string? fullName,
        int planId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@FullName", fullName, DbType.String, size: 150);
        p.Add("@PlanId", planId, DbType.Int32);

        return QuerySingleAsync<ProvisionTeacherResult>(
            "USP_ProvisionTeacherProfile", p, cancellationToken);
    }
}
