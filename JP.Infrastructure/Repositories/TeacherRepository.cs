using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Domain.Teachers;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

internal sealed class BridgeSyncResult : ProcResult
{
    public int Added { get; set; }
    public int Restored { get; set; }
    public int Removed { get; set; }
}

internal sealed class BridgeSyncWithUpdateResult : ProcResult
{
    public int Added { get; set; }
    public int Restored { get; set; }
    public int Removed { get; set; }
    public int Updated { get; set; }
}

/// <summary>The contact procedure's single row: envelope plus the details.</summary>
internal sealed class TeacherContactRow
{
    public int Status { get; set; }
    public string? Code { get; set; }
    public string Message { get; set; } = string.Empty;
    public long? Id { get; set; }
    public string? ResumePath { get; set; }
    public string? ContactEmail { get; set; }
    public string? ContactMobile { get; set; }
}

internal interface ITeacherRepository
{
    Task<TeacherProfileDto?> GetProfileAsync(Guid userUid, CancellationToken cancellationToken);

    Task<TeacherBrowseDto?> GetBrowseProfileAsync(Guid teacherUid, CancellationToken cancellationToken);

    Task<TeacherContactRow> GetContactAsync(Guid teacherUid, long viewerSchoolId, CancellationToken cancellationToken);

    Task<ProcResult> UpdateProfileAsync(Guid userUid, UpdateTeacherProfileRequest request, CancellationToken cancellationToken);

    Task<ProcResult> SavePhotoAsync(Guid userUid, string photoPath, CancellationToken cancellationToken);

    /// <summary>
    /// Where the teacher's own photo, resume or document lives.
    /// </summary>
    /// <remarks>
    /// 🔴 The teacher is resolved from the token's Uid inside the procedure, so
    /// there is no parameter for whose file it is — 'somebody else's' cannot be
    /// expressed. Null means no file, or not yours; the API turns both into a
    /// 404 (3H).
    /// </remarks>
    Task<string?> GetPhotoPathAsync(Guid userUid, CancellationToken cancellationToken);

    Task<string?> GetResumePathAsync(Guid userUid, CancellationToken cancellationToken);

    Task<string?> GetDocumentPathAsync(long documentId, Guid userUid, CancellationToken cancellationToken);
    Task<ProcResult> SaveResumeAsync(Guid userUid, string resumePath, CancellationToken cancellationToken);

    Task<ProcResult> SaveDocumentAsync(Guid userUid, int documentTypeId, string filePath, string fileName, int fileSizeKb, string mimeType, CancellationToken cancellationToken);
    Task<ProcResult> DeleteDocumentAsync(Guid userUid, long documentId, CancellationToken cancellationToken);

    Task<BridgeSyncResult> SaveSubjectsAsync(Guid userUid, IReadOnlyList<int> ids, CancellationToken cancellationToken);
    Task<BridgeSyncResult> SaveClassLevelsAsync(Guid userUid, IReadOnlyList<int> ids, CancellationToken cancellationToken);
    Task<BridgeSyncResult> SaveSkillsAsync(Guid userUid, IReadOnlyList<int> ids, CancellationToken cancellationToken);
    Task<BridgeSyncWithUpdateResult> SaveLanguagesAsync(Guid userUid, IReadOnlyList<TeacherLanguageDto> languages, CancellationToken cancellationToken);
    Task<BridgeSyncWithUpdateResult> SavePreferredLocationsAsync(Guid userUid, IReadOnlyList<TeacherLocationDto> locations, CancellationToken cancellationToken);

    Task<ProcResult> SaveExperienceAsync(Guid userUid, long? id, SaveExperienceRequest request, CancellationToken cancellationToken);
    Task<ProcResult> DeleteExperienceAsync(Guid userUid, long id, CancellationToken cancellationToken);
}

/// <summary>
/// The teacher profile.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 EVERY WRITE TAKES <c>userUid</c> AND NOTHING THAT IDENTIFIES A TEACHER.
/// </para>
/// <para>
/// Phase 3D built the procedures so that editing somebody else's profile cannot
/// be expressed — no procedure takes a TeacherId, verified against
/// sys.parameters. This layer holds that line: it never accepts a teacher id and
/// never looks one up on a caller's behalf. Where a child row is addressed by id
/// — an experience, a document — the procedure checks it against the teacher the
/// Uid resolved to, and answers NOT_FOUND for anybody else's.
/// </para>
/// </remarks>
internal sealed class TeacherRepository : BaseRepository, ITeacherRepository
{
    public TeacherRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<TeacherRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.App;

    public Task<TeacherProfileDto?> GetProfileAsync(Guid userUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);

        return QueryMultipleAsync<TeacherProfileDto?>(
            "USP_GetTeacherProfile",
            async grid =>
            {
                var profile = await grid.ReadFirstOrDefaultAsync<TeacherProfileDto>().ConfigureAwait(false);
                if (profile is null)
                {
                    return null;
                }

                var subjects = (await grid.ReadAsync<IdRow>().ConfigureAwait(false)).AsList();
                var levels = (await grid.ReadAsync<ClassLevelRow>().ConfigureAwait(false)).AsList();
                var skills = (await grid.ReadAsync<SkillRow>().ConfigureAwait(false)).AsList();
                var languages = (await grid.ReadAsync<TeacherLanguageDto>().ConfigureAwait(false)).AsList();
                var locations = (await grid.ReadAsync<TeacherLocationDto>().ConfigureAwait(false)).AsList();
                var experiences = (await grid.ReadAsync<TeacherExperienceDto>().ConfigureAwait(false)).AsList();
                var documents = (await grid.ReadAsync<TeacherDocumentDto>().ConfigureAwait(false)).AsList();

                return profile with
                {
                    SubjectIds = subjects.Select(s => s.SubjectId).ToList(),
                    ClassLevelIds = levels.Select(l => l.ClassLevelId).ToList(),
                    SkillIds = skills.Select(s => s.SkillId).ToList(),
                    Languages = languages,
                    PreferredLocations = locations,
                    Experiences = experiences,
                    Documents = documents,
                };
            },
            p,
            cancellationToken);
    }

    /// <summary>
    /// The browse view.
    /// </summary>
    /// <remarks>
    /// 🔴 Maps <c>USP_GetTeacherPublicProfile</c> and ONLY that. It must never
    /// be pointed at the contact procedure, and the contact procedure's result
    /// must never be mapped into <see cref="TeacherBrowseDto"/> — that type has
    /// no contact properties to map into, which is the point (2.56).
    /// </remarks>
    public Task<TeacherBrowseDto?> GetBrowseProfileAsync(Guid teacherUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@TeacherUid", teacherUid, DbType.Guid);

        return QueryMultipleAsync<TeacherBrowseDto?>(
            "USP_GetTeacherPublicProfile",
            async grid =>
            {
                var profile = await grid.ReadFirstOrDefaultAsync<TeacherBrowseDto>().ConfigureAwait(false);
                if (profile is null)
                {
                    return null;
                }

                var subjects = (await grid.ReadAsync<IdRow>().ConfigureAwait(false)).AsList();
                var levels = (await grid.ReadAsync<ClassLevelRow>().ConfigureAwait(false)).AsList();
                var skills = (await grid.ReadAsync<SkillRow>().ConfigureAwait(false)).AsList();
                var languages = (await grid.ReadAsync<TeacherLanguageDto>().ConfigureAwait(false)).AsList();
                var locations = (await grid.ReadAsync<TeacherLocationDto>().ConfigureAwait(false)).AsList();
                var experiences = (await grid.ReadAsync<TeacherExperiencePublicDto>().ConfigureAwait(false)).AsList();
                var documents = (await grid.ReadAsync<TeacherDocumentBadgeDto>().ConfigureAwait(false)).AsList();

                return profile with
                {
                    SubjectIds = subjects.Select(s => s.SubjectId).ToList(),
                    ClassLevelIds = levels.Select(l => l.ClassLevelId).ToList(),
                    SkillIds = skills.Select(s => s.SkillId).ToList(),
                    Languages = languages,
                    PreferredLocations = locations,
                    Experiences = experiences,
                    Documents = documents,
                };
            },
            p,
            cancellationToken);
    }

    public Task<TeacherContactRow> GetContactAsync(
        Guid teacherUid, long viewerSchoolId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@TeacherUid", teacherUid, DbType.Guid);

        // 🔴 The viewing school is resolved from the caller's own membership,
        // never from the request (2.39). A school naming another school's id
        // would otherwise unlock everything that school had earned.
        p.Add("@ViewerSchoolId", viewerSchoolId, DbType.Int64);

        return QuerySingleAsync<TeacherContactRow>("USP_GetTeacherContactForSchool", p, cancellationToken);
    }

    public Task<ProcResult> UpdateProfileAsync(
        Guid userUid, UpdateTeacherProfileRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@RowVersion", request.RowVersion, DbType.Int32);
        p.Add("@FullName", request.FullName, DbType.String, size: 150);
        p.Add("@DOB", request.Dob, DbType.Date);
        p.Add("@GenderId", request.GenderId, DbType.Int32);
        p.Add("@QualificationId", request.QualificationId, DbType.Int32);
        p.Add("@HighestQualificationText", request.HighestQualificationText, DbType.String, size: 200);
        p.Add("@DesignationId", request.DesignationId, DbType.Int32);
        p.Add("@CurrentSchool", request.CurrentSchool, DbType.String, size: 200);
        p.Add("@LastSchool", request.LastSchool, DbType.String, size: 200);
        p.Add("@ExpectedSalaryMin", request.ExpectedSalaryMin, DbType.Decimal);
        p.Add("@ExpectedSalaryMax", request.ExpectedSalaryMax, DbType.Decimal);
        p.Add("@CurrentCityId", request.CurrentCityId, DbType.Int32);
        p.Add("@CurrentStateId", request.CurrentStateId, DbType.Int32);
        p.Add("@AboutMe", request.AboutMe, DbType.String, size: -1);

        return QuerySingleAsync<ProcResult>("USP_UpdateTeacherProfile", p, cancellationToken);
    }

    public Task<string?> GetPhotoPathAsync(Guid userUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);

        return QueryFirstOrDefaultAsync<string>("USP_GetTeacherPhotoPath", p, cancellationToken);
    }

    public Task<string?> GetResumePathAsync(Guid userUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);

        return QueryFirstOrDefaultAsync<string>("USP_GetTeacherResumePath", p, cancellationToken);
    }

    public Task<string?> GetDocumentPathAsync(long documentId, Guid userUid, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@DocumentId", documentId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);

        return QueryFirstOrDefaultAsync<string>("USP_GetTeacherDocumentPath", p, cancellationToken);
    }

    public Task<ProcResult> SavePhotoAsync(Guid userUid, string photoPath, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@PhotoPath", photoPath, DbType.String, size: 500);

        return QuerySingleAsync<ProcResult>("USP_SaveTeacherPhoto", p, cancellationToken);
    }

    public Task<ProcResult> SaveResumeAsync(Guid userUid, string resumePath, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@ResumePath", resumePath, DbType.String, size: 500);

        return QuerySingleAsync<ProcResult>("USP_SaveTeacherResume", p, cancellationToken);
    }

    public Task<ProcResult> SaveDocumentAsync(
        Guid userUid, int documentTypeId, string filePath, string fileName,
        int fileSizeKb, string mimeType, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@DocumentTypeId", documentTypeId, DbType.Int32);
        p.Add("@FilePath", filePath, DbType.String, size: 500);
        p.Add("@FileName", fileName, DbType.String, size: 255);
        p.Add("@FileSizeKb", fileSizeKb, DbType.Int32);
        p.Add("@MimeType", mimeType, DbType.AnsiString, size: 100);

        return QuerySingleAsync<ProcResult>("USP_SaveTeacherDocument", p, cancellationToken);
    }

    public Task<ProcResult> DeleteDocumentAsync(Guid userUid, long documentId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@DocumentId", documentId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_DeleteTeacherDocument", p, cancellationToken);
    }

    // ---- the three plain set syncs -----------------------------------------

    public Task<BridgeSyncResult> SaveSubjectsAsync(Guid userUid, IReadOnlyList<int> ids, CancellationToken cancellationToken)
        => SaveIdSetAsync("USP_SaveTeacherSubjects", "@SubjectIds", userUid, ids, cancellationToken);

    public Task<BridgeSyncResult> SaveClassLevelsAsync(Guid userUid, IReadOnlyList<int> ids, CancellationToken cancellationToken)
        => SaveIdSetAsync("USP_SaveTeacherClassLevels", "@ClassLevelIds", userUid, ids, cancellationToken);

    public Task<BridgeSyncResult> SaveSkillsAsync(Guid userUid, IReadOnlyList<int> ids, CancellationToken cancellationToken)
        => SaveIdSetAsync("USP_SaveTeacherSkills", "@SkillIds", userUid, ids, cancellationToken);

    private Task<BridgeSyncResult> SaveIdSetAsync(
        string procedure, string parameterName, Guid userUid,
        IReadOnlyList<int> ids, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add(parameterName, SchoolRepository.IntIdTable(ids).AsTableValuedParameter("dbo.IntIdList"));

        return QuerySingleAsync<BridgeSyncResult>(procedure, p, cancellationToken);
    }

    // ---- the two that carry a payload --------------------------------------

    public Task<BridgeSyncWithUpdateResult> SaveLanguagesAsync(
        Guid userUid, IReadOnlyList<TeacherLanguageDto> languages, CancellationToken cancellationToken)
    {
        var table = new DataTable();
        table.Columns.Add("LanguageId", typeof(int));
        table.Columns.Add("ProficiencyLevel", typeof(byte));

        // ⚠️ DISTINCT on the key: the same language twice would hit the unique
        // index and fail the whole save rather than the duplicate.
        foreach (var l in (languages ?? []).GroupBy(l => l.LanguageId).Select(g => g.First()))
        {
            table.Rows.Add(l.LanguageId, (object?)l.ProficiencyLevel ?? DBNull.Value);
        }

        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@Languages", table.AsTableValuedParameter("dbo.LanguageProficiencyList"));

        return QuerySingleAsync<BridgeSyncWithUpdateResult>("USP_SaveTeacherLanguages", p, cancellationToken);
    }

    public Task<BridgeSyncWithUpdateResult> SavePreferredLocationsAsync(
        Guid userUid, IReadOnlyList<TeacherLocationDto> locations, CancellationToken cancellationToken)
    {
        var table = new DataTable();
        table.Columns.Add("CityId", typeof(int));
        table.Columns.Add("StateId", typeof(int));
        table.Columns.Add("PreferenceOrder", typeof(int));

        /*
          ⚠️ NOT deduplicated here, deliberately — the procedure does it, because
          the key is (CityId, StateId) with NULL-EQUALITY and LINQ's GroupBy
          treats two nulls as equal while SQL's `=` does not. Doing it in both
          places with two different notions of equality is how they drift.
        */
        foreach (var l in locations ?? [])
        {
            table.Rows.Add((object?)l.CityId ?? DBNull.Value, l.StateId, l.PreferenceOrder);
        }

        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@Locations", table.AsTableValuedParameter("dbo.PreferredLocationList"));

        return QuerySingleAsync<BridgeSyncWithUpdateResult>("USP_SaveTeacherPreferredLocations", p, cancellationToken);
    }

    // ---- experiences: entities, not a set ----------------------------------

    public Task<ProcResult> SaveExperienceAsync(
        Guid userUid, long? id, SaveExperienceRequest request, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@Id", id, DbType.Int64);
        p.Add("@SchoolName", request.SchoolName, DbType.String, size: 200);
        p.Add("@DesignationId", request.DesignationId, DbType.Int32);
        p.Add("@SubjectId", request.SubjectId, DbType.Int32);
        p.Add("@FromDate", request.FromDate, DbType.Date);
        p.Add("@ToDate", request.ToDate, DbType.Date);
        p.Add("@IsCurrent", request.IsCurrent ? (byte)1 : (byte)0, DbType.Byte);

        return QuerySingleAsync<ProcResult>("USP_SaveTeacherExperience", p, cancellationToken);
    }

    public Task<ProcResult> DeleteExperienceAsync(Guid userUid, long id, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@Id", id, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_DeleteTeacherExperience", p, cancellationToken);
    }
}

internal sealed class IdRow { public int SubjectId { get; set; } }
internal sealed class ClassLevelRow { public int ClassLevelId { get; set; } }
internal sealed class SkillRow { public int SkillId { get; set; } }
