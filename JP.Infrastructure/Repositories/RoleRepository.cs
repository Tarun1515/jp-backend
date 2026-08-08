using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

internal interface IRoleRepository
{
    Task<IReadOnlyList<RoleRow>> GetRoleListAsync(Guid? organizationUid, int? userTypeId,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<PermissionRow>> GetPermissionListAsync(int? moduleId,
        CancellationToken cancellationToken);

    Task<ProcResult> CreateSchoolRoleAsync(Guid organizationUid, string roleCode, string roleName,
        string permissionCodesCsv, long createdByUserId, CancellationToken cancellationToken);
}

internal sealed class RoleRepository : BaseRepository, IRoleRepository
{
    public RoleRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<RoleRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.Sso;

    public Task<IReadOnlyList<RoleRow>> GetRoleListAsync(
        Guid? organizationUid, int? userTypeId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@OrganizationUid", organizationUid, DbType.Guid);
        p.Add("@UserTypeId", userTypeId, DbType.Int32);
        p.Add("@IncludeSystemRoles", true, DbType.Boolean);

        return QueryAsync<RoleRow>("USP_GetRoleList", p, cancellationToken);
    }

    public Task<IReadOnlyList<PermissionRow>> GetPermissionListAsync(
        int? moduleId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@ModuleId", moduleId, DbType.Int32);

        return QueryAsync<PermissionRow>("USP_GetPermissionList", p, cancellationToken);
    }

    public Task<ProcResult> CreateSchoolRoleAsync(
        Guid organizationUid, string roleCode, string roleName, string permissionCodesCsv,
        long createdByUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@OrganizationUid", organizationUid, DbType.Guid);
        p.Add("@RoleCode", roleCode, DbType.AnsiString, size: 50);
        p.Add("@RoleName", roleName, DbType.String, size: 100);
        p.Add("@PermissionCodes", permissionCodesCsv, DbType.String, size: 4000);
        p.Add("@CreatedByUserId", createdByUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_CreateSchoolRole", p, cancellationToken);
    }
}
