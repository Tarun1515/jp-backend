namespace JP.Domain.Invites;

/*==============================================================================
  Teacher invites — the wire shapes. Phase 6B.

  🔒 ACCEPTING ONE OF THESE IS CONSENT PATH 2 (2.56, LOCKED). Sending one is
  not, viewing one is not, ignoring one is not, and paying for one is not.

  🔴 TWO SHAPES FOR ONE ROW, as with offers and applications before them.
  SchoolInviteDto is the school's outbox; MyInviteDto is the teacher's inbox.
  They are not one class with fields blanked out — that is how a field
  eventually arrives populated by accident.

  ⚠️ NEITHER CARRIES CONTACT. The school's shape is a LIST, and the shape rule
  3D set and 5A restated holds even for an ACCEPTED invite: a browse surface
  ends up in a screenshot or an export, and contact is a deliberate act on one
  person. The school opens the teacher's contact endpoint, which asks
  fn_TeacherContactUnlocked. SchoolInviteDto is checked by ContactLeakGuard at
  startup for exactly this reason.
==============================================================================*/

/// <summary>What a school sends.</summary>
public sealed class SendInviteRequest
{
    /// <summary>The teacher's public identifier. There is no TeacherId on the wire (2.39).</summary>
    public Guid TeacherUid { get; set; }

    /// <summary>
    /// Which campus is inviting. ⚠️ Legitimate data AND an authorization input —
    /// a campus the caller does not hold answers NOT_FOUND (2.39).
    /// </summary>
    public long BranchId { get; set; }

    /// <summary>
    /// Optional, and its absence is the point of the feature: a school may
    /// invite a teacher WITHOUT having posted a job. "We would like to talk to
    /// you" is a real thing to say.
    /// </summary>
    public long? JobId { get; set; }

    public string? Message { get; set; }
}

/// <summary>The result of sending an invitation.</summary>
public sealed class SendInviteResultDto
{
    public long InviteId { get; set; }

    /// <summary>
    /// ⚠️ <c>ALREADY_INVITED</c> arrives on a SUCCESS. Unlike an offer's
    /// ALREADY_OFFERED — which only a genuine race can produce — this one is
    /// reachable by an ordinary second click, because nothing in the invite
    /// flow refuses before the unique index does. Either way nothing was
    /// charged: the insert runs before the meter (020).
    /// </summary>
    public string? Code { get; set; }

    /// <summary>False when an open invitation already existed.</summary>
    public bool Created { get; set; }

    /// <summary>
    /// 🔴 True only when the plan was actually charged. FREE and
    /// ALREADY_CONSUMED both leave this false — the first because the mode is
    /// the grant, the second because it was counted once already (2.5).
    /// </summary>
    public bool Consumed { get; set; }

    /// <summary>1 = plan quota, 2 = credits. Null when nothing was charged.</summary>
    public int? Source { get; set; }
}

/// <summary>What a teacher answers with.</summary>
public sealed class RespondToInviteRequest
{
    /// <summary>
    /// 🔒 True is CONSENT PATH 2 — the school's access to this teacher's
    /// contact details begins here and nowhere else. False records an explicit
    /// pass, which unlocks nothing, forever.
    /// </summary>
    public bool Accept { get; set; }

    /// <summary>Optional, and shown to the school.</summary>
    public string? TeacherRemarks { get; set; }
}

/// <summary>One invitation, as the school that sent it sees it.</summary>
/// <remarks>
/// 🔒 NO CONTACT PROPERTIES — checked by <c>ContactLeakGuard</c> at startup.
/// See this file's header for why that holds even after the teacher accepts.
/// </remarks>
public sealed class SchoolInviteDto
{
    public long InviteId { get; set; }
    public Guid InviteUid { get; set; }

    public long BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;

    public long? JobId { get; set; }
    public string? JobTitle { get; set; }

    public Guid TeacherUid { get; set; }
    public string TeacherName { get; set; } = string.Empty;
    public string? PhotoPath { get; set; }
    public int? TeacherDesignationId { get; set; }
    public int? TeacherQualificationId { get; set; }
    public int? TotalExperienceMonths { get; set; }
    public int? CurrentCityId { get; set; }
    public int? CurrentStateId { get; set; }
    public bool IsVerified { get; set; }
    public byte ProfileCompletionPercent { get; set; }

    public string? Message { get; set; }

    public int InviteStatusId { get; set; }

    /// <summary>The SCHOOL's wording — "Ignored", not "You passed on this".</summary>
    public string InviteStatusName { get; set; } = string.Empty;

    /// <summary>True while the invitation is still outstanding (Sent or Viewed).</summary>
    public bool IsOpen { get; set; }

    /// <summary>
    /// 🔒 True on exactly one status — ACCEPTED. It is what
    /// <c>fn_TeacherContactUnlocked</c> matches, surfaced so a screen can say
    /// "you can contact them" without re-deciding the rule itself.
    /// </summary>
    public bool IsConsent { get; set; }

    public DateTime SentOn { get; set; }

    /// <summary>When the teacher opened it. ⚠️ Null is "not yet", not "no".</summary>
    public DateTime? ViewedOn { get; set; }

    public DateTime? RespondedOn { get; set; }
    public string? TeacherRemarks { get; set; }

    public int RowVersion { get; set; }

    /// <summary>🔴 Arrives through an alias in the procedure (2.61).</summary>
    public bool IsActive { get; set; }
}

/// <summary>One invitation, as the teacher who received it sees it.</summary>
public sealed class MyInviteDto
{
    public long InviteId { get; set; }
    public Guid InviteUid { get; set; }

    public long? JobId { get; set; }
    public string? JobTitle { get; set; }
    public int? SubjectId { get; set; }
    public int? DesignationId { get; set; }
    public decimal? SalaryMin { get; set; }
    public decimal? SalaryMax { get; set; }
    public bool? IsSalaryNegotiable { get; set; }
    public DateTime? LastDateToApply { get; set; }

    /// <summary>
    /// 🔴 The school IS named, before any consent exists — the one place this
    /// product deliberately shows a school to a teacher that way, because
    /// "somebody wants to talk to you" is useless without knowing who.
    /// </summary>
    public Guid SchoolUid { get; set; }
    public string SchoolName { get; set; } = string.Empty;
    public string? SchoolLogoPath { get; set; }
    public bool IsSchoolVerified { get; set; }

    public string BranchName { get; set; } = string.Empty;
    public int? BranchCityId { get; set; }
    public int? BranchStateId { get; set; }

    public string? Message { get; set; }

    public int InviteStatusId { get; set; }

    /// <summary>
    /// 🔴 The TEACHER's wording, from
    /// <c>m_app_invite_status.TeacherFacingName</c> — "Invitation received",
    /// "You passed on this". The school's vocabulary is not sent to this app.
    /// </summary>
    public string InviteStatusName { get; set; } = string.Empty;

    public bool IsOpen { get; set; }

    public DateTime SentOn { get; set; }
    public DateTime? ViewedOn { get; set; }
    public DateTime? RespondedOn { get; set; }
    public string? TeacherRemarks { get; set; }

    public int RowVersion { get; set; }

    /// <summary>🔴 Arrives through an alias in the procedure (2.61).</summary>
    public bool IsActive { get; set; }
}
