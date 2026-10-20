using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Domain.Invites;
using JP.Domain.Teachers;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

/// <summary>
/// The result of sending an invitation, as the procedure reports it.
/// </summary>
/// <remarks>
/// Extends <see cref="ProcResult"/> with the consume's own answer, the same way
/// the publish row does: a school needs to know whether it was charged, and
/// from where.
/// </remarks>
internal sealed class SendInviteRow : ProcResult
{
    public byte Consumed { get; set; }
    public byte? SourceId { get; set; }
}

/// <summary>Teacher search and invitations, over the jp_app procedures. Phase 6B.</summary>
internal interface IInviteRepository
{
    /// <summary>
    /// 🔒 The search. Its projection carries no contact column — see 019 and
    /// <see cref="TeacherSearchResultDto"/>.
    /// </summary>
    Task<(IReadOnlyList<TeacherSearchResultDto> Rows, long Total)> SearchTeachersAsync(
        long schoolId, TeacherSearchFilter filter, CancellationToken cancellationToken);

    Task<SendInviteRow> SendAsync(
        long schoolId, Guid userUid, SendInviteRequest request, Guid ownerUid,
        int featureId, byte gatingModeId, byte hasMapping, byte isIncluded,
        int? quotaPerPeriod, int? expectedPlanId,
        int? fallbackPlanId, byte fallbackHasMapping, byte fallbackIsIncluded,
        int? fallbackQuotaPerPeriod,
        long actorUserId,
        CancellationToken cancellationToken);

    Task<ProcResult> MarkViewedAsync(Guid userUid, long inviteId, CancellationToken cancellationToken);

    Task<ProcResult> RespondAsync(
        Guid userUid, long inviteId, bool accept, string? remarks, long actorUserId,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<SchoolInviteDto>> GetForSchoolAsync(
        long schoolId, Guid userUid, int? inviteStatusId, CancellationToken cancellationToken);

    Task<IReadOnlyList<MyInviteDto>> GetMineAsync(
        Guid userUid, bool openOnly, CancellationToken cancellationToken);
}

internal sealed class InviteRepository : BaseRepository, IInviteRepository
{
    public InviteRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<InviteRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.App;

    public async Task<(IReadOnlyList<TeacherSearchResultDto> Rows, long Total)> SearchTeachersAsync(
        long schoolId, TeacherSearchFilter filter, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(filter);

        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@SubjectId", filter.SubjectId, DbType.Int32);
        p.Add("@DesignationId", filter.DesignationId, DbType.Int32);
        p.Add("@QualificationId", filter.QualificationId, DbType.Int32);
        p.Add("@ClassLevelId", filter.ClassLevelId, DbType.Int32);
        p.Add("@CityId", filter.CityId, DbType.Int32);
        p.Add("@StateId", filter.StateId, DbType.Int32);
        p.Add("@ExperienceRangeId", filter.ExperienceRangeId, DbType.Int32);
        p.Add("@VerifiedOnly", filter.VerifiedOnly, DbType.Boolean);
        p.Add("@PageNumber", filter.PageNumber, DbType.Int32);
        p.Add("@PageSize", filter.PageSize, DbType.Int32);

        /*
          ⚠️ The total arrives on every row (COUNT(*) OVER()) rather than from a
          second query, so the count and the page describe the same result set.
          An empty page means zero, which is the only honest reading of no rows.
        */
        var rows = (await QueryAsync<TeacherSearchRow>("USP_SearchTeachers", p, cancellationToken)
            .ConfigureAwait(false)).AsList();

        var total = rows.Count > 0 ? rows[0].TotalRecords : 0;

        /*
          ⚠️ MAPPED EXPLICITLY, not inherited. The first version had
          TeacherSearchRow extend the DTO and cast — which would have left
          TotalRecords present on the runtime type of every object handed to
          the serialiser, and left the DTO unsealed so that ContactLeakGuard
          was reflecting over a type somebody could widen from outside.

          🔒 Seventeen lines of assignment is the price of the guarded type
          staying sealed and carrying exactly the columns it is checked for.
        */
        var mapped = rows.Select(r => new TeacherSearchResultDto
        {
            TeacherUid = r.TeacherUid,
            FullName = r.FullName,
            PhotoPath = r.PhotoPath,
            GenderId = r.GenderId,
            QualificationId = r.QualificationId,
            HighestQualificationText = r.HighestQualificationText,
            DesignationId = r.DesignationId,
            TotalExperienceMonths = r.TotalExperienceMonths,
            CurrentSchool = r.CurrentSchool,
            ExpectedSalaryMin = r.ExpectedSalaryMin,
            ExpectedSalaryMax = r.ExpectedSalaryMax,
            CurrentCityId = r.CurrentCityId,
            CurrentStateId = r.CurrentStateId,
            IsVerified = r.IsVerified,
            ProfileCompletionPercent = r.ProfileCompletionPercent,
            HasOpenInvite = r.HasOpenInvite,
            HasApplied = r.HasApplied,
            IsActive = r.IsActive,
        }).ToList();

        return (mapped, total);
    }

    /// <summary>
    /// Send, and consume the invitation allowance in one transaction.
    /// </summary>
    /// <remarks>
    /// 🔴 The four fallback arguments are required for the same reason as
    /// JobRepository.PublishAsync — see G38. Inviting is the other consuming
    /// action (2.64) and it had the identical omission.
    /// </remarks>
    public Task<SendInviteRow> SendAsync(
        long schoolId, Guid userUid, SendInviteRequest request, Guid ownerUid,
        int featureId, byte gatingModeId, byte hasMapping, byte isIncluded,
        int? quotaPerPeriod, int? expectedPlanId,
        int? fallbackPlanId, byte fallbackHasMapping, byte fallbackIsIncluded,
        int? fallbackQuotaPerPeriod,
        long actorUserId,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@TeacherUid", request.TeacherUid, DbType.Guid);
        p.Add("@BranchId", request.BranchId, DbType.Int64);
        p.Add("@JobId", request.JobId, DbType.Int64);
        p.Add("@Message", request.Message, DbType.String, size: 2000);
        p.Add("@OwnerUid", ownerUid, DbType.Guid);
        p.Add("@FeatureId", featureId, DbType.Int32);
        p.Add("@GatingModeId", gatingModeId, DbType.Byte);
        p.Add("@HasMapping", hasMapping, DbType.Byte);
        p.Add("@IsIncluded", isIncluded, DbType.Byte);
        p.Add("@QuotaPerPeriod", quotaPerPeriod, DbType.Int32);
        p.Add("@ExpectedPlanId", expectedPlanId, DbType.Int32);
        p.Add("@FallbackPlanId", fallbackPlanId, DbType.Int32);
        p.Add("@FallbackHasMapping", fallbackHasMapping, DbType.Byte);
        p.Add("@FallbackIsIncluded", fallbackIsIncluded, DbType.Byte);
        p.Add("@FallbackQuotaPerPeriod", fallbackQuotaPerPeriod, DbType.Int32);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<SendInviteRow>("USP_SendInvite", p, cancellationToken);
    }

    public Task<ProcResult> MarkViewedAsync(Guid userUid, long inviteId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@InviteId", inviteId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_MarkInviteViewed", p, cancellationToken);
    }

    public Task<ProcResult> RespondAsync(
        Guid userUid, long inviteId, bool accept, string? remarks, long actorUserId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@InviteId", inviteId, DbType.Int64);
        p.Add("@Accept", accept, DbType.Boolean);
        p.Add("@TeacherRemarks", remarks, DbType.String, size: 1000);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_RespondToInvite", p, cancellationToken);
    }

    public async Task<IReadOnlyList<SchoolInviteDto>> GetForSchoolAsync(
        long schoolId, Guid userUid, int? inviteStatusId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@InviteStatusId", inviteStatusId, DbType.Int32);
        p.Add("@Top", 200, DbType.Int32);

        var rows = await QueryAsync<SchoolInviteDto>("USP_GetInvitesForSchool", p, cancellationToken)
            .ConfigureAwait(false);

        return rows.AsList();
    }

    public async Task<IReadOnlyList<MyInviteDto>> GetMineAsync(
        Guid userUid, bool openOnly, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@OpenOnly", openOnly, DbType.Boolean);

        var rows = await QueryAsync<MyInviteDto>("USP_GetMyInvites", p, cancellationToken)
            .ConfigureAwait(false);

        return rows.AsList();
    }
}

/// <summary>
/// The search row exactly as <c>USP_SearchTeachers</c> returns it.
/// </summary>
/// <remarks>
/// <para>
/// ⚠️ A STANDALONE TYPE, NOT A SUBCLASS OF THE DTO — and deliberately so. The
/// first version inherited, which meant the DTO had to be unsealed and every
/// object reaching the serialiser was really a row carrying
/// <c>TotalRecords</c>. Both are small things that make the guarded shape less
/// trustworthy: ContactLeakGuard reflects over the DTO, and a type anybody can
/// derive from is a type anybody can widen.
/// </para>
/// <para>
/// 🔒 So this one is internal, sealed, never serialised, and mapped across by
/// hand. <c>TotalRecords</c> is paging plumbing and belongs in the response
/// envelope, not on every row of the payload.
/// </para>
/// </remarks>
internal sealed class TeacherSearchRow
{
    public Guid TeacherUid { get; set; }
    public string FullName { get; set; } = string.Empty;
    public string? PhotoPath { get; set; }
    public int? GenderId { get; set; }
    public int? QualificationId { get; set; }
    public string? HighestQualificationText { get; set; }
    public int? DesignationId { get; set; }
    public int? TotalExperienceMonths { get; set; }
    public string? CurrentSchool { get; set; }
    public decimal? ExpectedSalaryMin { get; set; }
    public decimal? ExpectedSalaryMax { get; set; }
    public int? CurrentCityId { get; set; }
    public int? CurrentStateId { get; set; }
    public bool IsVerified { get; set; }
    public byte ProfileCompletionPercent { get; set; }
    public bool HasOpenInvite { get; set; }
    public bool HasApplied { get; set; }
    public bool IsActive { get; set; }
    public long TotalRecords { get; set; }
}
