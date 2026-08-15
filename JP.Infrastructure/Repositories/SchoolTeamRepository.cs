using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Domain.Schools;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

/// <summary>One membership row, before the jp_sso half is joined onto it.</summary>
internal sealed class SchoolTeamMemberRow
{
    public long SchoolUserId { get; set; }
    public Guid UserUid { get; set; }
    public string? FullName { get; set; }
    public string? DesignationText { get; set; }
    public byte RoleInSchool { get; set; }
    public byte Is_Active { get; set; }
    public DateTime CreatedOn { get; set; }
    public DateTime? ModifiedOn { get; set; }
    public int BranchCount { get; set; }
}

/// <summary>A user-to-campus link, already filtered to the caller's own scope.</summary>
internal sealed class SchoolTeamBranchRow
{
    public long SchoolUserId { get; set; }
    public long BranchId { get; set; }
}

internal sealed class SchoolTeamRows
{
    public IReadOnlyList<SchoolTeamMemberRow> Members { get; init; } = [];
    public IReadOnlyList<SchoolTeamBranchRow> Branches { get; init; } = [];
}

internal sealed class ProvisionSchoolUserResult : ProcResult
{
    public int BranchesLinked { get; set; }
}

internal sealed class SaveRoleResult : ProcResult
{
    /// <summary>False when the values sent matched what was stored and nothing was written.</summary>
    public bool Changed { get; set; }
}

internal sealed class BranchSyncResult : ProcResult
{
    public int Added { get; set; }
    public int Restored { get; set; }
    public int Removed { get; set; }
}

internal interface ISchoolTeamRepository
{
    Task<SchoolTeamRows> GetTeamAsync(long schoolId, Guid userUid, CancellationToken cancellationToken);

    Task<ProvisionSchoolUserResult> ProvisionMemberAsync(long schoolId, Guid callerUid, Guid newUserUid,
        byte roleInSchool, string? fullName, string? designationText, IReadOnlyList<long> branchIds,
        long actionByUserId, CancellationToken cancellationToken);

    Task<SaveRoleResult> SaveRoleAsync(long schoolId, Guid callerUid, Guid targetUserUid,
        SaveTeamMemberRoleRequest request, long actionByUserId, CancellationToken cancellationToken);

    Task<BranchSyncResult> SaveBranchesAsync(long schoolId, Guid callerUid, Guid targetUserUid,
        IReadOnlyList<long> branchIds, long actionByUserId, CancellationToken cancellationToken);

    Task<ProcResult> DeactivateAsync(long schoolId, Guid callerUid, Guid targetUserUid,
        long actionByUserId, CancellationToken cancellationToken);
}

/// <summary>
/// A school's team, in jp_app.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 The owner rules live in the procedures, not here. An owner cannot be
/// demoted or deactivated and nobody can be promoted into the role; every one of
/// those is refused in <c>011_school_team.sql</c> with its own code and its own
/// message. A duplicate check in this layer would be a second rule to keep in
/// step with the first.
/// </para>
/// <para>
/// ⚠️ Every method takes the CALLER's uid as well as the target's. That pair is
/// what makes a cross-school write impossible: the procedure resolves the target
/// through the caller's own school, so naming somebody else's colleague returns
/// NOT_FOUND rather than touching them.
/// </para>
/// </remarks>
internal sealed class SchoolTeamRepository : BaseRepository, ISchoolTeamRepository
{
    public SchoolTeamRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<SchoolTeamRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.App;

    public Task<SchoolTeamRows> GetTeamAsync(long schoolId, Guid userUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@IncludeInactive", true, DbType.Boolean);

        return QueryMultipleAsync<SchoolTeamRows>(
            "USP_GetSchoolUserList",
            async grid => new SchoolTeamRows
            {
                Members = (await grid.ReadAsync<SchoolTeamMemberRow>().ConfigureAwait(false)).AsList(),
                Branches = (await grid.ReadAsync<SchoolTeamBranchRow>().ConfigureAwait(false)).AsList(),
            },
            p,
            cancellationToken);
    }

    public Task<ProvisionSchoolUserResult> ProvisionMemberAsync(
        long schoolId, Guid callerUid, Guid newUserUid, byte roleInSchool, string? fullName,
        string? designationText, IReadOnlyList<long> branchIds, long actionByUserId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", callerUid, DbType.Guid);
        p.Add("@NewUserUid", newUserUid, DbType.Guid);
        p.Add("@RoleInSchool", roleInSchool, DbType.Byte);
        p.Add("@FullName", fullName, DbType.String, size: 150);
        p.Add("@DesignationText", designationText, DbType.String, size: 150);
        p.Add("@ActionByUserId", actionByUserId, DbType.Int64);
        p.Add("@BranchIds", BranchIdTable(branchIds).AsTableValuedParameter("dbo.BigIntIdList"));

        return QuerySingleAsync<ProvisionSchoolUserResult>("USP_ProvisionSchoolUser", p, cancellationToken);
    }

    public Task<SaveRoleResult> SaveRoleAsync(
        long schoolId, Guid callerUid, Guid targetUserUid, SaveTeamMemberRoleRequest request,
        long actionByUserId, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", callerUid, DbType.Guid);
        p.Add("@TargetUserUid", targetUserUid, DbType.Guid);
        p.Add("@RoleInSchool", request.RoleInSchool, DbType.Byte);
        p.Add("@FullName", request.FullName, DbType.String, size: 150);
        p.Add("@DesignationText", request.DesignationText, DbType.String, size: 150);
        p.Add("@ActionByUserId", actionByUserId, DbType.Int64);

        return QuerySingleAsync<SaveRoleResult>("USP_SaveSchoolUserRole", p, cancellationToken);
    }

    public Task<BranchSyncResult> SaveBranchesAsync(
        long schoolId, Guid callerUid, Guid targetUserUid, IReadOnlyList<long> branchIds,
        long actionByUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", callerUid, DbType.Guid);
        p.Add("@TargetUserUid", targetUserUid, DbType.Guid);
        p.Add("@ActionByUserId", actionByUserId, DbType.Int64);
        p.Add("@BranchIds", BranchIdTable(branchIds).AsTableValuedParameter("dbo.BigIntIdList"));

        return QuerySingleAsync<BranchSyncResult>("USP_SaveSchoolUserBranches", p, cancellationToken);
    }

    public Task<ProcResult> DeactivateAsync(
        long schoolId, Guid callerUid, Guid targetUserUid, long actionByUserId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", callerUid, DbType.Guid);
        p.Add("@TargetUserUid", targetUserUid, DbType.Guid);
        p.Add("@ActionByUserId", actionByUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_DeactivateSchoolUser", p, cancellationToken);
    }

    /// <summary>
    /// Branch ids as the table type the sync takes.
    /// </summary>
    /// <remarks>
    /// ⚠️ bigint, not int — <c>dbo.IntIdList</c> would silently truncate a large
    /// BranchId into a different school's campus. And DISTINCT here rather than
    /// in the procedure: the type has a primary key, so a duplicate in the
    /// payload would be rejected by the client before the call is even made.
    /// </remarks>
    private static DataTable BranchIdTable(IReadOnlyList<long> ids)
    {
        var table = new DataTable();
        table.Columns.Add("Id", typeof(long));

        foreach (var id in (ids ?? []).Distinct())
        {
            table.Rows.Add(id);
        }

        return table;
    }
}
