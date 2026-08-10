using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

internal interface IMasterRepository
{
    /// <summary>
    /// One master list, and whether the key was one the procedure knows.
    /// </summary>
    /// <remarks>
    /// The tuple exists so an unrecognised key can be LOGGED without changing
    /// what the caller is told. See the note on the implementation.
    /// </remarks>
    Task<(IReadOnlyList<MasterRow> Rows, bool Recognised)> GetAsync(string masterCode, int? parentId, CancellationToken cancellationToken);

    Task<DocumentTypeRow?> GetDocumentTypeAsync(int documentTypeId, CancellationToken cancellationToken);
}

internal sealed class MasterRepository : BaseRepository, IMasterRepository
{
    public MasterRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<MasterRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.Mdm;

    /// <summary>
    /// One master list.
    /// </summary>
    /// <remarks>
    /// 🔴 <paramref name="masterCode"/> reaches USP_GetMaster, which selects a
    /// branch of a CASE it wrote itself. It is never concatenated into a table
    /// name — that is the whole reason the procedure is shaped that way, and an
    /// unknown code returns an empty set rather than an error (decision 2.46).
    ///
    /// This repository deliberately adds NO second whitelist. Two gates that
    /// have to agree is how they stop agreeing; the procedure is the gate.
    /// </remarks>
    public async Task<(IReadOnlyList<MasterRow> Rows, bool Recognised)> GetAsync(
        string masterCode,
        int? parentId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@MasterCode", masterCode, DbType.AnsiString, size: 50);
        p.Add("@ParentId", parentId, DbType.Int32);

        // 🔴 The response is identical for an unknown key — empty set, no
        // error. This output parameter is for US, not the caller: see the
        // procedure's comment on why a silent whitelist hides our own typos as
        // effectively as it deflects an attacker.
        p.Add("@Recognised", dbType: DbType.Boolean, direction: ParameterDirection.Output);

        var rows = await QueryAsync<MasterRow>("USP_GetMaster", p, cancellationToken)
            .ConfigureAwait(false);

        // Null only if the procedure predates the parameter. Treated as
        // recognised so an out-of-date database logs nothing rather than
        // logging everything.
        var recognised = p.Get<bool?>("@Recognised") ?? true;

        return (rows, recognised);
    }

    /// <summary>
    /// The upload rules for one document type.
    /// </summary>
    /// <remarks>
    /// Read before every upload so <c>MaxSizeKb</c> and
    /// <c>AllowedExtensions</c> come from the seeded row rather than a constant
    /// (decision 2.47). Changing the limit for TET certificates must be a data
    /// change, not a deployment.
    /// </remarks>
    public async Task<DocumentTypeRow?> GetDocumentTypeAsync(
        int documentTypeId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@MasterCode", "DOCUMENT_TYPE", DbType.AnsiString, size: 50);
        p.Add("@ParentId", null, DbType.Int32);

        var rows = await QueryAsync<MasterRow>("USP_GetMaster", p, cancellationToken)
            .ConfigureAwait(false);

        var row = rows.FirstOrDefault(r => r.Id == documentTypeId);

        return row is null
            ? null
            : new DocumentTypeRow
            {
                Id = row.Id,
                Code = row.Code,
                Name = row.Name,
                RequestTypeId = row.ParentId ?? 0,
                IsMandatory = row.IsMandatory ?? false,
                MaxSizeKb = row.MaxSizeKb ?? 0,
                AllowedExtensions = row.AllowedExtensions ?? string.Empty,
            };
    }
}
