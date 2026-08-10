using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Domain.Approvals;
using JP.Domain.Common;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

internal interface IApprovalRepository
{
    Task<SubmitProcResult> SubmitAsync(SubmitApprovalRequest request, Guid? organizationUid, long requestorUserId, string? ipAddress, CancellationToken cancellationToken);

    Task<(IReadOnlyList<ApprovalRequestRow> Rows, long Total)> ListAsync(ApprovalRequestFilter filter, Guid? organizationUid, CancellationToken cancellationToken);

    Task<ApprovalRequestDetailDto?> GetByIdAsync(long requestId, CancellationToken cancellationToken);

    Task<ProcessActionProcResult> ProcessActionAsync(long requestId, int actionTypeId, long actionByUserId, int rowVersion, int? rejectionReasonId, string? remarks, string? ipAddress, string? actorRoleIds, CancellationToken cancellationToken);

    Task<ProcResult> ResubmitAsync(long requestId, long actionByUserId, string? remarks, int rowVersion, string? ipAddress, CancellationToken cancellationToken);

    Task<IReadOnlyList<PendingCountDto>> GetPendingCountsAsync(Guid? organizationUid, CancellationToken cancellationToken);

    /// <summary>
    /// Approvals that completed and were meant to provision something.
    /// </summary>
    /// <remarks>
    /// Half of the reconciliation: this side knows what SHOULD exist, jp_app
    /// knows what does. Neither can join to the other (decision 2.2), so the
    /// service carries the list across.
    /// </remarks>
    Task<IReadOnlyList<CompletedApprovalRow>> GetCompletedForReconciliationAsync(int sinceDays, CancellationToken cancellationToken);

    Task<ProcResult> SaveDocumentAsync(long requestId, int documentTypeId, string filePath, string fileName, int fileSizeKb, string mimeType, long actionByUserId, CancellationToken cancellationToken);

    Task<ProcResult> VerifyDocumentAsync(long documentId, bool isVerified, long actionByUserId, int? rejectionReasonId, string? remarks, CancellationToken cancellationToken);

    /// <summary>
    /// Which request a document belongs to.
    /// </summary>
    /// <remarks>
    /// Returns the id only, never the path. A path without its request is
    /// something a caller can open with nothing to check it against — the
    /// access rule lives on the request.
    /// </remarks>
    Task<long?> GetRequestIdForDocumentAsync(long documentId, CancellationToken cancellationToken);
}

internal sealed class ApprovalRepository : BaseRepository, IApprovalRepository
{
    public ApprovalRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<ApprovalRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.Mdm;

    /// <summary>
    /// Submit a request.
    /// </summary>
    /// <remarks>
    /// 🔴 <paramref name="organizationUid"/> and <paramref name="requestorUserId"/>
    /// are separate parameters, NOT taken off <paramref name="request"/>. The
    /// service reads both from the JWT (decision 2.39), and there is no overload
    /// that lets a caller supply them from a payload.
    /// </remarks>
    public Task<SubmitProcResult> SubmitAsync(
        SubmitApprovalRequest request,
        Guid? organizationUid,
        long requestorUserId,
        string? ipAddress,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(request);

        var p = new DynamicParameters();
        p.Add("@RequestTypeId", request.RequestTypeId, DbType.Int32);
        p.Add("@EntityUid", request.EntityUid, DbType.Guid);
        p.Add("@RequestorUserId", requestorUserId, DbType.Int64);
        p.Add("@OrganizationUid", organizationUid, DbType.Guid);

        // school payload
        p.Add("@SchoolName", request.SchoolName, DbType.String, size: 200);
        p.Add("@SchoolTypeId", request.SchoolTypeId, DbType.Int32);
        p.Add("@BoardId", request.BoardId, DbType.Int32);
        p.Add("@AffiliationNumber", request.AffiliationNumber, DbType.AnsiString, size: 50);
        p.Add("@RegistrationNo", request.RegistrationNo, DbType.AnsiString, size: 50);
        p.Add("@LogoPath", request.LogoPath, DbType.String, size: 500);
        p.Add("@GroupType", request.GroupType, DbType.Byte);
        p.Add("@EstablishedYear", request.EstablishedYear, DbType.Int16);
        p.Add("@AddressLine1", request.AddressLine1, DbType.String, size: 250);
        p.Add("@AddressLine2", request.AddressLine2, DbType.String, size: 250);
        p.Add("@CityId", request.CityId, DbType.Int32);
        p.Add("@DistrictId", request.DistrictId, DbType.Int32);
        p.Add("@StateId", request.StateId, DbType.Int32);
        p.Add("@Pincode", request.Pincode, DbType.AnsiString, size: 10);
        p.Add("@PrincipalName", request.PrincipalName, DbType.String, size: 150);
        p.Add("@PrincipalMobile", request.PrincipalMobile, DbType.AnsiString, size: 15);
        p.Add("@HrContactName", request.HrContactName, DbType.String, size: 150);
        p.Add("@HrContactMobile", request.HrContactMobile, DbType.AnsiString, size: 15);
        p.Add("@ContactEmail", request.ContactEmail, DbType.String, size: 150);
        p.Add("@ContactMobile", request.ContactMobile, DbType.AnsiString, size: 15);
        p.Add("@Website", request.Website, DbType.String, size: 255);
        p.Add("@AboutSchool", request.AboutSchool, DbType.String, size: -1);

        // teacher payload
        p.Add("@FullName", request.FullName, DbType.String, size: 150);
        p.Add("@DOB", request.Dob?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        p.Add("@GenderId", request.GenderId, DbType.Int32);
        p.Add("@QualificationId", request.QualificationId, DbType.Int32);
        p.Add("@TotalExperienceMonths", request.TotalExperienceMonths, DbType.Int32);
        p.Add("@CurrentCityId", request.CurrentCityId, DbType.Int32);
        p.Add("@CurrentStateId", request.CurrentStateId, DbType.Int32);
        p.Add("@CurrentSchool", request.CurrentSchool, DbType.String, size: 200);

        // The procedure splits this with STRING_SPLIT and de-duplicates.
        p.Add(
            "@SubjectIds",
            request.SubjectIds is { Count: > 0 } ? string.Join(',', request.SubjectIds) : null,
            DbType.AnsiString,
            size: 500);

        p.Add("@IpAddress", ipAddress, DbType.AnsiString, size: 45);

        return QuerySingleAsync<SubmitProcResult>("USP_SubmitApprovalRequest", p, cancellationToken);
    }

    /// <summary>
    /// The admin queue. Two result sets: the page, then the total.
    /// </summary>
    /// <remarks>
    /// 🔴 <paramref name="organizationUid"/> is applied as a FILTER here, from
    /// the caller's own claim. A school passes its own and can therefore only
    /// ever see its own requests; an admin passes null and sees everything. The
    /// client cannot influence which (decision 2.39).
    /// </remarks>
    public Task<(IReadOnlyList<ApprovalRequestRow> Rows, long Total)> ListAsync(
        ApprovalRequestFilter filter,
        Guid? organizationUid,
        CancellationToken cancellationToken)
    {
        ArgumentNullException.ThrowIfNull(filter);

        var p = new DynamicParameters();
        p.Add("@RequestTypeId", filter.RequestTypeId, DbType.Int32);
        p.Add("@StatusId", filter.StatusId, DbType.Int32);
        p.Add("@AssignedToUserId", filter.AssignedToUserId, DbType.Int64);
        p.Add("@OrganizationUid", organizationUid, DbType.Guid);
        p.Add("@Search", filter.Search, DbType.String, size: 150);
        p.Add("@FromDate", filter.FromDate?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        p.Add("@ToDate", filter.ToDate?.ToDateTime(TimeOnly.MinValue), DbType.Date);
        p.Add("@PageNumber", filter.PageNumber, DbType.Int32);
        p.Add("@PageSize", filter.PageSize, DbType.Int32);

        // Passed straight through. The procedure compares these against a
        // fixed list and falls back to the queue's own order for anything it
        // does not recognise — there is no second whitelist here to drift out
        // of step with that one.
        p.Add("@SortBy", filter.SortBy, DbType.AnsiString, size: 30);
        p.Add("@SortDirection", filter.SortDirection, DbType.AnsiString, size: 4);

        return QueryMultipleAsync<(IReadOnlyList<ApprovalRequestRow>, long)>(
            "USP_GetApprovalRequestList",
            async grid =>
            {
                var rows = (await grid.ReadAsync<ApprovalRequestRow>().ConfigureAwait(false)).AsList();
                var total = await grid.ReadSingleAsync<long>().ConfigureAwait(false);
                return (rows, total);
            },
            p,
            cancellationToken);
    }

    /// <summary>
    /// One request, assembled from five result sets.
    /// </summary>
    /// <remarks>
    /// Result sets 2 and 3 (school detail, teacher detail) are empty for the
    /// type that does not apply, and the documents and payments sets are empty
    /// until something is uploaded or paid. Empty is data, not a failure — the
    /// reader must not treat it as one.
    /// </remarks>
    public async Task<ApprovalRequestDetailDto?> GetByIdAsync(
        long requestId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@RequestId", requestId, DbType.Int64);
        p.Add("@RequestUid", null, DbType.Guid);

        return await QueryMultipleAsync<ApprovalRequestDetailDto?>(
            "USP_GetApprovalRequestById",
            async grid =>
            {
                var header = await grid.ReadFirstOrDefaultAsync<ApprovalRequestRow>().ConfigureAwait(false);
                if (header is null)
                {
                    return null;
                }

                var school = await grid.ReadFirstOrDefaultAsync<SchoolRegistrationDetailDto>().ConfigureAwait(false);
                var teacher = await grid.ReadFirstOrDefaultAsync<TeacherRegistrationDetailDto>().ConfigureAwait(false);
                var docs = (await grid.ReadAsync<RequestDocumentDto>().ConfigureAwait(false)).AsList();
                var trail = (await grid.ReadAsync<RequestActionDto>().ConfigureAwait(false)).AsList();
                var payments = (await grid.ReadAsync<RequestPaymentDto>().ConfigureAwait(false)).AsList();

                return new ApprovalRequestDetailDto
                {
                    Header = ToDto(header),
                    SchoolDetail = school,
                    TeacherDetail = teacher,
                    Documents = docs,
                    Trail = trail,
                    Payments = payments,
                };
            },
            p,
            cancellationToken).ConfigureAwait(false);
    }

    public Task<ProcessActionProcResult> ProcessActionAsync(
        long requestId,
        int actionTypeId,
        long actionByUserId,
        int rowVersion,
        int? rejectionReasonId,
        string? remarks,
        string? ipAddress,
        string? actorRoleIds,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@RequestId", requestId, DbType.Int64);
        p.Add("@ActionTypeId", actionTypeId, DbType.Int32);
        p.Add("@ActionByUserId", actionByUserId, DbType.Int64);
        p.Add("@RowVersion", rowVersion, DbType.Int32);

        // The procedure drops this for an approve. Sent regardless rather than
        // conditionally, so there is one rule about it and it lives in one place.
        p.Add("@RejectionReasonId", rejectionReasonId, DbType.Int32);

        p.Add("@Remarks", remarks, DbType.String, size: 1000);
        p.Add("@IpAddress", ipAddress, DbType.AnsiString, size: 45);
        p.Add("@ActorRoleIds", actorRoleIds, DbType.AnsiString, size: 200);

        return QuerySingleAsync<ProcessActionProcResult>("USP_ProcessApprovalAction", p, cancellationToken);
    }

    public Task<ProcResult> ResubmitAsync(
        long requestId,
        long actionByUserId,
        string? remarks,
        int rowVersion,
        string? ipAddress,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@RequestId", requestId, DbType.Int64);
        p.Add("@ActionByUserId", actionByUserId, DbType.Int64);
        p.Add("@Remarks", remarks, DbType.String, size: 1000);
        p.Add("@RowVersion", rowVersion, DbType.Int32);
        p.Add("@IpAddress", ipAddress, DbType.AnsiString, size: 45);

        return QuerySingleAsync<ProcResult>("USP_ResubmitApprovalRequest", p, cancellationToken);
    }

    public Task<IReadOnlyList<PendingCountDto>> GetPendingCountsAsync(
        Guid? organizationUid,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@OrganizationUid", organizationUid, DbType.Guid);

        return QueryAsync<PendingCountDto>("USP_GetPendingCountsByType", p, cancellationToken);
    }

    public Task<IReadOnlyList<CompletedApprovalRow>> GetCompletedForReconciliationAsync(
        int sinceDays,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@SinceDays", sinceDays, DbType.Int32);

        return QueryAsync<CompletedApprovalRow>(
            "USP_GetCompletedApprovalsForReconciliation", p, cancellationToken);
    }

    public Task<ProcResult> SaveDocumentAsync(
        long requestId,
        int documentTypeId,
        string filePath,
        string fileName,
        int fileSizeKb,
        string mimeType,
        long actionByUserId,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@RequestId", requestId, DbType.Int64);
        p.Add("@DocumentTypeId", documentTypeId, DbType.Int32);
        p.Add("@FilePath", filePath, DbType.String, size: 500);
        p.Add("@FileName", fileName, DbType.String, size: 255);
        p.Add("@FileSizeKb", fileSizeKb, DbType.Int32);
        p.Add("@MimeType", mimeType, DbType.AnsiString, size: 100);
        p.Add("@ActionByUserId", actionByUserId, DbType.Int64);

        return QuerySingleAsync<ProcResult>("USP_SaveRequestDocument", p, cancellationToken);
    }

    public Task<ProcResult> VerifyDocumentAsync(
        long documentId,
        bool isVerified,
        long actionByUserId,
        int? rejectionReasonId,
        string? remarks,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@DocumentId", documentId, DbType.Int64);
        p.Add("@IsVerified", isVerified ? (byte)1 : (byte)0, DbType.Byte);
        p.Add("@ActionByUserId", actionByUserId, DbType.Int64);
        p.Add("@RejectionReasonId", rejectionReasonId, DbType.Int32);
        p.Add("@Remarks", remarks, DbType.String, size: 1000);

        return QuerySingleAsync<ProcResult>("USP_VerifyDocument", p, cancellationToken);
    }

    public Task<long?> GetRequestIdForDocumentAsync(long documentId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@DocumentId", documentId, DbType.Int64);

        return QueryFirstOrDefaultAsync<long?>("USP_GetDocumentRequestId", p, cancellationToken);
    }

    internal static ApprovalRequestListItemDto ToDto(ApprovalRequestRow r) => new()
    {
        RequestId = r.RequestId,
        RequestUid = r.RequestUid,
        RequestNo = r.RequestNo,
        RequestTypeId = r.RequestTypeId,
        RequestTypeCode = r.RequestTypeCode,
        RequestTypeName = r.RequestTypeName,
        StatusId = r.StatusId,
        StatusCode = r.StatusCode,
        StatusName = r.StatusName,
        CurrentApprovalLevel = r.CurrentApprovalLevel,
        EntityUid = r.EntityUid,
        OrganizationUid = r.OrganizationUid,
        RequestorUserId = r.RequestorUserId,
        ApproverUserId = r.ApproverUserId,
        SubmittedOn = r.SubmittedOn,
        CompletedOn = r.CompletedOn,
        RowVersion = r.RowVersion,
        EntityName = r.EntityName,
        WaitingDays = r.WaitingDays,
    };
}
