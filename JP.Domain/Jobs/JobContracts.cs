namespace JP.Domain.Jobs;

/*==============================================================================
  🔴 SchoolId NEVER APPEARS ON ANY DTO IN THIS FILE (2.39).

  It lives in jp_app and never leaves the server. The API resolves it from the
  token's OrganizationUid on every request. If it went out in a response, the
  next developer would reasonably assume it can be sent back in — and the whole
  tenant-isolation rule ends there.

  ⚠️ BranchId DOES appear, in both directions, because a job genuinely belongs
  to a campus the user picks. That is exactly why it is the dangerous one: it is
  legitimate data AND an authorization input, and only validation tells them
  apart. Every procedure joins through fn_VisibleBranches before using it.
==============================================================================*/

/// <summary>Stored statuses. ⚠️ Expired (3) is derived, never written.</summary>
public static class JobStatus
{
    public const int Draft = 1;
    public const int Active = 2;

    /// <summary>
    /// 🔴 Never stored in <c>t_app_jobs.JobStatusId</c> — a CHECK constraint
    /// forbids it. An Active job past its LastDateToApply READS as this,
    /// through <c>fn_EffectiveJobStatusId</c>. There is no sweep job.
    /// </summary>
    public const int Expired = 3;

    public const int Closed = 4;
}

/// <summary>One row of the school's job list.</summary>
public sealed class JobListItemDto
{
    public long JobId { get; set; }
    public Guid JobUid { get; set; }
    public long BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
    public string JobTitle { get; set; } = string.Empty;

    public int SubjectId { get; set; }
    public int DesignationId { get; set; }
    public int EmploymentTypeId { get; set; }
    public int NoOfVacancies { get; set; }

    public decimal? SalaryMin { get; set; }
    public decimal? SalaryMax { get; set; }
    public bool IsSalaryNegotiable { get; set; }

    public DateTime? LastDateToApply { get; set; }
    public DateTime? PublishedOn { get; set; }
    public DateTime? ClosedOn { get; set; }

    public int ViewCount { get; set; }
    public int ApplicationCount { get; set; }
    public int RowVersion { get; set; }

    /// <summary>
    /// 🔴 The EFFECTIVE status — what the job actually is right now.
    /// </summary>
    /// <remarks>
    /// Differs from <see cref="StoredStatusId"/> for exactly one case: an
    /// Active job whose closing date has passed reads Expired here and Active
    /// there. Both are returned so a screen can show the truth and a
    /// verification can prove the derivation happened without a process running.
    /// </remarks>
    public int JobStatusId { get; set; }

    /// <summary>What the database row literally holds.</summary>
    public int StoredStatusId { get; set; }

    public string StatusName { get; set; } = string.Empty;
    public string StoredStatusName { get; set; } = string.Empty;

    /// <summary>🔴 Arrives through an alias in the procedure (2.61).</summary>
    public bool IsActive { get; set; }
}

/// <summary>One job, with its subject and class-level sets.</summary>
public sealed class JobDetailDto
{
    public long JobId { get; set; }
    public Guid JobUid { get; set; }
    public long BranchId { get; set; }
    public string BranchName { get; set; } = string.Empty;
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
    public DateTime? ClosedOn { get; set; }
    public int ViewCount { get; set; }
    public int ApplicationCount { get; set; }
    public int RowVersion { get; set; }

    public int JobStatusId { get; set; }
    public int StoredStatusId { get; set; }
    public string StatusName { get; set; } = string.Empty;

    /// <summary>🔴 Aliased in the procedure (2.61).</summary>
    public bool IsActive { get; set; }

    public IReadOnlyList<int> SubjectIds { get; set; } = [];
    public IReadOnlyList<int> ClassLevelIds { get; set; } = [];

    /// <summary>
    /// Whether the structural fields are locked right now.
    /// </summary>
    /// <remarks>
    /// ⚠️ Presentation only. The procedure enforces the lock; this lets the
    /// form grey the fields out instead of letting somebody fill them in and
    /// then be refused. A screen that disagreed with the server would be a
    /// nuisance, not a hole.
    /// </remarks>
    public bool StructuralFieldsLocked { get; set; }
}

/// <summary>Create or edit. JobId null means create.</summary>
public sealed class SaveJobRequest
{
    public long? JobId { get; set; }

    /// <summary>
    /// 🔴 Data AND an authorization input. Validated against the caller's
    /// resolved branch scope before use; a branch they do not hold is NOT_FOUND.
    /// </summary>
    public long BranchId { get; set; }

    public string JobTitle { get; set; } = string.Empty;
    public int SubjectId { get; set; }
    public int DesignationId { get; set; }
    public int? QualificationId { get; set; }
    public int EmploymentTypeId { get; set; } = 1;
    public int NoOfVacancies { get; set; } = 1;

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

    public IReadOnlyList<int> SubjectIds { get; set; } = [];
    public IReadOnlyList<int> ClassLevelIds { get; set; } = [];

    public int? RowVersion { get; set; }
}

/// <summary>What a publish did — including what it cost.</summary>
public sealed class PublishJobResultDto
{
    public long JobId { get; set; }
    public int JobStatusId { get; set; }

    /// <summary>
    /// True only when a ledger row was written. False on a FREE feature, and
    /// false on a re-publish that resolved as ALREADY_CONSUMED.
    /// </summary>
    public bool Consumed { get; set; }

    /// <summary>1 = plan quota, 2 = credits. Null when nothing was consumed.</summary>
    public int? Source { get; set; }

    /// <summary>The ledger entry, when there is one.</summary>
    public long? EntryId { get; set; }

    /// <summary>
    /// ⚠️ Can be set on a SUCCESS — <c>ALREADY_CONSUMED</c> means the job was
    /// published and nothing was charged, because this job had been paid for
    /// before. Branch on the HTTP status first, then the code.
    /// </summary>
    public string? Code { get; set; }
}

/// <summary>The dashboard's jobs area.</summary>
/// <remarks>
/// 🔴 3I shipped this area as an honest empty state because there was no table
/// to count. There is one now, so it counts — and a school with no jobs shows a
/// real zero, which is a measurement rather than a placeholder.
///
/// ⚠️ The APPLICATIONS area on the same dashboard stays a not-yet empty state.
/// t_app_applications is Phase 5, and a zero there would still be a number with
/// nothing behind it (2.62).
/// </remarks>
public sealed class SchoolJobStatsDto
{
    public int TotalJobs { get; set; }
    public int DraftCount { get; set; }
    public int ActiveCount { get; set; }
    public int ExpiredCount { get; set; }
    public int ClosedCount { get; set; }

    public IReadOnlyList<RecentJobDto> Recent { get; set; } = [];
}

public sealed class RecentJobDto
{
    public long JobId { get; set; }
    public Guid JobUid { get; set; }
    public string JobTitle { get; set; } = string.Empty;
    public string BranchName { get; set; } = string.Empty;
    public DateTime? LastDateToApply { get; set; }
    public DateTime? PublishedOn { get; set; }
    public int NoOfVacancies { get; set; }
    public int JobStatusId { get; set; }
    public string StatusName { get; set; } = string.Empty;
}
