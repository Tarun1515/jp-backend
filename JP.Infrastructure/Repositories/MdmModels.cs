using JP.Domain.Approvals;

namespace JP.Infrastructure.Repositories;

/// <summary>
/// Raw rows from the jp_mdm procedures.
/// </summary>
/// <remarks>
/// <c>internal</c> like every repository type (decision 2.36). These map
/// one-to-one onto the procedure result sets; the service projects them onto
/// the public DTOs in JP.Domain.
/// </remarks>
internal sealed class MasterRow
{
    public int Id { get; set; }
    public string Code { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public int DisplayOrder { get; set; }
    public int? ParentId { get; set; }

    // Only USP_GetMaster 'DOCUMENT_TYPE' populates these.
    public bool? IsMandatory { get; set; }
    public int? MaxSizeKb { get; set; }
    public string? AllowedExtensions { get; set; }

    // Only 'EXPERIENCE_RANGE'.
    public int? MinMonths { get; set; }
    public int? MaxMonths { get; set; }
}

/// <summary>
/// The submit envelope. Same Status/Code/Message/Id shape as every write
/// procedure (decision 2.21).
/// </summary>
internal sealed class SubmitProcResult : ProcResult
{
}

/// <summary>
/// USP_ProcessApprovalAction's envelope, which carries three extra columns.
/// </summary>
internal sealed class ProcessActionProcResult : ProcResult
{
    public int? NewStatusId { get; set; }

    /// <summary>
    /// The procedure's signal that the cross-database work is now the API's
    /// job — create the profile, activate the user (decision 2.2).
    /// </summary>
    public bool IsCompleted { get; set; }

    public byte? CurrentApprovalLevel { get; set; }
}

internal sealed class ApprovalRequestRow
{
    public long RequestId { get; set; }
    public Guid RequestUid { get; set; }
    public string RequestNo { get; set; } = string.Empty;
    public int RequestTypeId { get; set; }
    public string RequestTypeCode { get; set; } = string.Empty;
    public string RequestTypeName { get; set; } = string.Empty;
    public int StatusId { get; set; }
    public string StatusCode { get; set; } = string.Empty;
    public string StatusName { get; set; } = string.Empty;
    public byte CurrentApprovalLevel { get; set; }
    public Guid EntityUid { get; set; }
    public Guid? OrganizationUid { get; set; }
    public long RequestorUserId { get; set; }
    public long? ApproverUserId { get; set; }
    public DateTime SubmittedOn { get; set; }
    public DateTime? CompletedOn { get; set; }
    public int RowVersion { get; set; }
    public string? EntityName { get; set; }
    public int WaitingDays { get; set; }
}

/// <summary>
/// The one row USP_SaveRequestDocument needs before it will accept an upload:
/// the per-type limits, read rather than hardcoded (decision 2.47).
/// </summary>
internal sealed class DocumentTypeRow
{
    public int Id { get; set; }
    public string Code { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public int RequestTypeId { get; set; }
    public bool IsMandatory { get; set; }
    public int MaxSizeKb { get; set; }
    public string AllowedExtensions { get; set; } = string.Empty;
}

/// <summary>
/// What the document endpoint needs to decide whether the caller may have it.
/// </summary>
internal sealed class DocumentAccessRow
{
    public long DocumentId { get; set; }
    public long RequestId { get; set; }
    public string FilePath { get; set; } = string.Empty;
    public string FileName { get; set; } = string.Empty;
    public string MimeType { get; set; } = string.Empty;

    /// <summary>Who submitted the request this document belongs to.</summary>
    public long RequestorUserId { get; set; }

    public Guid? OrganizationUid { get; set; }
}

/// <summary>
/// What a draft save returns: the envelope plus the entity uid the client has
/// to send back next time.
/// </summary>
internal sealed class SaveDraftProcResult : ProcResult
{
    public Guid? EntityUid { get; set; }
}

/// <summary>
/// A completed approval that was SUPPOSED to create something in another
/// database — read from jp_mdm, then offered to jp_app to check.
/// </summary>
/// <remarks>
/// ⚠️ Only request types that provision something appear here. The procedure
/// filters out teacher verification, which by design creates nothing (2.9);
/// including it would mark every approved teacher request as an orphan for
/// ever, and a report that is permanently wrong is a report nobody opens.
/// </remarks>
internal sealed class CompletedApprovalRow
{
    public long RequestId { get; set; }
    public Guid RequestUid { get; set; }
    public string RequestNo { get; set; } = string.Empty;
    public int RequestTypeId { get; set; }
    public string RequestTypeName { get; set; } = string.Empty;
    public Guid EntityUid { get; set; }
    public Guid? OrganizationUid { get; set; }
    public long RequestorUserId { get; set; }
    public DateTime CompletedOn { get; set; }
    public string? EntityName { get; set; }
}

/// <summary>
/// One row of the reconciliation answer, as jp_app returns it.
/// </summary>
/// <remarks>
/// 🔴 Deliberately narrow. jp_app knows nothing about an approval beyond the
/// four columns it was handed, so this carries the RequestUid back and nothing
/// more — the caller pairs it with the <see cref="CompletedApprovalRow"/> it
/// sent to recover the request id, type and name.
///
/// Widening this to look like the jp_mdm row would be a lie about where the
/// data came from, and the first person to add a column here would go looking
/// for it in a database that does not have it.
/// </remarks>
internal sealed class OrphanedApprovalRow
{
    public Guid RequestUid { get; set; }
    public string RequestNo { get; set; } = string.Empty;
    public Guid? OrganizationUid { get; set; }
    public DateTime CompletedOn { get; set; }
    public int HoursSinceCompleted { get; set; }
}
