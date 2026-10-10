using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Domain.Offers;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

/// <summary>Offer Lite, over the jp_app procedures. Phase 6A.</summary>
internal interface IOfferRepository
{
    Task<ProcResult> SendAsync(
        long schoolId, Guid userUid, long applicationId, SendOfferRequest request,
        long actorUserId, CancellationToken cancellationToken);

    Task<ProcResult> RespondAsync(
        long teacherId, long offerId, bool accept, string? remarks, long actorUserId,
        CancellationToken cancellationToken);

    Task<ProcResult> WithdrawAsync(
        long schoolId, Guid userUid, long offerId, string? reason, long actorUserId,
        CancellationToken cancellationToken);

    Task<ProcResult> ConfirmHireAsync(
        long schoolId, Guid userUid, long applicationId, string? remarks, long actorUserId,
        CancellationToken cancellationToken);

    Task<IReadOnlyList<OfferDto>> GetForApplicationAsync(
        long schoolId, Guid userUid, long applicationId, CancellationToken cancellationToken);

    Task<IReadOnlyList<MyOfferDto>> GetMyOffersAsync(
        Guid userUid, bool liveOnly, CancellationToken cancellationToken);
}

internal sealed class OfferRepository : BaseRepository, IOfferRepository
{
    public OfferRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<OfferRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.App;

    public Task<ProcResult> SendAsync(
        long schoolId, Guid userUid, long applicationId, SendOfferRequest request,
        long actorUserId, CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@ApplicationId", applicationId, DbType.Int64);
        p.Add("@DesignationId", request.DesignationId, DbType.Int32);
        p.Add("@OfferedSalary", request.OfferedSalary, DbType.Decimal);
        p.Add("@JoiningDate", request.JoiningDate, DbType.Date);
        p.Add("@ReportingTime", request.ReportingTime, DbType.Time);
        p.Add("@TermsAndConditions", request.TermsAndConditions, DbType.String, size: -1);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_SendOffer", p, cancellationToken);
    }

    public Task<ProcResult> RespondAsync(
        long teacherId, long offerId, bool accept, string? remarks, long actorUserId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@TeacherId", teacherId, DbType.Int64);
        p.Add("@OfferId", offerId, DbType.Int64);
        p.Add("@Accept", accept, DbType.Boolean);
        p.Add("@TeacherRemarks", remarks, DbType.String, size: 1000);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_RespondToOffer", p, cancellationToken);
    }

    public Task<ProcResult> WithdrawAsync(
        long schoolId, Guid userUid, long offerId, string? reason, long actorUserId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@OfferId", offerId, DbType.Int64);
        p.Add("@Reason", reason, DbType.String, size: 1000);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_WithdrawOffer", p, cancellationToken);
    }

    public Task<ProcResult> ConfirmHireAsync(
        long schoolId, Guid userUid, long applicationId, string? remarks, long actorUserId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@ApplicationId", applicationId, DbType.Int64);
        p.Add("@Remarks", remarks, DbType.String, size: 1000);
        p.Add("@ActorUserId", actorUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_ConfirmHire", p, cancellationToken);
    }

    public async Task<IReadOnlyList<OfferDto>> GetForApplicationAsync(
        long schoolId, Guid userUid, long applicationId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SchoolId", schoolId, DbType.Int64);
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@ApplicationId", applicationId, DbType.Int64);

        var rows = await QueryAsync<OfferDto>("USP_GetOffersForApplication", p, cancellationToken)
            .ConfigureAwait(false);

        return rows.AsList();
    }

    public async Task<IReadOnlyList<MyOfferDto>> GetMyOffersAsync(
        Guid userUid, bool liveOnly, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserUid", userUid, DbType.Guid);
        p.Add("@LiveOnly", liveOnly, DbType.Boolean);

        var rows = await QueryAsync<MyOfferDto>("USP_GetMyOffers", p, cancellationToken)
            .ConfigureAwait(false);

        return rows.AsList();
    }
}
