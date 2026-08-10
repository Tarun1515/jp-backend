using JP.Domain.Common;

namespace JP.Domain.Approvals;

/// <summary>
/// Submit a request for approval.
/// </summary>
/// <remarks>
/// 🔴 There is no OrganizationUid, RequestorUserId or SchoolId on this type,
/// and there must never be. All three come from the JWT (decision 2.39). A
/// client that could name its own organisation could submit on behalf of
/// another school.
///
/// EntityUid IS on the request, because it identifies the thing being
/// registered rather than the caller — and the service still checks it against
/// the caller's own scope before use.
/// </remarks>
public sealed record SubmitApprovalRequest
{
    public int RequestTypeId { get; init; }
    public Guid EntityUid { get; init; }

    // ---- school payload (request types 1 and 3) ---------------------------
    public string? SchoolName { get; init; }
    public int? SchoolTypeId { get; init; }
    public int? BoardId { get; init; }
    public string? AffiliationNumber { get; init; }
    public string? RegistrationNo { get; init; }
    public string? LogoPath { get; init; }
    public byte? GroupType { get; init; }
    public short? EstablishedYear { get; init; }
    public string? AddressLine1 { get; init; }
    public string? AddressLine2 { get; init; }

    /// <summary>⚠️ Nullable, and stays nullable: the city dataset is empty (2.47).</summary>
    public int? CityId { get; init; }
    public int? DistrictId { get; init; }
    public int? StateId { get; init; }

    public string? Pincode { get; init; }
    public string? PrincipalName { get; init; }
    public string? PrincipalMobile { get; init; }
    public string? HrContactName { get; init; }
    public string? HrContactMobile { get; init; }
    public string? ContactEmail { get; init; }
    public string? ContactMobile { get; init; }
    public string? Website { get; init; }
    public string? AboutSchool { get; init; }

    // ---- teacher payload (request type 2) ---------------------------------
    public string? FullName { get; init; }

    /// <summary>A calendar date, not an instant (decision 2.28).</summary>
    public DateOnly? Dob { get; init; }

    public int? GenderId { get; init; }
    public int? QualificationId { get; init; }
    public int? TotalExperienceMonths { get; init; }
    public int? CurrentCityId { get; init; }
    public int? CurrentStateId { get; init; }
    public string? CurrentSchool { get; init; }

    public IReadOnlyList<int>? SubjectIds { get; init; }
}

/// <summary>The submit result. <see cref="AlreadyPending"/> is a success, not a failure.</summary>
public sealed record SubmitApprovalResponse
{
    public long RequestId { get; init; }
    public string RequestNo { get; init; } = string.Empty;

    /// <summary>
    /// True when an open request already existed and this call returned it
    /// rather than creating a second. A double-clicked submit lands here.
    /// </summary>
    public bool AlreadyPending { get; init; }

    public string Message { get; init; } = string.Empty;
}

public sealed record ApprovalRequestListItemDto
{
    public long RequestId { get; init; }
    public Guid RequestUid { get; init; }
    public string RequestNo { get; init; } = string.Empty;
    public int RequestTypeId { get; init; }
    public string RequestTypeCode { get; init; } = string.Empty;
    public string RequestTypeName { get; init; } = string.Empty;
    public int StatusId { get; init; }
    public string StatusCode { get; init; } = string.Empty;
    public string StatusName { get; init; } = string.Empty;
    public byte CurrentApprovalLevel { get; init; }
    public Guid EntityUid { get; init; }
    public Guid? OrganizationUid { get; init; }
    public long RequestorUserId { get; init; }
    public long? ApproverUserId { get; init; }
    public DateTime SubmittedOn { get; init; }
    public DateTime? CompletedOn { get; init; }
    public int RowVersion { get; init; }

    /// <summary>School name or teacher name, whichever this request type carries.</summary>
    public string? EntityName { get; init; }

    /// <summary>Computed in SQL so every surface agrees on it.</summary>
    public int WaitingDays { get; init; }
}

/// <summary>
/// Filters for the admin queue.
/// </summary>
/// <remarks>
/// 🔴 No OrganizationUid. The scope is read from the caller's token in the
/// service (decision 2.39), so there is no field here for a client to set and
/// no path that would honour it. Search, paging and sorting come from
/// <see cref="PagedRequest"/>.
/// </remarks>
public sealed class ApprovalRequestFilter : PagedRequest
{
    public int? RequestTypeId { get; set; }
    public int? StatusId { get; set; }
    public long? AssignedToUserId { get; set; }

    /// <summary>IST calendar date, converted to a UTC range in SQL (2.28).</summary>
    public DateOnly? FromDate { get; set; }
    public DateOnly? ToDate { get; set; }
}

public sealed record ApprovalRequestDetailDto
{
    public ApprovalRequestListItemDto Header { get; init; } = new();
    public SchoolRegistrationDetailDto? SchoolDetail { get; init; }
    public TeacherRegistrationDetailDto? TeacherDetail { get; init; }
    public IReadOnlyList<RequestDocumentDto> Documents { get; init; } = [];
    public IReadOnlyList<RequestActionDto> Trail { get; init; } = [];
    public IReadOnlyList<RequestPaymentDto> Payments { get; init; } = [];
}

public sealed record SchoolRegistrationDetailDto
{
    public long RequestId { get; init; }
    public string SchoolName { get; init; } = string.Empty;
    public int? SchoolTypeId { get; init; }
    public int? BoardId { get; init; }
    public string? AffiliationNumber { get; init; }
    public string? RegistrationNo { get; init; }
    public string? LogoPath { get; init; }
    public byte? GroupType { get; init; }
    public short? EstablishedYear { get; init; }
    public string? AddressLine1 { get; init; }
    public string? AddressLine2 { get; init; }
    public int? CityId { get; init; }
    public int? DistrictId { get; init; }
    public int? StateId { get; init; }
    public string? Pincode { get; init; }
    public string? PrincipalName { get; init; }
    public string? PrincipalMobile { get; init; }
    public string? HrContactName { get; init; }
    public string? HrContactMobile { get; init; }
    public string? ContactEmail { get; init; }
    public string? ContactMobile { get; init; }
    public string? Website { get; init; }
    public string? AboutSchool { get; init; }
}

public sealed record TeacherRegistrationDetailDto
{
    public long RequestId { get; init; }
    public string FullName { get; init; } = string.Empty;
    public DateOnly? Dob { get; init; }
    public int? GenderId { get; init; }
    public int? QualificationId { get; init; }
    public int? TotalExperienceMonths { get; init; }
    public int? CurrentCityId { get; init; }
    public int? CurrentStateId { get; init; }
    public string? CurrentSchool { get; init; }

    /// <summary>Comma-separated ids, aggregated in SQL.</summary>
    public string? SubjectIds { get; init; }
}

public sealed record RequestDocumentDto
{
    public long DocumentId { get; init; }
    public long RequestId { get; init; }
    public int DocumentTypeId { get; init; }
    public string DocumentTypeCode { get; init; } = string.Empty;
    public string DocumentTypeName { get; init; } = string.Empty;
    public bool IsMandatory { get; init; }

    /// <summary>
    /// ⚠️ Internal storage path. The controller does NOT return this to a
    /// client — a document is fetched through /api/documents/{id}, which checks
    /// access. Exposing the path would make the file guessable.
    /// </summary>
    public string FilePath { get; init; } = string.Empty;

    public string FileName { get; init; } = string.Empty;
    public int FileSizeKb { get; init; }
    public string MimeType { get; init; } = string.Empty;
    public int Version { get; init; }
    public bool IsVerified { get; init; }
    public long? VerifiedByUserId { get; init; }
    public DateTime? VerifiedOn { get; init; }
    public int? RejectionReasonId { get; init; }
    public string? RejectionReasonName { get; init; }
    public string? Remarks { get; init; }
    public DateTime CreatedOn { get; init; }
}

public sealed record RequestActionDto
{
    public long ApprovalId { get; init; }
    public long RequestId { get; init; }
    public byte LevelNumber { get; init; }
    public int ActionTypeId { get; init; }
    public string ActionTypeCode { get; init; } = string.Empty;
    public string ActionTypeName { get; init; } = string.Empty;
    public long ActionByUserId { get; init; }

    /// <summary>
    /// Set on a rejection or a resubmission request, null on an approve.
    /// </summary>
    /// <remarks>
    /// Structured alongside <see cref="Remarks"/> rather than instead of it.
    /// The remarks are what the school reads; this is what anybody counting
    /// rejection causes reads, and free text is not countable.
    /// </remarks>
    public int? RejectionReasonId { get; init; }

    public string? RejectionReasonName { get; init; }

    public string? Remarks { get; init; }
    public DateTime ActionOn { get; init; }
    public string? IpAddress { get; init; }
}

public sealed record RequestPaymentDto
{
    public long PaymentId { get; init; }
    public long RequestId { get; init; }
    public int? PlanId { get; init; }
    public decimal Amount { get; init; }
    public int PaymentModeId { get; init; }
    public string PaymentModeName { get; init; } = string.Empty;
    public string? GatewayRefNo { get; init; }
    public int PaymentStatusId { get; init; }
    public string PaymentStatusName { get; init; } = string.Empty;
    public DateTime? PaidOn { get; init; }
    public long? VerifiedByUserId { get; init; }
}

/// <summary>Approve, reject or request a resubmission.</summary>
public sealed record ProcessActionRequest
{
    /// <summary>1 Approve · 2 Reject · 3 RequestResubmit.</summary>
    public int ActionTypeId { get; init; }

    /// <summary>
    /// 🔴 Required. The optimistic concurrency check — two admins with the same
    /// request open must not both succeed (decision 2.46).
    /// </summary>
    public int RowVersion { get; init; }

    public string? Remarks { get; init; }
    public int? RejectionReasonId { get; init; }
}

public sealed record ProcessActionResponse
{
    public long RequestId { get; init; }
    public int NewStatusId { get; init; }
    public byte? CurrentApprovalLevel { get; init; }

    /// <summary>
    /// True when this action finished the request. The API — not the procedure
    /// — then does the cross-database work (decision 2.2).
    /// </summary>
    public bool IsCompleted { get; init; }

    /// <summary>
    /// 🔴 True only when every cross-database step also succeeded.
    ///
    /// False with <see cref="OrchestrationError"/> set means the approval itself
    /// committed but the follow-up did not — the request is Approved while the
    /// user or profile is not yet in place. See the reconciliation query in
    /// <c>database/jp_mdm/90_ops/</c>.
    /// </summary>
    public bool OrchestrationCompleted { get; init; }

    public string? OrchestrationError { get; init; }
    public string Message { get; init; } = string.Empty;
}

public sealed record ResubmitRequest
{
    public string? Remarks { get; init; }
    public int RowVersion { get; init; }
}

public sealed record PendingCountDto
{
    public int RequestTypeId { get; init; }
    public string RequestTypeCode { get; init; } = string.Empty;
    public string RequestTypeName { get; init; } = string.Empty;
    public int PendingCount { get; init; }
    public int OldestWaitingDays { get; init; }
}

/// <summary>
/// An approval that completed but whose cross-database work did not.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 This is the shape of a partial failure: the approval is committed in
/// jp_mdm, the user may well be Active in jp_sso, and jp_app has no school. The
/// person it belongs to can sign in and lands on nothing.
/// </para>
/// <para>
/// <see cref="RequestId"/> is here so the admin screen can offer a retry rather
/// than only reporting the problem. The reconciliation procedure in jp_app
/// answers in terms of <see cref="RequestUid"/> — it is the only key that
/// crosses the database boundary — and the API pairs it back up with the
/// jp_mdm row it came from.
/// </para>
/// </remarks>
public sealed record OrphanedApprovalDto
{
    public long RequestId { get; init; }
    public Guid RequestUid { get; init; }
    public string RequestNo { get; init; } = string.Empty;
    public int RequestTypeId { get; init; }
    public string RequestTypeName { get; init; } = string.Empty;
    public Guid? OrganizationUid { get; init; }
    public long RequestorUserId { get; init; }
    public string? EntityName { get; init; }
    public DateTime CompletedOn { get; init; }
    public int HoursSinceCompleted { get; init; }

    /// <summary>
    /// Why this request is on the list, in words an admin can act on.
    /// </summary>
    /// <remarks>
    /// Composed server-side so every surface says the same thing, and so the
    /// screen never has to infer a cause from a count.
    /// </remarks>
    public string Reason { get; init; } = string.Empty;
}

public sealed record VerifyDocumentRequest
{
    public bool IsVerified { get; init; }
    public int? RejectionReasonId { get; init; }
    public string? Remarks { get; init; }
}
