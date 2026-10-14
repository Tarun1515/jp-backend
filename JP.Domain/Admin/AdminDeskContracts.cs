namespace JP.Domain.Admin;

/*==============================================================================
  THE ADMIN OPERATIONS DESK. Phase 7B.

  Moderation, reports, featured placement, the site's copy, and the enquiries
  queue — five surfaces that share one property worth stating once:

  🔒 EVERYTHING HERE IS ADDRESSED BY UID (2.47). A request names a job, a
  school or a report by its uid; the integer ids stay inside the procedures.
  The exceptions are the FAQ, the content block, the enquiry and the featured
  window, which are admin-only rows with no public identity at all — those
  carry their own integer ids, and nothing outside the admin app ever sees one.
==============================================================================*/

/// <summary>Pull a job off the public site, or put it back.</summary>
/// <remarks>
/// 🔴 Remarks are REQUIRED on both, and the school is shown them. A moderation
/// action nobody can explain is the one that becomes an argument later.
/// </remarks>
public sealed class JobModerationRequest
{
    public string Remarks { get; set; } = string.Empty;
}

/// <summary>One line of a job's moderation history.</summary>
/// <remarks>
/// 🔒 NO ACTOR AND NO REPORTER. A school does not need to know which
/// administrator pulled their advert — naming one invites them to contact that
/// person directly — and it must never learn that somebody complained. 025's
/// procedure reads no report table at all, and a build guard asserts it.
/// </remarks>
public sealed class JobModerationEntryDto
{
    public long LogId { get; set; }

    /// <summary>PULL or RESTORE.</summary>
    public string ActionType { get; set; } = string.Empty;

    public string Remarks { get; set; } = string.Empty;

    public DateTime ActionOn { get; set; }

    /// <summary>The status the job held before this action, in words.</summary>
    public string? PreviousStatusName { get; set; }
}

/*------------------------------------------------------------------------------
  ONE ROW OF THE MODERATION QUEUE.

  🔴 THE APPLICATION COUNT IS DERIVED — COUNT(*) over live rows, every time.

  It is NOT t_app_jobs.ApplicationCount: 016 forbids writing that column and
  017 forbids reading it, because a denormalised copy drifts silently. The
  first version read it and every advert showed 0 applied, which the screens
  suite caught with two applications on the row.

  🔒 The procedure behind this may COUNT applications and may not write one —
  asserted through is_updated on sys.dm_sql_referenced_entities, in 025.

  ⚠️ EffectiveStatusId, not the stored one (2.65). A job whose last date has
  passed reads EXPIRED here, which is what the site shows, even though no row
  anywhere stores 3.
------------------------------------------------------------------------------*/
public sealed class ModeratableJobDto
{
    public Guid JobUid { get; set; }
    public string JobTitle { get; set; } = string.Empty;
    public Guid SchoolUid { get; set; }
    public string SchoolName { get; set; } = string.Empty;
    public string? CityName { get; set; }
    public int EffectiveStatusId { get; set; }
    public string? StatusName { get; set; }
    public int ApplicationCount { get; set; }
    public int ViewCount { get; set; }
    public DateTime? PublishedOn { get; set; }
    public DateTime? LastDateToApply { get; set; }

    /// <summary>Open (non-terminal) reports against this job — the triage signal.</summary>
    public int OpenReportCount { get; set; }

    /// <summary>PULL or RESTORE, or null for a job moderation has never touched.</summary>
    public string? LastActionType { get; set; }
    public DateTime? LastActionOn { get; set; }
}

/// <summary>What somebody reports, and why.</summary>
public sealed class SubmitReportRequest
{
    public int ReasonId { get; set; }

    /// <summary>JOB, TEACHER or SCHOOL.</summary>
    public string EntityType { get; set; } = string.Empty;

    public Guid EntityUid { get; set; }

    public string? Description { get; set; }
}

/// <summary>
/// One report, as the ADMIN sees it.
/// </summary>
/// <remarks>
/// 🔒 THIS TYPE CARRIES THE REPORTER AND IS RETURNED BY ADMIN ENDPOINTS ONLY.
///
/// <c>ReportedByUserUid</c> exists so an admin can see that one account filed
/// forty reports — <c>ReportsByThisAccount</c> is the number that makes a
/// pattern visible. Neither may reach the party being reported, which is why
/// no school-facing or teacher-facing endpoint returns this type and why 025
/// carries a build guard naming the only procedures allowed to project the
/// column.
///
/// ⚠️ 7B's verification reads the RAW BYTES of every response the reported
/// party can fetch and fails on this field's name appearing anywhere in them.
/// </remarks>
public sealed class ReportDto
{
    public Guid ReportUid { get; set; }

    public string ReportedEntityType { get; set; } = string.Empty;

    /// <summary>The reported thing's own uid, so the admin can open it.</summary>
    public Guid? EntityUid { get; set; }

    public string? EntityName { get; set; }

    public string ReasonName { get; set; } = string.Empty;

    public string? Description { get; set; }

    public string StatusCode { get; set; } = string.Empty;

    public string StatusName { get; set; } = string.Empty;

    /// <summary>🔒 Admin eyes only. See the remarks on this type.</summary>
    public Guid ReportedByUserUid { get; set; }

    /// <summary>🔒 Admin eyes only — how many this account has filed.</summary>
    public int ReportsByThisAccount { get; set; }

    public string? AdminRemarks { get; set; }

    public DateTime? ReviewedOn { get; set; }

    public DateTime CreatedOn { get; set; }
}

/// <summary>Move a report along: UnderReview, ActionTaken or Dismissed.</summary>
public sealed class UpdateReportStatusRequest
{
    public int StatusId { get; set; }

    /// <summary>
    /// ⚠️ Required for a TERMINAL state and optional for UnderReview. 025
    /// enforces that: "I am looking at this" needs no essay, and a decision
    /// with no reason is one nobody can review.
    /// </summary>
    public string? AdminRemarks { get; set; }
}

/// <summary>A featured window, as the admin list shows it.</summary>
/// <remarks>
/// 🔴 <c>IsLiveToday</c> IS COMPUTED, NOT STORED. Nothing anywhere records
/// whether a window is currently active — every read compares its dates
/// against <c>fn_IstToday()</c>. 034 fails the build if either featured table
/// grows a stored flag, because a flag needs a sweep and a sweep is a job that
/// will one day not run, silently.
/// </remarks>
public sealed class FeaturedWindowDto
{
    public long FeaturedId { get; set; }

    /// <summary>JOB or SCHOOL.</summary>
    public string FeaturedType { get; set; } = string.Empty;

    public Guid EntityUid { get; set; }

    public string EntityName { get; set; } = string.Empty;

    /// <summary>The school a featured JOB belongs to. Null for a featured school.</summary>
    public string? OwnerName { get; set; }

    public DateTime FromDate { get; set; }

    public DateTime ToDate { get; set; }

    public int DisplayOrder { get; set; }

    /// <summary>🔴 Derived from the IST date at read time. See the remarks above.</summary>
    public bool IsLiveToday { get; set; }

    /// <summary>
    /// ⚠️ The job's or school's own state, so an admin can see that a window
    /// will never show because the thing it promotes has been closed, pulled
    /// or suspended — without opening it.
    /// </summary>
    public string? EntityStatusName { get; set; }
}

public sealed class SaveFeaturedRequest
{
    /// <summary>JOB or SCHOOL.</summary>
    public string FeaturedType { get; set; } = string.Empty;

    public Guid EntityUid { get; set; }

    public DateTime FromDate { get; set; }

    public DateTime ToDate { get; set; }

    public int DisplayOrder { get; set; }
}

/// <summary>A FAQ as the admin edits it — including the hidden ones.</summary>
public sealed class AdminFaqDto
{
    public int FaqId { get; set; }

    /// <summary>TEACHER, SCHOOL or GENERAL.</summary>
    public string Category { get; set; } = string.Empty;

    public string Question { get; set; } = string.Empty;

    public string Answer { get; set; } = string.Empty;

    public int DisplayOrder { get; set; }

    /// <summary>
    /// ⚠️ The public read returns only live rows; this one returns the hidden
    /// rows too. A question an admin cannot see is one they cannot bring back.
    /// </summary>
    public bool IsActive { get; set; }

    public DateTime? ModifiedOn { get; set; }
}

public sealed class SaveFaqRequest
{
    /// <summary>Null to add a new one.</summary>
    public int? FaqId { get; set; }

    public string Category { get; set; } = string.Empty;

    public string Question { get; set; } = string.Empty;

    public string Answer { get; set; } = string.Empty;

    public int DisplayOrder { get; set; }

    public bool IsActive { get; set; } = true;
}

/// <summary>A content block as the admin edits it.</summary>
public sealed class AdminContentBlockDto
{
    public int BlockId { get; set; }

    /// <summary>🔴 The key is the contract (2.81) — a template names this, not an id.</summary>
    public string BlockKey { get; set; } = string.Empty;

    public string? BlockTitle { get; set; }

    public string BlockContent { get; set; } = string.Empty;

    public string? ImagePath { get; set; }

    public int DisplayOrder { get; set; }

    public bool IsActive { get; set; }

    public DateTime? ModifiedOn { get; set; }
}

public sealed class SaveContentBlockRequest
{
    public string BlockKey { get; set; } = string.Empty;

    public string? BlockTitle { get; set; }

    public string BlockContent { get; set; } = string.Empty;

    public string? ImagePath { get; set; }

    public int DisplayOrder { get; set; }

    public bool IsActive { get; set; } = true;
}

/// <summary>
/// One contact enquiry in the queue.
/// </summary>
/// <remarks>
/// 🔒 THERE IS NO CALLER IDENTITY TO SHOW, and that is 033's design: an enquiry
/// arrives from an anonymous visitor, so the table has no UserUid column and a
/// build guard fails if it gains one. What an admin sees is what the visitor
/// typed.
/// </remarks>
public sealed class EnquiryDto
{
    public long EnquiryId { get; set; }

    public string Name { get; set; } = string.Empty;

    public string Email { get; set; } = string.Empty;

    public string? Mobile { get; set; }

    public string Subject { get; set; } = string.Empty;

    public string Message { get; set; } = string.Empty;

    public bool IsResolved { get; set; }

    public DateTime? ResolvedOn { get; set; }

    public string? ResolutionRemarks { get; set; }

    public DateTime CreatedOn { get; set; }
}

public sealed class ResolveEnquiryRequest
{
    /// <summary>
    /// 🔴 Required. 033's CHECK already demands a resolver and a timestamp; the
    /// remark is what makes the trail answer the question somebody will
    /// actually ask, which is "what did we tell them?".
    /// </summary>
    public string Remarks { get; set; } = string.Empty;
}
