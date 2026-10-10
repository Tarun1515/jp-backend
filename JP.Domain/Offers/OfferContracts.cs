namespace JP.Domain.Offers;

/*==============================================================================
  Offer Lite — the wire shapes. Phase 6A.

  🔴 NO SchoolId ANYWHERE, on either side. The school is resolved from the
  token's OrganizationUid (2.39); a teacher identifies a school by SchoolUid.
  There is no TeacherId on the wire either.

  🔴 TWO SHAPES FOR ONE ROW, AND THE DIFFERENCE IS DELIBERATE.
  OfferDto is what the SCHOOL sees; MyOfferDto is what the TEACHER sees. They
  are not one class with fields blanked out, because that is how a field
  eventually arrives populated by accident — 024 and 017 draw the same line for
  applications. The school's withdrawal reason and the name of whoever sent the
  offer exist only on the first; the teacher's status wording exists only on the
  second.
==============================================================================*/

/// <summary>One offer, as the school that made it sees it.</summary>
public sealed class OfferDto
{
    public long OfferId { get; set; }
    public Guid OfferUid { get; set; }
    public long ApplicationId { get; set; }

    public long BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;

    public int DesignationId { get; set; }
    public decimal? OfferedSalary { get; set; }
    public DateTime? JoiningDate { get; set; }
    public TimeSpan? ReportingTime { get; set; }
    public string? TermsAndConditions { get; set; }

    public int OfferStatusId { get; set; }

    /// <summary>The SCHOOL's wording — "Declined", not "You declined".</summary>
    public string OfferStatusName { get; set; } = string.Empty;

    /// <summary>
    /// 🔴 True only for Sent. It is what the filtered unique index means, and
    /// what decides whether this offer can still be withdrawn or answered.
    /// </summary>
    public bool IsLive { get; set; }

    public DateTime SentOn { get; set; }
    public long? SentByUserId { get; set; }

    /// <summary>
    /// Resolved through this school's own colleague list, and NULL for anybody
    /// who is not on it — the same rule 017 applies to a history actor, and for
    /// the same reason: an email fallback would leak an address.
    /// </summary>
    public string? SentByName { get; set; }

    public DateTime? RespondedOn { get; set; }

    /// <summary>The teacher's own words when they answered. Shown to the school.</summary>
    public string? TeacherRemarks { get; set; }

    /// <summary>🔴 The school's internal note. Never sent to the teacher (018).</summary>
    public string? WithdrawalReason { get; set; }

    public int RowVersion { get; set; }

    /// <summary>🔴 Arrives through an alias in the procedure (2.61).</summary>
    public bool IsActive { get; set; }
}

/// <summary>One offer, as the teacher who received it sees it.</summary>
public sealed class MyOfferDto
{
    public long OfferId { get; set; }
    public Guid OfferUid { get; set; }
    public long ApplicationId { get; set; }

    public long JobId { get; set; }
    public string JobTitle { get; set; } = string.Empty;

    public int DesignationId { get; set; }
    public decimal? OfferedSalary { get; set; }
    public DateTime? JoiningDate { get; set; }
    public TimeSpan? ReportingTime { get; set; }
    public string? TermsAndConditions { get; set; }

    public int OfferStatusId { get; set; }

    /// <summary>
    /// 🔴 The TEACHER's wording, from <c>m_app_offer_status.TeacherFacingName</c>
    /// — "Offer received", "You declined". The school's vocabulary is not sent
    /// to this app at all, and neither is its withdrawal reason.
    /// </summary>
    public string OfferStatusName { get; set; } = string.Empty;

    public bool IsLive { get; set; }

    public DateTime SentOn { get; set; }
    public DateTime? RespondedOn { get; set; }
    public string? TeacherRemarks { get; set; }

    public Guid SchoolUid { get; set; }
    public string SchoolName { get; set; } = string.Empty;
    public string? SchoolLogoPath { get; set; }
    public string BranchName { get; set; } = string.Empty;

    /// <summary>🔴 Arrives through an alias in the procedure (2.61).</summary>
    public bool IsActive { get; set; }
}

/// <summary>What a school sends.</summary>
public sealed class SendOfferRequest
{
    /// <summary>
    /// From <c>m_mdm_designation</c>, not free text — a school cannot offer a
    /// post that does not exist in the master (2.7), and the offer stays
    /// comparable against the job it came from.
    /// </summary>
    public int DesignationId { get; set; }

    public decimal? OfferedSalary { get; set; }
    public DateTime? JoiningDate { get; set; }

    /// <summary>
    /// ⚠️ A clock time, not an instant. "Report at 8:00" does not move with a
    /// timezone and is stored as <c>time(0)</c> (2.28).
    /// </summary>
    public TimeSpan? ReportingTime { get; set; }

    public string? TermsAndConditions { get; set; }
}

/// <summary>What a teacher answers with.</summary>
public sealed class RespondToOfferRequest
{
    public bool Accept { get; set; }

    /// <summary>Optional, and shown to the school.</summary>
    public string? TeacherRemarks { get; set; }
}

/// <summary>What a school gives when it pulls its own offer.</summary>
public sealed class WithdrawOfferRequest
{
    /// <summary>Optional, and kept private to the school (018).</summary>
    public string? Reason { get; set; }
}

/// <summary>What a school gives when confirming somebody actually started.</summary>
public sealed class ConfirmHireRequest
{
    public string? Remarks { get; set; }
}

/// <summary>The result of sending an offer.</summary>
public sealed class SendOfferResultDto
{
    public long OfferId { get; set; }

    /// <summary>
    /// ⚠️ <c>ALREADY_OFFERED</c> arrives on a SUCCESS, and only ever from a
    /// genuine race — an ordinary second click is refused by the transition map
    /// long before the unique index is reached.
    /// </summary>
    public string? Code { get; set; }

    /// <summary>False when the offer already existed.</summary>
    public bool Created { get; set; }
}
