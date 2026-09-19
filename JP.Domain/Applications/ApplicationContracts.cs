using JP.Domain.Common;

namespace JP.Domain.Applications;

/*==============================================================================
  🔴 SchoolId NEVER APPEARS ON ANY DTO IN THIS FILE (2.39).

  It lives in jp_app and never leaves the server. The API resolves it from the
  token's OrganizationUid on every request. Where a school has to be IDENTIFIED
  to a teacher — "who is this job with" — the DTO carries SchoolUid, which is
  the public identifier, exactly as the school's own public profile does.

  🔴 TeacherId NEVER APPEARS EITHER, and for the same reason. A teacher is
  identified by TeacherUid on the wire, and the id behind it is resolved from
  the token on the teacher's own side and from the application row on the
  school's.

  ---------------------------------------------------------------------------
  🔴 TWO LIST SHAPES, TWO AUDIENCES, AND NO PATH BETWEEN THEM
  ---------------------------------------------------------------------------
  ApplicantListItemDto (the school's) has NO ContactEmail, NO ContactMobile and
  NO resume path — not null, ABSENT. Contact lives on
  ApplicantDetailDto alone, and arrives there only through
  fn_TeacherContactUnlocked.

  MyApplicationListItemDto (the teacher's) has NO RejectionReason. The school's
  private note on why somebody was turned down is not a field a teacher-facing
  type declares.

  Both absences are the 3D/3E precedent: a column present-but-empty is one
  somebody populates later without thinking about the rule forty lines up.
==============================================================================*/

/// <summary>The six reachable application states. 7–10 are Phase 6.</summary>
/// <remarks>
/// 🔴 The ids are a contract (2.47) and the ten rows are all seeded, but only
/// these six are reachable — <c>fn_ApplicationTransitionAllowed</c> refuses the
/// offer chain outright until <c>t_app_offers</c> exists.
/// </remarks>
public static class ApplicationStatus
{
    public const int Applied = 1;
    public const int Viewed = 2;
    public const int Shortlisted = 3;
    public const int Interview = 4;
    public const int Selected = 5;
    public const int Rejected = 6;

    /// <summary>Lowest id in the Phase 6 offer chain. 7–10 inclusive.</summary>
    public const int FirstOfferStage = 7;
}

/*==============================================================================
  SCHOOL SIDE
==============================================================================*/

/// <summary>
/// One row of the school's applicant list.
/// </summary>
/// <remarks>
/// 🔴 NO CONTACT PROPERTIES, AND NONE MAY BE ADDED. A list is a browse surface
/// that ends up in a log, an export or a screenshot; contact is a deliberate
/// act on one person and lives on <see cref="ApplicantDetailDto"/>. If you are
/// here because you want an email address on the list, the answer is the detail
/// endpoint, not a wider list.
/// </remarks>
public sealed class ApplicantListItemDto
{
    public long ApplicationId { get; set; }
    public Guid ApplicationUid { get; set; }

    public long JobId { get; set; }
    public string JobTitle { get; set; } = string.Empty;
    public int SubjectId { get; set; }
    public int DesignationId { get; set; }

    /// <summary>
    /// 🔴 Data AND an authorization input, like a job's. Every procedure joins
    /// through <c>fn_VisibleBranches</c> before using it.
    /// </summary>
    public long BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;

    /// <summary>The teacher's PUBLIC identifier. There is no TeacherId here.</summary>
    public Guid TeacherUid { get; set; }
    public string TeacherName { get; set; } = string.Empty;
    public string? PhotoPath { get; set; }
    public int? TeacherDesignationId { get; set; }
    public int? TeacherQualificationId { get; set; }
    public int? TotalExperienceMonths { get; set; }
    public int? CurrentCityId { get; set; }
    public int? CurrentStateId { get; set; }
    public byte ProfileCompletionPercent { get; set; }

    /// <summary>🔴 A badge, never a gate (2.9). Unverified teachers still list.</summary>
    public bool IsVerified { get; set; }

    public int ApplicationStatusId { get; set; }
    public string StatusName { get; set; } = string.Empty;
    public DateTime AppliedOn { get; set; }
    public DateTime? ViewedOn { get; set; }

    /// <summary>
    /// The FACT of a resume, never its path.
    /// </summary>
    /// <remarks>
    /// The file is served by <c>GET /api/applicants/{id}/resume</c>, gated on
    /// RESUME.DOWNLOAD. A path on the list would route around that permission.
    /// </remarks>
    public bool HasResume { get; set; }

    public bool HasCoverNote { get; set; }

    public int RowVersion { get; set; }

    /// <summary>🔴 Arrives through an alias in the procedure (2.61).</summary>
    public bool IsActive { get; set; }
}

/// <summary>
/// One applicant in full — including the contact block.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 <see cref="ContactEmail"/>, <see cref="ContactMobile"/> and
/// <see cref="ResumePathSnapshot"/> are populated ONLY when
/// <c>fn_TeacherContactUnlocked</c> says so, and
/// <see cref="IsContactUnlocked"/> reports what it said. Nothing in C# decides
/// this — the procedure calls the function and the API maps what came back.
/// </para>
/// <para>
/// ⚠️ It will always be unlocked here, because an application IS the consent.
/// The question is still asked, so that the shape is right for the next reader
/// that does not have an application in hand.
/// </para>
/// </remarks>
public sealed class ApplicantDetailDto
{
    public long ApplicationId { get; set; }
    public Guid ApplicationUid { get; set; }

    public long JobId { get; set; }
    public string JobTitle { get; set; } = string.Empty;
    public int SubjectId { get; set; }
    public int DesignationId { get; set; }
    public int EmploymentTypeId { get; set; }
    public int NoOfVacancies { get; set; }
    public DateTime? LastDateToApply { get; set; }

    /// <summary>🔴 The job's EFFECTIVE status — expiry is derived, never stored.</summary>
    public int JobStatusId { get; set; }

    public long BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;

    public Guid TeacherUid { get; set; }
    public string TeacherName { get; set; } = string.Empty;
    public string? PhotoPath { get; set; }
    public int? GenderId { get; set; }
    public int? TeacherQualificationId { get; set; }
    public string? HighestQualificationText { get; set; }
    public int? TeacherDesignationId { get; set; }
    public int? TotalExperienceMonths { get; set; }
    public string? CurrentSchool { get; set; }
    public string? LastSchool { get; set; }
    public decimal? ExpectedSalaryMin { get; set; }
    public decimal? ExpectedSalaryMax { get; set; }
    public int? CurrentCityId { get; set; }
    public int? CurrentStateId { get; set; }
    public string? AboutMe { get; set; }
    public bool IsVerified { get; set; }
    public byte ProfileCompletionPercent { get; set; }

    public int ApplicationStatusId { get; set; }
    public string StatusName { get; set; } = string.Empty;
    public DateTime AppliedOn { get; set; }
    public DateTime? ViewedOn { get; set; }
    public string? CoverNote { get; set; }

    /// <summary>
    /// The school's own note on a rejection.
    /// </summary>
    /// <remarks>
    /// ⚠️ SCHOOL-FACING ONLY. No teacher-facing type in this file declares it,
    /// and no teacher-facing procedure selects it. The teacher is told "Not
    /// selected" and nothing more.
    /// </remarks>
    public string? RejectionReason { get; set; }

    public int RowVersion { get; set; }

    /// <summary>🔴 Aliased in the procedure (2.61).</summary>
    public bool IsActive { get; set; }

    /// <summary>What <c>fn_TeacherContactUnlocked</c> answered. Nothing else decides it.</summary>
    public bool IsContactUnlocked { get; set; }

    public string? ContactEmail { get; set; }
    public string? ContactMobile { get; set; }

    /// <summary>
    /// 🔴 THE RESUME AS IT WAS WHEN THEY APPLIED, never the teacher's current
    /// one.
    /// </summary>
    /// <remarks>
    /// The teacher may replace the file tomorrow. A school that shortlisted
    /// somebody must be able to re-read what it shortlisted, and the procedure
    /// reads <c>t_app_applications.ResumePathSnapshot</c> with no join to the
    /// live column at all.
    /// </remarks>
    public string? ResumePathSnapshot { get; set; }

    public bool HasResume { get; set; }

    public IReadOnlyList<ApplicationHistoryDto> History { get; set; } = [];

    /// <summary>
    /// 🔴 THE STATUSES THIS APPLICATION MAY LEGALLY MOVE TO, FROM THE SERVER.
    /// </summary>
    /// <remarks>
    /// <para>
    /// Computed by <c>fn_ApplicationTransitionAllowed</c> itself — the same
    /// function that refuses an illegal move — so the buttons a screen draws
    /// and the moves the database permits cannot disagree. A TypeScript copy
    /// of the map would be a second source of truth for a rule that is already
    /// enforced, and it would drift silently: the screen would offer an action
    /// the server then refused.
    /// </para>
    /// <para>
    /// ⚠️ EMPTY IS AN ANSWER. A Rejected application is terminal, so this comes
    /// back empty and the screen draws no status actions at all — a move that
    /// will never be allowed is ABSENT, not disabled (the 3F/3G rule). A client
    /// must never read empty as "unknown, offer everything".
    /// </para>
    /// <para>
    /// ⚠️ Presentation input only, exactly like <c>StructuralFieldsLocked</c>
    /// on a job. The server refuses an illegal transition with
    /// INVALID_TRANSITION whether or not a button was drawn.
    /// </para>
    /// </remarks>
    public IReadOnlyList<AllowedTransitionDto> AllowedTransitions { get; set; } = [];
}

/// <summary>A status this application may be moved to next.</summary>
/// <remarks>
/// <c>Code</c> is the stable contract a client branches on (2.47 / 2.21);
/// <c>Name</c> is the school's wording and the client may not assume it.
/// </remarks>
public sealed class AllowedTransitionDto
{
    public int ApplicationStatusId { get; set; }
    public string Code { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public int DisplayOrder { get; set; }
}

/// <summary>One step of an application's journey, as the school sees it.</summary>
public sealed class ApplicationHistoryDto
{
    public long HistoryId { get; set; }
    public int? FromStatusId { get; set; }
    public string? FromStatusName { get; set; }
    public int ToStatusId { get; set; }
    public string ToStatusName { get; set; } = string.Empty;
    public DateTime ChangedOn { get; set; }

    /// <summary>The jp_sso user who moved it. Survives them leaving the team (3G).</summary>
    public long? ChangedByUserId { get; set; }

    /// <summary>
    /// The colleague's name, resolved through this school's own team list.
    /// </summary>
    /// <remarks>
    /// 🔴 NULL WHEN THE ACTOR IS THE TEACHER, and deliberately without a
    /// fallback. The first history row on every application is written by the
    /// applicant, so falling back to the actor's email address would hand the
    /// school a teacher's sign-in address on every applicant's detail screen,
    /// gated by nothing (2.56).
    /// </remarks>
    public string? ChangedByName { get; set; }

    /// <summary>⚠️ School-facing only. Never sent to a teacher.</summary>
    public string? Remarks { get; set; }
}

/// <summary>A school's move on an application.</summary>
/// <remarks>
/// 🔴 No SchoolId, and no TeacherId. The application is addressed by its own id
/// in the route and validated against the caller's branch scope inside the
/// procedure.
/// </remarks>
public sealed class SetApplicationStatusRequest
{
    public int ToStatusId { get; set; }

    /// <summary>
    /// The school's own note. Stored on a rejection, and never shown to the
    /// teacher in this phase.
    /// </summary>
    public string? Remarks { get; set; }
}

/// <summary>The dashboard's applicants area, and the list header's counts.</summary>
/// <remarks>
/// 🔴 3I shipped this as an honest not-yet empty state because there was no
/// table to count (2.62). There is one now, so a school with no applicants
/// shows a real zero — which is a measurement rather than a placeholder.
/// </remarks>
public sealed class SchoolApplicantStatsDto
{
    public int TotalApplications { get; set; }
    public int NewCount { get; set; }
    public int ViewedCount { get; set; }
    public int ShortlistedCount { get; set; }
    public int InterviewCount { get; set; }
    public int SelectedCount { get; set; }
    public int RejectedCount { get; set; }

    /// <summary>How many distinct postings have somebody on them.</summary>
    public int JobsWithApplicants { get; set; }

    public IReadOnlyList<RecentApplicantDto> Recent { get; set; } = [];
}

/// <summary>A dashboard row. 🔴 No contact fields — a tile is a browse surface.</summary>
public sealed class RecentApplicantDto
{
    public long ApplicationId { get; set; }
    public Guid ApplicationUid { get; set; }
    public long JobId { get; set; }
    public string JobTitle { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public Guid TeacherUid { get; set; }
    public string TeacherName { get; set; } = string.Empty;
    public string? PhotoPath { get; set; }
    public bool IsVerified { get; set; }
    public int ApplicationStatusId { get; set; }
    public string StatusName { get; set; } = string.Empty;
    public DateTime AppliedOn { get; set; }
    public DateTime? ViewedOn { get; set; }
}

/*==============================================================================
  TEACHER SIDE
==============================================================================*/

/// <summary>
/// The filters the teacher's job browse accepts.
/// </summary>
/// <remarks>
/// ⚠️ Inherits the self-clamping paging from <see cref="PagedRequest"/>, so a
/// caller asking for 100000 rows is clamped rather than refused — and the
/// procedure clamps again, because a floor that only exists in C# is a floor a
/// direct EXEC walks straight past.
/// </remarks>
public sealed class JobBrowseFilter : PagedRequest
{
    public int? SubjectId { get; set; }
    public int? DesignationId { get; set; }
    public int? EmploymentTypeId { get; set; }
    public int? CityId { get; set; }
    public int? StateId { get; set; }
    public decimal? MinSalary { get; set; }
}

/// <summary>A job as it appears in the teacher's browse.</summary>
/// <remarks>
/// 🔴 Only ACTIVE jobs reach this type — the procedure filters on
/// <c>fn_EffectiveJobStatusId</c>, so an expired posting does not list at all.
/// There is no status property here because there is only one status it could
/// ever hold.
/// </remarks>
public sealed class JobBrowseItemDto
{
    public long JobId { get; set; }
    public Guid JobUid { get; set; }
    public string JobTitle { get; set; } = string.Empty;

    public int SubjectId { get; set; }
    public int DesignationId { get; set; }
    public int? QualificationId { get; set; }
    public int EmploymentTypeId { get; set; }
    public int NoOfVacancies { get; set; }
    public int? MinExperienceMonths { get; set; }
    public int? MaxExperienceMonths { get; set; }

    public decimal? SalaryMin { get; set; }
    public decimal? SalaryMax { get; set; }
    public bool IsSalaryNegotiable { get; set; }

    public int? CityId { get; set; }
    public int? StateId { get; set; }

    public DateTime? LastDateToApply { get; set; }
    public DateTime? ExpectedJoiningDate { get; set; }
    public DateTime? PublishedOn { get; set; }

    /// <summary>🔴 The school's PUBLIC identifier. SchoolId never travels (2.39).</summary>
    public Guid SchoolUid { get; set; }
    public string SchoolName { get; set; } = string.Empty;
    public string? SchoolLogoPath { get; set; }
    public bool IsSchoolVerified { get; set; }
    public string BranchName { get; set; } = string.Empty;

    /// <summary>
    /// 🔴 DERIVED — a COUNT of live application rows, computed on every read.
    /// </summary>
    /// <remarks>
    /// <c>t_app_jobs.ApplicationCount</c> exists, stays at zero and is never
    /// written (024). A maintained counter is a second source of truth that
    /// drifts silently: the number stops matching the list under it and nothing
    /// errors.
    /// </remarks>
    public int ApplicationCount { get; set; }

    public bool HasApplied { get; set; }
    public bool IsSaved { get; set; }

    /// <summary>🔴 Aliased in the procedure (2.61).</summary>
    public bool IsActive { get; set; }
}

/// <summary>One job, as an applicant reads it before deciding.</summary>
public sealed class JobForTeacherDto
{
    public long JobId { get; set; }
    public Guid JobUid { get; set; }
    public string JobTitle { get; set; } = string.Empty;

    public int SubjectId { get; set; }
    public int DesignationId { get; set; }
    public int? QualificationId { get; set; }
    public int EmploymentTypeId { get; set; }
    public int NoOfVacancies { get; set; }
    public int? MinExperienceMonths { get; set; }
    public int? MaxExperienceMonths { get; set; }

    public decimal? SalaryMin { get; set; }
    public decimal? SalaryMax { get; set; }
    public bool IsSalaryNegotiable { get; set; }

    public int? CityId { get; set; }
    public int? StateId { get; set; }
    public string? WorkingDays { get; set; }
    public TimeSpan? TimingFrom { get; set; }
    public TimeSpan? TimingTo { get; set; }

    public DateTime? LastDateToApply { get; set; }
    public DateTime? ExpectedJoiningDate { get; set; }
    public string? JobDescription { get; set; }
    public DateTime? PublishedOn { get; set; }

    public Guid SchoolUid { get; set; }
    public string SchoolName { get; set; } = string.Empty;
    public string? SchoolLogoPath { get; set; }
    public string? AboutSchool { get; set; }
    public bool IsSchoolVerified { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public int? BranchCityId { get; set; }
    public int? BranchStateId { get; set; }

    /// <summary>🔴 DERIVED. See <see cref="JobBrowseItemDto.ApplicationCount"/>.</summary>
    public int ApplicationCount { get; set; }

    public bool HasApplied { get; set; }
    public bool IsSaved { get; set; }
    public bool IsActive { get; set; }

    public IReadOnlyList<int> SubjectIds { get; set; } = [];
    public IReadOnlyList<int> ClassLevelIds { get; set; } = [];
}

/// <summary>A teacher applies.</summary>
/// <remarks>
/// 🔴 NO TeacherId. The teacher is resolved from the token, so applying on
/// somebody else's behalf cannot be expressed — the 3D property, carried
/// forward.
/// </remarks>
public sealed class ApplyToJobRequest
{
    public long JobId { get; set; }

    public string? CoverNote { get; set; }
}

/// <summary>What an apply did.</summary>
public sealed class ApplyResultDto
{
    public long ApplicationId { get; set; }

    /// <summary>
    /// ⚠️ Can be set on a SUCCESS — <c>ALREADY_APPLIED</c> means the
    /// application exists and nothing was created. Branch on the HTTP status
    /// first, then the code (2.12).
    /// </summary>
    public string? Code { get; set; }

    /// <summary>True only when this call is the one that created the row.</summary>
    public bool Created { get; set; }
}

/// <summary>
/// One row of the teacher's own applications.
/// </summary>
/// <remarks>
/// 🔴 NO RejectionReason PROPERTY, AND NONE MAY BE ADDED.
/// <see cref="StatusName"/> is <c>TeacherFacingName</c> from the master — "Not
/// selected", never "Rejected" — and the school's own note on why does not
/// appear in any teacher-facing procedure or type (023).
/// </remarks>
public sealed class MyApplicationListItemDto
{
    public long ApplicationId { get; set; }
    public Guid ApplicationUid { get; set; }

    public long JobId { get; set; }
    public Guid JobUid { get; set; }
    public string JobTitle { get; set; } = string.Empty;
    public int SubjectId { get; set; }
    public int DesignationId { get; set; }
    public int EmploymentTypeId { get; set; }
    public decimal? SalaryMin { get; set; }
    public decimal? SalaryMax { get; set; }
    public bool IsSalaryNegotiable { get; set; }
    public DateTime? LastDateToApply { get; set; }

    /// <summary>🔴 The job's EFFECTIVE status — a closed posting says so.</summary>
    public int JobStatusId { get; set; }

    public Guid SchoolUid { get; set; }
    public string SchoolName { get; set; } = string.Empty;
    public string? SchoolLogoPath { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public int? BranchCityId { get; set; }
    public int? BranchStateId { get; set; }

    public int ApplicationStatusId { get; set; }

    /// <summary>🔴 <c>TeacherFacingName</c>, never the school's word for it.</summary>
    public string StatusName { get; set; } = string.Empty;

    public DateTime AppliedOn { get; set; }
    public DateTime? ViewedOn { get; set; }
    public string? CoverNote { get; set; }
    public bool HasResume { get; set; }

    /// <summary>🔴 Aliased in the procedure (2.61).</summary>
    public bool IsActive { get; set; }
}

/// <summary>One of the teacher's own applications, in full.</summary>
public sealed class MyApplicationDetailDto
{
    public long ApplicationId { get; set; }
    public Guid ApplicationUid { get; set; }

    public long JobId { get; set; }
    public Guid JobUid { get; set; }
    public string JobTitle { get; set; } = string.Empty;
    public int SubjectId { get; set; }
    public int DesignationId { get; set; }
    public int? QualificationId { get; set; }
    public int EmploymentTypeId { get; set; }
    public int NoOfVacancies { get; set; }
    public int? MinExperienceMonths { get; set; }
    public int? MaxExperienceMonths { get; set; }
    public decimal? SalaryMin { get; set; }
    public decimal? SalaryMax { get; set; }
    public bool IsSalaryNegotiable { get; set; }
    public string? WorkingDays { get; set; }
    public TimeSpan? TimingFrom { get; set; }
    public TimeSpan? TimingTo { get; set; }
    public DateTime? LastDateToApply { get; set; }
    public DateTime? ExpectedJoiningDate { get; set; }
    public string? JobDescription { get; set; }
    public int JobStatusId { get; set; }

    public Guid SchoolUid { get; set; }
    public string SchoolName { get; set; } = string.Empty;
    public string? SchoolLogoPath { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public int? BranchCityId { get; set; }
    public int? BranchStateId { get; set; }

    public int ApplicationStatusId { get; set; }

    /// <summary>🔴 <c>TeacherFacingName</c>.</summary>
    public string StatusName { get; set; } = string.Empty;

    public DateTime AppliedOn { get; set; }
    public DateTime? ViewedOn { get; set; }
    public string? CoverNote { get; set; }
    public bool HasResume { get; set; }
    public bool IsActive { get; set; }

    public IReadOnlyList<MyApplicationStepDto> History { get; set; } = [];
}

/// <summary>
/// One step of the teacher's own journey.
/// </summary>
/// <remarks>
/// 🔴 NO Remarks AND NO ACTOR. The remarks are the school's internal note, and
/// which colleague pressed the button is the school's business. What the
/// teacher gets is when it moved and to what, in their words.
/// </remarks>
public sealed class MyApplicationStepDto
{
    public int ToStatusId { get; set; }
    public string StatusName { get; set; } = string.Empty;
    public DateTime ChangedOn { get; set; }
}

/// <summary>
/// A job the teacher saved.
/// </summary>
/// <remarks>
/// 🔴 SAVING IS NOT APPLYING. It is private to the teacher, tells the school
/// nothing, and must never unlock contact — <c>fn_TeacherContactUnlocked</c>
/// does not read <c>t_app_saved_jobs</c> and must never be made to (024).
/// </remarks>
public sealed class SavedJobDto
{
    public long SavedJobId { get; set; }
    public DateTime SavedOn { get; set; }

    public long JobId { get; set; }
    public Guid JobUid { get; set; }
    public string JobTitle { get; set; } = string.Empty;
    public int SubjectId { get; set; }
    public int DesignationId { get; set; }
    public int EmploymentTypeId { get; set; }
    public decimal? SalaryMin { get; set; }
    public decimal? SalaryMax { get; set; }
    public bool IsSalaryNegotiable { get; set; }
    public int? CityId { get; set; }
    public int? StateId { get; set; }
    public DateTime? LastDateToApply { get; set; }

    /// <summary>
    /// 🔴 EFFECTIVE. A saved job that has since expired is still returned, with
    /// its real status — removing it silently would look like the feature
    /// losing the teacher's data.
    /// </summary>
    public int JobStatusId { get; set; }

    public Guid SchoolUid { get; set; }
    public string SchoolName { get; set; } = string.Empty;
    public string? SchoolLogoPath { get; set; }
    public string BranchName { get; set; } = string.Empty;

    public bool HasApplied { get; set; }

    /// <summary>🔴 Aliased in the procedure (2.61).</summary>
    public bool IsActive { get; set; }
}

/// <summary>What a save/unsave toggle left behind.</summary>
public sealed class ToggleSavedJobResultDto
{
    public long JobId { get; set; }
    public bool IsSaved { get; set; }
}

/// <summary>The teacher dashboard's applications area.</summary>
public sealed class TeacherApplicationStatsDto
{
    public int TotalApplications { get; set; }
    public int AppliedCount { get; set; }
    public int ViewedCount { get; set; }
    public int ShortlistedCount { get; set; }
    public int InterviewCount { get; set; }
    public int SelectedCount { get; set; }
    public int RejectedCount { get; set; }
    public int SavedJobCount { get; set; }

    public IReadOnlyList<RecentMyApplicationDto> Recent { get; set; } = [];
}

/// <summary>A dashboard row on the teacher's side.</summary>
public sealed class RecentMyApplicationDto
{
    public long ApplicationId { get; set; }
    public Guid ApplicationUid { get; set; }
    public long JobId { get; set; }
    public string JobTitle { get; set; } = string.Empty;
    public Guid SchoolUid { get; set; }
    public string SchoolName { get; set; } = string.Empty;
    public string? SchoolLogoPath { get; set; }
    public int ApplicationStatusId { get; set; }

    /// <summary>🔴 <c>TeacherFacingName</c>.</summary>
    public string StatusName { get; set; } = string.Empty;

    public DateTime AppliedOn { get; set; }
    public DateTime? ViewedOn { get; set; }
}
