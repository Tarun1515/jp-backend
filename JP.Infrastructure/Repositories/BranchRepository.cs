using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Domain.Schools;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

internal sealed class SaveBranchProcResult : ProcResult
{
    public Guid? BranchUid { get; set; }
}

internal interface IBranchRepository
{
    Task<IReadOnlyList<BranchDto>> ListAsync(long schoolId, Guid userUid, string? search, int? stateId, bool includeInactive, CancellationToken cancellationToken);

    Task<BranchDto?> GetByIdAsync(long branchId, Guid userUid, CancellationToken cancellationToken);

    Task<SaveBranchProcResult> SaveAsync(long schoolId, Guid userUid, long? branchId, SaveBranchRequest request, long actionByUserId, CancellationToken cancellationToken);

    Task<ProcResult> DeleteAsync(long branchId, long schoolId, Guid userUid, int rowVersion, long actionByUserId, CancellationToken cancellationToken);
}

/// <summary>
/// Branches, every one of them scope-resolved.
/// </summary>
/// <remarks>
/// 🔴 This repository does NOT decide who can see what. Every procedure it calls
/// joins through <c>dbo.fn_VisibleBranches</c> (decision 2.53), which is the one
/// place branch scope is decided. Re-checking here would create a second rule to
/// keep in step, and the day the two disagree is the day one of them is wrong.
///
/// The consequence to hold onto: a branch outside the caller's scope comes back
/// as NOTHING, and the service turns that into a 404 rather than a 403.
/// Confirming a branch exists but is not yours is itself a leak.
/// </remarks>
internal sealed class BranchRepository : BaseRepository, IBranchRepository
{
    public BranchRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<BranchRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.App;

    public Task<IReadOnlyList<BranchDto>> ListAsync(
        long schoolId, Guid userUid, string? search, int? stateId, bool includeInactive,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@Search", search, DbType.String, size: 150);
        p.Add("@StateId", stateId, DbType.Int32);
        p.Add("@IncludeInactive", includeInactive, DbType.Boolean);

        return QueryAsync<BranchDto>("USP_GetBranchList", p, cancellationToken);
    }

    public Task<BranchDto?> GetByIdAsync(long branchId, Guid userUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@BranchId", branchId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);

        return QueryFirstOrDefaultAsync<BranchDto>("USP_GetBranchById", p, cancellationToken);
    }

    public Task<SaveBranchProcResult> SaveAsync(
        long schoolId, Guid userUid, long? branchId, SaveBranchRequest request,
        long actionByUserId, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var p = new DynamicParameters();

        // 🔴 School and user from the caller's own resolution, branch id from the
        // route — and the procedure gates the branch through the scope resolver
        // before touching it.
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@BranchId", branchId, DbType.Int64);
        p.Add("@RowVersion", request.RowVersion, DbType.Int32);
        p.Add("@ActionByUserId", actionByUserId, DbType.Int64);

        p.Add("@BranchName", request.BranchName, DbType.String, size: 200);
        p.Add("@BranchCode", request.BranchCode, DbType.AnsiString, size: 30);
        p.Add("@AddressLine1", request.AddressLine1, DbType.String, size: 250);
        p.Add("@AddressLine2", request.AddressLine2, DbType.String, size: 250);
        p.Add("@CityId", request.CityId, DbType.Int32);
        p.Add("@DistrictId", request.DistrictId, DbType.Int32);
        p.Add("@StateId", request.StateId, DbType.Int32);
        p.Add("@Pincode", request.Pincode, DbType.AnsiString, size: 10);
        p.Add("@Latitude", request.Latitude, DbType.Decimal);
        p.Add("@Longitude", request.Longitude, DbType.Decimal);
        p.Add("@ContactPerson", request.ContactPerson, DbType.String, size: 150);
        p.Add("@ContactEmail", request.ContactEmail, DbType.String, size: 150);
        p.Add("@ContactMobile", request.ContactMobile, DbType.AnsiString, size: 15);
        p.Add("@IsActive", request.IsActive ? (byte)1 : (byte)0, DbType.Byte);

        return QuerySingleAsync<SaveBranchProcResult>("USP_SaveBranch", p, cancellationToken);
    }

    public Task<ProcResult> DeleteAsync(
        long branchId, long schoolId, Guid userUid, int rowVersion,
        long actionByUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@BranchId", branchId, DbType.Int64);
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@RowVersion", rowVersion, DbType.Int32);
        p.Add("@ActionByUserId", actionByUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_DeleteBranch", p, cancellationToken);
    }
}
