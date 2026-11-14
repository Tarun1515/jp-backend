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

/*==============================================================================
  SR-2 — THE CAMPUS-PIN DESK.

  ----------------------------------------------------------------------------
  🔴 PinRef IS AN OPAQUE STRING THE SERVER OWNS
  ----------------------------------------------------------------------------
  The client never builds one, parses one or compares two: it reads it off a
  row and posts it straight back on correct or clear. Today it is a BranchUid
  rendered as text. The day this desk also lists a registration that has no
  campus row yet, it becomes a discriminated string and not one line of client
  code changes.

  ⚠️ WHICH IS WHY IT IS A string AND NOT A Guid. A Guid property would publish
  the format in the contract, and the first client to construct one from a
  branch uid it got somewhere else would break on the day above.

  ----------------------------------------------------------------------------
  🔴 THREE THINGS IN THIS SHAPE THAT ARE NOT NEGOTIABLE
  ----------------------------------------------------------------------------
  THE THRESHOLD IS ON THE ROW. ThresholdKm travels with every row rather than
  living in a client constant. A client copy of a server setting is silently
  wrong the day the server is configured to anything else, and the screen would
  then explain the queue using the wrong number — "4.1 km, over the 3 km limit"
  beside a row that is listed because the limit is now 4.

  NeedsReview IS NOT DistanceKm > ThresholdKm. A CLEARED pin is a large distance
  an administrator has judged correct — a big site with its gate on another
  road, a village address that geocodes to the panchayat office. If the row
  carried only the comparison, that judgement would have nowhere to live and the
  same campus would be back on the queue tomorrow, for ever. IsCleared sits
  beside it so a screen can explain a large distance that needs no action.

  CORRECT AND CLEAR ARE SEPARATE ACTS. Correct overwrites the coordinates and
  records the previous pair; clear changes nothing at all and records that
  somebody decided the distance was fine. Posting the unchanged pin back through
  correct would write a correction that corrected nothing, and the trail would
  read "corrected by X" about somebody who deliberately did not move it — so
  USP_CorrectCampusPin refuses an unchanged pin by name and says to clear it
  instead.
==============================================================================*/

/// <summary>
/// One campus's pin, measured against the geocoded point of its own stated
/// address.
/// </summary>
public sealed class CampusPinReviewDto
{
    /// <summary>
    /// 🔴 OPAQUE. Echo it back on correct and clear; never parse it. See the
    /// block above.
    /// </summary>
    public string PinRef { get; set; } = string.Empty;

    public Guid SchoolUid { get; set; }

    public string SchoolName { get; set; } = string.Empty;

    /// <summary>
    /// ⚠️ Nullable in the contract although t_app_school_branches.BranchName is
    /// NOT NULL — the nullability is for the registration-sourced row that has
    /// no campus yet, so a client written against this shape does not have to
    /// change when one appears.
    /// </summary>
    public string? CampusName { get; set; }

    public bool IsHeadOffice { get; set; }

    /// <summary>The two address lines, joined, or null when both are empty.</summary>
    public string? AddressLine { get; set; }

    public string? CityName { get; set; }

    /// <summary>Where the school PINNED the campus.</summary>
    public decimal? Latitude { get; set; }

    public decimal? Longitude { get; set; }

    /// <summary>
    /// Where the address the school STATED geocodes to — the anchor.
    /// </summary>
    /// <remarks>
    /// 🔴 NOT the town centre. 038's header measures every coordinate in the
    /// database and says why none of the existing ones would do; these two
    /// columns were added by that file because the product stored no such
    /// point. Null until the address-lookup path writes one, which is SR-3 — so
    /// a row with a pin and no anchor reports no distance and needs no review,
    /// which is honest rather than reassuring.
    /// </remarks>
    public decimal? AnchorLatitude { get; set; }

    public decimal? AnchorLongitude { get; set; }

    /// <summary>
    /// The distance between the two, in kilometres. Null when there is nothing
    /// to measure.
    /// </summary>
    public decimal? DistanceKm { get; set; }

    /// <summary>🔴 The CONFIGURED threshold, on the row. See the block above.</summary>
    public decimal ThresholdKm { get; set; }

    /// <summary>
    /// 🔴 Too far AND not already judged correct. Never the bare comparison.
    /// </summary>
    public bool NeedsReview { get; set; }

    /// <summary>
    /// An administrator has recorded that this exact pin's distance is correct.
    /// </summary>
    /// <remarks>
    /// ⚠️ "THIS EXACT PIN". The judgement is derived from a CLEAR trail row
    /// whose previous pin EQUALS the one that is there now, so it lapses by
    /// itself if the school later moves the pin — no column to go stale and no
    /// sweep to forget to run (038's header).
    /// </remarks>
    public bool IsCleared { get; set; }

    /// <summary>When the anchor was geocoded.</summary>
    /// <remarks>
    /// ⚠️ SHOWN BESIDE <see cref="CampusModifiedOn"/> ON PURPOSE. An address
    /// edited after its geocode was taken leaves a STALE anchor, and nothing
    /// can prevent that without re-geocoding on every edit. What an admin can
    /// do is notice that the anchor predates the last change to the campus — so
    /// both timestamps travel, rather than a "stale" flag that would have to
    /// pick a tolerance.
    /// </remarks>
    public DateTime? AnchorTakenOn { get; set; }

    public DateTime? CampusModifiedOn { get; set; }

    /// <summary><c>CORRECT</c>, <c>CLEAR</c> or null.</summary>
    public string? LastActionType { get; set; }

    public long? LastActionByUserId { get; set; }

    public DateTime? LastActionOn { get; set; }

    /// <summary>
    /// The registration request this campus came from, when the row was fetched
    /// by request.
    /// </summary>
    /// <remarks>
    /// ⚠️ NULL ON THE LIST, AND THAT IS NOT LAZINESS. jp_app stores
    /// t_app_schools.SourceRequestUid — the request's UID, not its bigint id —
    /// and may not join to jp_mdm (2.2). Resolving the id for every row would be
    /// a cross-database lookup per row to render a number the list does not
    /// show. The by-request read already knows the id it was asked about, so it
    /// is the one path that can fill this in honestly.
    /// </remarks>
    public long? RequestId { get; set; }

    /// <summary>What administrators have done to this pin, newest first.</summary>
    /// <remarks>
    /// ⚠️ EMPTY ON THE LIST — twenty trails for a page nobody opened is twenty
    /// queries nobody asked for. The single-row reads populate it. An empty
    /// array beside a non-null <see cref="LastActionOn"/> means "not loaded",
    /// never "nothing happened".
    /// </remarks>
    public IReadOnlyList<CampusPinActionDto> Trail { get; set; } = [];
}

/// <summary>
/// One entry in a campus pin's trail, from the append-only
/// <c>t_app_branch_pin_review_log</c>.
/// </summary>
public sealed class CampusPinActionDto
{
    public long LogId { get; set; }

    /// <summary><c>CORRECT</c> or <c>CLEAR</c>.</summary>
    public string ActionType { get; set; } = string.Empty;

    public long? ActionByUserId { get; set; }

    public DateTime ActionOn { get; set; }

    /// <summary>
    /// 🔴 Required at the database (NOT NULL with a non-empty CHECK) and both
    /// procedures refuse an empty one. Nullable here only because the
    /// school-facing read shares this shape.
    /// </summary>
    public string? Remarks { get; set; }

    /// <summary>The pin as it stood when the action happened.</summary>
    /// <remarks>
    /// On a CORRECT this is what makes it reversible. On a CLEAR it is the
    /// SUBJECT of the judgement — the pin that was declared correct — which is
    /// how "cleared" is derived without a flag on the campus.
    /// </remarks>
    public decimal? PreviousLatitude { get; set; }

    public decimal? PreviousLongitude { get; set; }

    /// <summary>
    /// What it was set to. 🔴 NULL FOR A CLEAR, because a clear sets nothing.
    /// </summary>
    public decimal? NewLatitude { get; set; }

    public decimal? NewLongitude { get; set; }

    /// <summary>The anchor as it stood, copied — never joined live.</summary>
    /// <remarks>
    /// ⚠️ A log that joined the anchor live would silently re-tell its own past
    /// after a re-geocode: "corrected because it was 9km out" rendered as 300m
    /// out, with no record that anything moved.
    /// </remarks>
    public decimal? AnchorLatitude { get; set; }

    public decimal? AnchorLongitude { get; set; }

    /// <summary>
    /// The distance that justified the action, in METRES as the log stores it.
    /// </summary>
    /// <remarks>
    /// ⚠️ Metres here and kilometres on <see cref="CampusPinReviewDto"/>,
    /// deliberately: the row is a live measurement for a person to read, and the
    /// log is a record of what STDistance returned. Converting on the way into
    /// an append-only table would store a rounded figure derived from the real
    /// one, for ever.
    /// </remarks>
    public int? DistanceMetres { get; set; }
}

/// <summary>An administrator moving a campus pin.</summary>
public sealed class CorrectCampusPinRequest
{
    public decimal Latitude { get; set; }

    public decimal Longitude { get; set; }

    /// <summary>
    /// 🔴 REQUIRED, and the school is shown it. 034's floor: an action nobody
    /// can explain later is the one that becomes an argument, and this one
    /// overwrites a figure the school supplied.
    /// </summary>
    public string Remarks { get; set; } = string.Empty;
}

/// <summary>
/// An administrator recording that a campus pin's distance from its stated
/// address is correct. 🔴 Moves nothing.
/// </summary>
public sealed class ClearCampusPinRequest
{
    /// <summary>🔴 REQUIRED. "Why is 9km correct?" is the whole content here.</summary>
    public string Remarks { get; set; } = string.Empty;
}
