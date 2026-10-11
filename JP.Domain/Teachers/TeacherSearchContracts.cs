using JP.Domain.Common;

namespace JP.Domain.Teachers;

/*==============================================================================
  Teacher search — the school finds teachers. Phase 6B.

  🔒 THE RESULT SHAPE IS THE SECURITY SURFACE, AND IT IS GUARDED AT STARTUP.

  TeacherSearchResultDto is checked by ContactLeakGuard alongside
  TeacherBrowseDto: adding an email, a mobile, a resume path, a date of birth or
  a UserUid to it takes the API down on the developer's own machine with a
  message naming the property and the decision it breaks (2.56, LOCKED).

  ⚠️ AND THE REASON IS STRONGER HERE THAN ON THE BROWSE SHAPE. Every row on the
  applicant list has consented; almost nobody in a search result has. A contact
  column here would leak the entire teacher base to any school that typed a
  filter — not a shape violation, the actual rule.
==============================================================================*/

/// <summary>What a school filters on.</summary>
public sealed class TeacherSearchFilter : PagedRequest
{
    public int? SubjectId { get; set; }
    public int? DesignationId { get; set; }
    public int? QualificationId { get; set; }
    public int? ClassLevelId { get; set; }
    public int? CityId { get; set; }
    public int? StateId { get; set; }

    /// <summary>
    /// From <c>m_mdm_experience_range</c>. ⚠️ A RANGE ID, not a pair of
    /// numbers: the month boundaries live in the master so the client can
    /// change what "3 - 5 years" means without a deployment (2.7). A client
    /// sending min/max months itself would be the second definition.
    /// </summary>
    public int? ExperienceRangeId { get; set; }

    /// <summary>
    /// ⚠️ A FILTER THE SCHOOL CHOOSES, never a default. Verification is a
    /// signal, not a gate (2.9) — an unverified teacher appears unless a school
    /// explicitly asks otherwise.
    /// </summary>
    public bool VerifiedOnly { get; set; }
}

/// <summary>
/// One teacher in a search result.
/// </summary>
/// <remarks>
/// 🔒 NO CONTACT PROPERTIES, AND NONE MAY BE ADDED. Enforced by
/// <c>ContactLeakGuard</c> at startup, by the procedure having no such columns
/// to return, and by a raw-bytes assertion in
/// <c>jp-docs/scripts/verify/teacher-search.mjs</c> — the type, the SQL and the
/// wire, because a mapper can add a field the type never declared.
/// </remarks>
public sealed class TeacherSearchResultDto
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

    /// <summary>
    /// ⚠️ Returned deliberately. The teacher entered it AS A FILTER — hiding it
    /// wastes both sides' time on offers that were never going to work. It is a
    /// stated preference, not a private fact (010's header).
    /// </summary>
    public decimal? ExpectedSalaryMin { get; set; }
    public decimal? ExpectedSalaryMax { get; set; }

    public int? CurrentCityId { get; set; }
    public int? CurrentStateId { get; set; }

    /// <summary>🔴 A signal to the school, never a gate on the teacher (2.9).</summary>
    public bool IsVerified { get; set; }

    public byte ProfileCompletionPercent { get; set; }

    /// <summary>
    /// 🔴 Whether THIS school already has an invitation waiting with this
    /// teacher — a fact about the school's own rows, which is why it is allowed
    /// on this shape. It says nothing about the teacher the school does not
    /// already know it did, and it stops the screen offering a button the
    /// unique index would refuse.
    /// </summary>
    public bool HasOpenInvite { get; set; }

    /// <summary>Whether this teacher has already applied to this school.</summary>
    public bool HasApplied { get; set; }

    /// <summary>🔴 Arrives through an alias in the procedure (2.61).</summary>
    public bool IsActive { get; set; }
}
