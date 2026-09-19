using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

/// <summary>
/// The masters that live in <c>jp_app</c> rather than <c>jp_mdm</c>.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 WHY THIS IS A SECOND REPOSITORY AND NOT A METHOD ON
/// <see cref="IMasterRepository"/>.
/// </para>
/// <para>
/// <see cref="BaseRepository.Database"/> is one value per class, by design —
/// that is what makes "a call is inside exactly one database" visible in the
/// type system rather than a convention somebody has to hold in their head
/// (2.2). Five masters live in jp_app because <c>t_app_jobs</c> and
/// <c>t_app_feature_ledger</c> carry physical foreign keys to them and a
/// physical FK may not cross a database. So the read needs a second connection,
/// which means a second repository. Same shape, different database.
/// </para>
/// <para>
/// ⚠️ THIS IS ORDINARY REFERENCE DATA AND THE MASTER CACHE APPLIES TO IT. The
/// prohibition in <c>MONETIZATION_DESIGN.md</c> — gating reads never come off
/// the master cache — is about <c>m_mdm_features</c> and
/// <c>m_mdm_plan_features</c>, which is why
/// <see cref="IEntitlementRepository"/> exists separately and is never given a
/// cache. Neither table is reachable from here, and neither ever may be.
/// Employment types are a dropdown; a stale one for an hour is cosmetic.
/// </para>
/// <para>
/// Like <see cref="MasterRepository"/>, this adds NO second whitelist. The
/// procedure is the gate.
/// </para>
/// </remarks>
internal interface IAppMasterRepository
{
    /// <summary>
    /// One jp_app master list, and whether the key was one the procedure knows.
    /// </summary>
    /// <remarks>
    /// The <c>Recognised</c> half is load-bearing here in a way it is not in
    /// jp_mdm: it is how <c>MasterService</c> tells "not a jp_app master" from
    /// "a jp_app master that happens to be empty", and therefore whether an
    /// unknown key deserves a warning.
    /// </remarks>
    Task<(IReadOnlyList<MasterRow> Rows, bool Recognised)> GetAsync(
        string masterCode, int? parentId, CancellationToken cancellationToken);
}

internal sealed class AppMasterRepository : BaseRepository, IAppMasterRepository
{
    public AppMasterRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<AppMasterRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.App;

    /// <inheritdoc />
    /// <remarks>
    /// 🔴 <paramref name="masterCode"/> reaches <c>USP_GetAppMaster</c>, which
    /// selects a branch of a CASE it wrote itself. It is never concatenated
    /// into a table name, and an unknown code returns an empty set rather than
    /// an error — the same contract as jp_mdm's <c>USP_GetMaster</c>, because
    /// one <see cref="MasterRow"/> maps both result sets and a caller must not
    /// be able to tell from the response which database answered.
    /// </remarks>
    public async Task<(IReadOnlyList<MasterRow> Rows, bool Recognised)> GetAsync(
        string masterCode,
        int? parentId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@MasterCode", masterCode, DbType.AnsiString, size: 50);
        p.Add("@ParentId", parentId, DbType.Int32);
        p.Add("@Recognised", dbType: DbType.Boolean, direction: ParameterDirection.Output);

        var rows = await QueryAsync<MasterRow>("USP_GetAppMaster", p, cancellationToken)
            .ConfigureAwait(false);

        /*
          ⚠️ Defaults to FALSE here, where jp_mdm's defaults to true.

          The two defaults mean the same thing — "believe the database over the
          parameter" — but they fall the opposite way because the fall-through
          runs in one direction. A null from jp_mdm (a procedure predating the
          parameter) must not make every key look unknown and log a warning per
          request. A null from THIS one must not make every jp_mdm key look
          like it was claimed by jp_app, which would suppress the warning that
          finds our own typos.
        */
        var recognised = p.Get<bool?>("@Recognised") ?? false;

        return (rows, recognised);
    }
}
