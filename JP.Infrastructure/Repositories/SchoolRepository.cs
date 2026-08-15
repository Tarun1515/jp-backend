using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Domain.Schools;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

/// <summary>One row of a caller's school membership.</summary>
internal sealed class SchoolMembershipRow
{
    public long SchoolId { get; set; }
    public string SchoolName { get; set; } = string.Empty;
    public byte RoleInSchool { get; set; }
}

internal interface ISchoolRepository
{
    /// <summary>
    /// Which schools this account belongs to.
    /// </summary>
    /// <remarks>
    /// 🔴 The API's answer to "which school is this?" — resolved from the token's
    /// UserUid, never from a route or a body (decision 2.39).
    /// </remarks>
    Task<IReadOnlyList<SchoolMembershipRow>> GetMembershipsAsync(Guid userUid, CancellationToken cancellationToken);

    Task<SchoolProfileDto?> GetProfileAsync(long schoolId, Guid userUid, CancellationToken cancellationToken);

    Task<SchoolPublicProfileDto?> GetPublicProfileAsync(Guid schoolUid, CancellationToken cancellationToken);

    Task<ProcResult> UpdateProfileAsync(long schoolId, Guid userUid, UpdateSchoolProfileRequest request, long actionByUserId, CancellationToken cancellationToken);

    Task<ProcResult> SaveLogoAsync(long schoolId, Guid userUid, string logoPath, long actionByUserId, CancellationToken cancellationToken);

    Task<ProcResult> SavePhotoAsync(long schoolId, Guid userUid, string action, long? photoId, long? branchId, string? filePath, string? caption, IReadOnlyList<long>? order, long actionByUserId, CancellationToken cancellationToken);

    Task<FacilitySyncResult> SaveFacilitiesAsync(long schoolId, Guid userUid, long? branchId, IReadOnlyList<int> facilityIds, long actionByUserId, CancellationToken cancellationToken);
}

internal sealed class FacilitySyncResult : ProcResult
{
    public int Added { get; set; }
    public int Restored { get; set; }
    public int Removed { get; set; }
}

/// <summary>
/// The school's own profile, its photos and its facilities.
/// </summary>
/// <remarks>
/// Every method takes <c>userUid</c> and hands it to the procedure, which
/// resolves membership through <c>fn_IsSchoolMember</c> and branch scope through
/// <c>fn_VisibleBranches</c> (decision 2.53). This layer does not re-implement
/// either — one gate, in the database.
/// </remarks>
internal sealed class SchoolRepository : BaseRepository, ISchoolRepository
{
    public SchoolRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<SchoolRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.App;

    public Task<IReadOnlyList<SchoolMembershipRow>> GetMembershipsAsync(
        Guid userUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);

        return QueryAsync<SchoolMembershipRow>("USP_GetSchoolsForUser", p, cancellationToken);
    }

    public Task<SchoolProfileDto?> GetProfileAsync(
        long schoolId, Guid userUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);

        return QueryMultipleAsync<SchoolProfileDto?>(
            "USP_GetSchoolProfile",
            async grid =>
            {
                var school = await grid.ReadFirstOrDefaultAsync<SchoolProfileDto>().ConfigureAwait(false);
                if (school is null)
                {
                    return null;
                }

                var branches = (await grid.ReadAsync<BranchDto>().ConfigureAwait(false)).AsList();
                var photos = (await grid.ReadAsync<SchoolPhotoDto>().ConfigureAwait(false)).AsList();
                var facilities = (await grid.ReadAsync<FacilityRow>().ConfigureAwait(false)).AsList();

                return school with
                {
                    Branches = branches,
                    Photos = photos,
                    FacilityIds = facilities.Select(f => f.FacilityId).ToList(),
                };
            },
            p,
            cancellationToken);
    }

    public Task<SchoolPublicProfileDto?> GetPublicProfileAsync(
        Guid schoolUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolUid", schoolUid, DbType.Guid);

        return QueryMultipleAsync<SchoolPublicProfileDto?>(
            "USP_GetSchoolPublicProfile",
            async grid =>
            {
                /*
                  🔴 A suspended, unverified or deleted school returns NOTHING
                  here — the procedure filters on the lookup, so every result set
                  is empty rather than each one having to remember.

                  Null becomes a 404 in the service. Not 403: confirming that a
                  school exists but is hidden is itself a disclosure, the same
                  reasoning as the document download (2.48).
                */
                var school = await grid.ReadFirstOrDefaultAsync<SchoolPublicProfileDto>().ConfigureAwait(false);
                if (school is null)
                {
                    return null;
                }

                var branches = (await grid.ReadAsync<BranchPublicDto>().ConfigureAwait(false)).AsList();
                var photos = (await grid.ReadAsync<SchoolPhotoPublicDto>().ConfigureAwait(false)).AsList();
                var facilities = (await grid.ReadAsync<FacilityRow>().ConfigureAwait(false)).AsList();

                return school with
                {
                    Branches = branches,
                    Photos = photos,
                    FacilityIds = facilities.Select(f => f.FacilityId).ToList(),
                };
            },
            p,
            cancellationToken);
    }

    public Task<ProcResult> UpdateProfileAsync(
        long schoolId, Guid userUid, UpdateSchoolProfileRequest request,
        long actionByUserId, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var p = new DynamicParameters();

        // 🔴 Both from the token side, as separate arguments — never off the
        // request model, which has no field for either (2.39).
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@ActionByUserId", actionByUserId, DbType.Int64);

        p.Add("@RowVersion", request.RowVersion, DbType.Int32);
        p.Add("@SchoolTypeId", request.SchoolTypeId, DbType.Int32);
        p.Add("@BoardId", request.BoardId, DbType.Int32);
        p.Add("@AffiliationNumber", request.AffiliationNumber, DbType.AnsiString, size: 50);
        p.Add("@RegistrationNo", request.RegistrationNo, DbType.AnsiString, size: 50);
        p.Add("@PanNumber", request.PanNumber, DbType.AnsiString, size: 10);
        p.Add("@GroupType", request.GroupType, DbType.Byte);
        p.Add("@EstablishedYear", request.EstablishedYear, DbType.Int16);
        p.Add("@AboutSchool", request.AboutSchool, DbType.String, size: -1);
        p.Add("@Website", request.Website, DbType.String, size: 255);
        p.Add("@ContactEmail", request.ContactEmail, DbType.String, size: 150);
        p.Add("@ContactMobile", request.ContactMobile, DbType.AnsiString, size: 15);
        p.Add("@PrincipalName", request.PrincipalName, DbType.String, size: 150);
        p.Add("@HrContactName", request.HrContactName, DbType.String, size: 150);
        p.Add("@HrContactMobile", request.HrContactMobile, DbType.AnsiString, size: 15);
        p.Add("@AddressLine1", request.AddressLine1, DbType.String, size: 250);
        p.Add("@AddressLine2", request.AddressLine2, DbType.String, size: 250);
        p.Add("@CityId", request.CityId, DbType.Int32);
        p.Add("@DistrictId", request.DistrictId, DbType.Int32);
        p.Add("@StateId", request.StateId, DbType.Int32);
        p.Add("@Pincode", request.Pincode, DbType.AnsiString, size: 10);

        return QuerySingleAsync<ProcResult>("USP_UpdateSchoolProfile", p, cancellationToken);
    }

    public Task<ProcResult> SaveLogoAsync(
        long schoolId, Guid userUid, string logoPath, long actionByUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@LogoPath", logoPath, DbType.String, size: 500);
        p.Add("@ActionByUserId", actionByUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_SaveSchoolLogo", p, cancellationToken);
    }

    public Task<ProcResult> SavePhotoAsync(
        long schoolId, Guid userUid, string action, long? photoId, long? branchId,
        string? filePath, string? caption, IReadOnlyList<long>? order,
        long actionByUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@Action", action, DbType.AnsiString, size: 20);
        p.Add("@PhotoId", photoId, DbType.Int64);
        p.Add("@BranchId", branchId, DbType.Int64);
        p.Add("@FilePath", filePath, DbType.String, size: 500);
        p.Add("@Caption", caption, DbType.String, size: 250);
        p.Add("@ActionByUserId", actionByUserId, DbType.Int64);

        /*
          The reorder list. ⚠️ A table type cannot be NULL — "Operand type
          clash" — so an empty table is how "no list" is expressed, and the ADD
          and DELETE branches ignore it anyway.
        */
        var table = new DataTable();
        table.Columns.Add("Id", typeof(int));

        foreach (var id in order ?? [])
        {
            table.Rows.Add((int)id);
        }

        p.Add("@PhotoOrder", table.AsTableValuedParameter("dbo.IntIdList"));

        return QuerySingleAsync<ProcResult>("USP_SaveSchoolPhotos", p, cancellationToken);
    }

    public Task<FacilitySyncResult> SaveFacilitiesAsync(
        long schoolId, Guid userUid, long? branchId, IReadOnlyList<int> facilityIds,
        long actionByUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@BranchId", branchId, DbType.Int64);
        p.Add("@ActionByUserId", actionByUserId, DbType.Int64);
        p.Add("@FacilityIds", IntIdTable(facilityIds).AsTableValuedParameter("dbo.IntIdList"));

        return QuerySingleAsync<FacilitySyncResult>("USP_SaveSchoolFacilities", p, cancellationToken);
    }

    /// <summary>
    /// Turns an id list into the table type the sync procedures take.
    /// </summary>
    /// <remarks>
    /// ⚠️ DISTINCT here, not in the procedure: a duplicate in the payload is a
    /// client bug, and the unique index would reject the whole batch rather than
    /// the duplicate.
    /// </remarks>
    internal static DataTable IntIdTable(IReadOnlyList<int> ids)
    {
        var table = new DataTable();
        table.Columns.Add("Id", typeof(int));

        foreach (var id in (ids ?? []).Distinct())
        {
            table.Rows.Add(id);
        }

        return table;
    }
}

internal sealed class FacilityRow
{
    public int FacilityId { get; set; }
}
