using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Domain.Billing;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

/// <summary>A plan row as the catalog procedure returns it.</summary>
/// <remarks>
/// 🔴 <c>IsActive</c> arrives through an alias and cannot work without one —
/// Dapper does not strip underscores (2.61, G25).
/// </remarks>
internal sealed class CatalogPlanRow
{
    public int PlanId { get; set; }
    public string PlanCode { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public int UserTypeId { get; set; }
    public int? DurationDays { get; set; }
    public decimal Price { get; set; }
    public bool IsDefault { get; set; }
    public bool IsActive { get; set; }
    public int DisplayOrder { get; set; }
}

internal sealed class CatalogMappingRow
{
    public int PlanId { get; set; }
    public int FeatureId { get; set; }
    public string FeatureCode { get; set; } = string.Empty;
    public string FeatureName { get; set; } = string.Empty;
    public bool IsIncluded { get; set; }
    public int? QuotaPerPeriod { get; set; }
}

/// <summary>The result of <c>USP_RequestPlanChange</c>.</summary>
internal sealed class PlanChangeRow
{
    public int Status { get; set; }
    public string? Code { get; set; }
    public string? Message { get; set; }
    public long? RequestId { get; set; }
    public string? RequestNo { get; set; }
    public long? PaymentId { get; set; }
    public Guid? PaymentUid { get; set; }
    public decimal? PriceQuoted { get; set; }
}

/// <summary>
/// The result of <c>USP_VerifyPayment</c> — the verify half of the seam.
/// </summary>
/// <remarks>
/// 🔴 It carries everything the ACTIVATION half needs (owner, plan, duration),
/// because activation is in another database and cannot look any of it up
/// (2.2). The already-verified path returns the identical payload, which is
/// what lets a retry of a half-completed verification finish the job rather
/// than reporting success and doing nothing (6.5-A).
/// </remarks>
internal sealed class VerifyPaymentRow
{
    public int Status { get; set; }
    public string? Code { get; set; }
    public string? Message { get; set; }
    public string? ReceiptNo { get; set; }
    public bool AlreadyVerified { get; set; }
    public Guid? EntityUid { get; set; }
    public int? PlanId { get; set; }
    public string? PlanName { get; set; }
    public int? DurationDays { get; set; }
    public Guid? PaymentUid { get; set; }
    public long? RequestId { get; set; }
}

internal sealed class PendingPaymentRow
{
    public long PaymentId { get; set; }
    public Guid PaymentUid { get; set; }
    public long RequestId { get; set; }
    public string RequestNo { get; set; } = string.Empty;
    public Guid EntityUid { get; set; }
    public Guid? OrganizationUid { get; set; }
    public long RequestorUserId { get; set; }
    public DateTime SubmittedOn { get; set; }
    public int PlanId { get; set; }
    public string PlanCode { get; set; } = string.Empty;
    public string PlanName { get; set; } = string.Empty;
    public int UserTypeId { get; set; }
    public int? DurationDays { get; set; }
    public decimal Amount { get; set; }
    public decimal? PriceQuoted { get; set; }
    public int PaymentModeId { get; set; }
    public string PaymentModeName { get; set; } = string.Empty;
    public string? GatewayRefNo { get; set; }
    public string? Remarks { get; set; }
    public DateTime CreatedOn { get; set; }
    public decimal ShortBy { get; set; }
    public bool AmountDiffers { get; set; }
    public long TotalRecords { get; set; }
}

/// <summary>
/// 🔴 Standalone, for the same reason the DTO is — see PaymentDetailDto. An
/// inherited row type would also carry TotalRecords, which this read does not
/// return and the form has no use for.
/// </summary>
internal sealed class PaymentDetailRow
{
    public long PaymentId { get; set; }
    public Guid PaymentUid { get; set; }
    public long RequestId { get; set; }
    public string RequestNo { get; set; } = string.Empty;
    public Guid EntityUid { get; set; }
    public Guid? OrganizationUid { get; set; }
    public DateTime SubmittedOn { get; set; }
    public int PlanId { get; set; }
    public string PlanCode { get; set; } = string.Empty;
    public string PlanName { get; set; } = string.Empty;
    public int UserTypeId { get; set; }
    public int? DurationDays { get; set; }
    public decimal Amount { get; set; }
    public decimal? PriceQuoted { get; set; }
    public int PaymentModeId { get; set; }
    public string PaymentModeName { get; set; } = string.Empty;
    public string? GatewayRefNo { get; set; }
    public string? Remarks { get; set; }
    public DateTime CreatedOn { get; set; }
    public decimal ShortBy { get; set; }
    public bool AmountDiffers { get; set; }

    public int PaymentStatusId { get; set; }
    public string PaymentStatusCode { get; set; } = string.Empty;
    public DateTime? PaidOn { get; set; }
    public long? VerifiedByUserId { get; set; }
    public int RequestStatusId { get; set; }
    public string? ReceiptNo { get; set; }
    public DateTime? ReceiptIssuedOn { get; set; }
}

internal interface IBillingRepository
{
    /// <summary>The public plans for one user type, with their mappings.</summary>
    Task<(IReadOnlyList<CatalogPlanRow> Plans, IReadOnlyList<CatalogMappingRow> Mappings)>
        GetCatalogAsync(int userTypeId, CancellationToken cancellationToken);

    Task<PlanChangeRow> RequestPlanChangeAsync(
        Guid entityUid, Guid? organizationUid, long requestorUserId,
        int userTypeId, int planId, int paymentModeId, CancellationToken cancellationToken);

    Task<IReadOnlyList<PendingPaymentRow>> GetPendingAsync(
        int pageNumber, int pageSize, CancellationToken cancellationToken);

    Task<PaymentDetailRow?> GetPaymentAsync(long paymentId, CancellationToken cancellationToken);

    Task<VerifyPaymentRow> VerifyAsync(
        long paymentId, decimal? amount, int? paymentModeId, string? referenceNo,
        string? remarks, DateTime? paidOn, long? verifiedByUserId, string verifiedVia,
        CancellationToken cancellationToken);
}

/// <summary>
/// Billing's jp_mdm half: the catalog, the request, the queue, the verification.
/// </summary>
/// <remarks>
/// <para>
/// 🔒 A payment buys CAPABILITY and never a teacher's contact details. Nothing
/// here references <c>fn_TeacherContactUnlocked</c> or any contact column, and
/// the 2.56 greps assert that in both directions (LOCKED).
/// </para>
/// <para>
/// 🔴 ACTIVATION IS NOT HERE. The subscription lives in jp_app and no query may
/// cross (2.2), so the seam is at the SERVICE — see
/// <see cref="Services.IBillingService"/>. This repository is deliberately
/// unable to activate anything.
/// </para>
/// </remarks>
internal sealed class BillingRepository : BaseRepository, IBillingRepository
{
    public BillingRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<BillingRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.Mdm;

    public Task<(IReadOnlyList<CatalogPlanRow>, IReadOnlyList<CatalogMappingRow>)>
        GetCatalogAsync(int userTypeId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserTypeId", userTypeId, DbType.Int32);

        return QueryMultipleAsync<(IReadOnlyList<CatalogPlanRow>, IReadOnlyList<CatalogMappingRow>)>(
            "USP_GetPlanCatalog",
            async grid =>
            {
                var plans = (await grid.ReadAsync<CatalogPlanRow>().ConfigureAwait(false)).ToList();
                var maps = (await grid.ReadAsync<CatalogMappingRow>().ConfigureAwait(false)).ToList();

                return (plans, maps);
            },
            p,
            cancellationToken);
    }

    public Task<PlanChangeRow> RequestPlanChangeAsync(
        Guid entityUid, Guid? organizationUid, long requestorUserId,
        int userTypeId, int planId, int paymentModeId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@EntityUid", entityUid, DbType.Guid);
        p.Add("@OrganizationUid", organizationUid, DbType.Guid);
        p.Add("@RequestorUserId", requestorUserId, DbType.Int64);
        p.Add("@UserTypeId", userTypeId, DbType.Int32);
        p.Add("@PlanId", planId, DbType.Int32);
        p.Add("@PaymentModeId", paymentModeId, DbType.Int32);

        return QuerySingleAsync<PlanChangeRow>("USP_RequestPlanChange", p, cancellationToken);
    }

    public Task<IReadOnlyList<PendingPaymentRow>> GetPendingAsync(
        int pageNumber, int pageSize, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@PageNumber", pageNumber, DbType.Int32);
        p.Add("@PageSize", pageSize, DbType.Int32);

        return QueryAsync<PendingPaymentRow>("USP_GetPendingPayments", p, cancellationToken);
    }

    public Task<PaymentDetailRow?> GetPaymentAsync(long paymentId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@PaymentId", paymentId, DbType.Int64);

        return QueryFirstOrDefaultAsync<PaymentDetailRow>("USP_GetPaymentForVerify", p, cancellationToken);
    }

    public Task<VerifyPaymentRow> VerifyAsync(
        long paymentId, decimal? amount, int? paymentModeId, string? referenceNo,
        string? remarks, DateTime? paidOn, long? verifiedByUserId, string verifiedVia,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@PaymentId", paymentId, DbType.Int64);
        p.Add("@Amount", amount, DbType.Decimal);
        p.Add("@PaymentModeId", paymentModeId, DbType.Int32);
        p.Add("@GatewayRefNo", referenceNo, DbType.String, size: 100);
        p.Add("@Remarks", remarks, DbType.String, size: 500);
        p.Add("@PaidOn", paidOn, DbType.DateTime2);
        p.Add("@VerifiedByUserId", verifiedByUserId, DbType.Int64);

        /*
          🔴 The KIND of verification, not just the person. The gateway caller
          that arrives later has no user at all, and a NULL verifier with no
          explanation would be unreadable the first time it appeared — so the
          receipt's CHECK constraint requires that an ADMIN verification names
          an admin (6.5-A).
        */
        p.Add("@VerifiedVia", verifiedVia, DbType.AnsiString, size: 10);

        return QuerySingleAsync<VerifyPaymentRow>("USP_VerifyPayment", p, cancellationToken);
    }
}
