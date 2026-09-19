/*==============================================================================
  jp_app — 04_procedures / 017_application_reads.sql

  Everything that READS an application. Phase 5.

  016 writes; this file is the other half. They are separate files for the same
  reason 010 is two procedures rather than one with a flag: what a SCHOOL may
  see of an application and what a TEACHER may see of the same row are two
  different shapes, and a single procedure with an audience parameter is one
  forgotten column away from showing the wrong one to the wrong person.

  ---------------------------------------------------------------------------
  🔴 THE FOUR RULES EVERY PROCEDURE IN THIS FILE OBEYS
  ---------------------------------------------------------------------------

  1. CONTACT COMES FROM ONE FUNCTION, AND NOTHING ELSE.

     dbo.fn_TeacherContactUnlocked(@TeacherId, @SchoolId) decides whether a
     school sees an email, a mobile number or a resume. Not "an application
     row exists here, so obviously yes". Not a plan, not a subscription, not a
     role (2.56, LOCKED).

     ⚠️ It will always answer 1 on the applicant detail — the application IS
     the consent, so the question is answered before it is asked. It is still
     asked. The day a second reader appears that does NOT have an application
     in hand, it will copy this shape, and this shape is correct.

  2. SCOPE IS fn_VisibleBranches, ON EVERY SCHOOL-SIDE READ.

     A branch-bound HR sees applications at the campuses they hold and nothing
     else. The join is on t_app_applications' OWN denormalised BranchId (024),
     never routed through the job.

     ⚠️ An application outside the caller's scope produces ZERO ROWS, which
     the API turns into 404 — never FORBIDDEN, which would confirm it exists
     (2.6).

  3. 🔴 ApplicationCount IS DERIVED. COUNT of live rows, every time it is
     shown. t_app_jobs.ApplicationCount is deliberately left at zero and must
     never be written — see 024's header for the whole argument. This file
     never reads that column either, so a stale value cannot leak through a
     projection.

  4. 🔴 EVERY UNDERSCORE COLUMN IS ALIASED — `Is_Active AS IsActive` (2.61,
     incident G25). Dapper does not strip underscores and the failure is
     SILENT: the property keeps its default and nothing errors.

  ---------------------------------------------------------------------------
  ⚠️ WHAT THE TEACHER IS NEVER TOLD
  ---------------------------------------------------------------------------
  RejectionReason and the history's Remarks are the SCHOOL'S OWN notes. They
  are stored, they are shown to the school, and they do not appear in a single
  teacher-facing SELECT in this file. The teacher sees TeacherFacingName —
  "Not selected" — and nothing more.

  Free text written for one audience has a way of reaching the other, so the
  guard is that the columns are ABSENT from the teacher's procedures rather
  than blanked in them.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_GetTeacherIdForUser — the teacher behind a token, and nothing else.

  ⚠️ WHY THIS EXISTS AT ALL.

  Every teacher-facing READ in this file takes @UserUid and resolves the
  teacher itself, so "somebody else's list" cannot be expressed. But the two
  WRITES — USP_ApplyToJob and USP_ToggleSavedJob (016) — take @TeacherId,
  because an application is a row about a teacher rather than about a login.

  So the API needs exactly one lookup: token -> teacher. This is it, and it is
  the mirror of ISchoolProfileService.ResolveSchoolIdAsync on the school side
  (2.39): the value is resolved from the token on the server and there is no
  request field a client could set instead.

  🔴 A SUSPENDED TEACHER RESOLVES TO NOTHING. Suspension is an administrative
  decision about the person (2.9's companion), and an account that cannot be
  browsed must not be able to apply either — otherwise the suspension is
  cosmetic.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetTeacherIdForUser
    @UserUid uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    SELECT t.TeacherId,
           t.TeacherUid,
           CASE WHEN t.ResumePath IS NULL OR LTRIM(RTRIM(t.ResumePath)) = ''
                THEN CAST(0 AS tinyint) ELSE CAST(1 AS tinyint) END AS HasResume
    FROM dbo.t_app_teachers t
    WHERE t.UserUid     = @UserUid
      AND t.Is_Deleted  = 0
      AND t.Is_Active   = 1
      AND t.IsSuspended = 0;
END
GO


/*==============================================================================
  USP_GetApplicantList — the school's applicants, school-wide or per job.

  One procedure for both because they are the same question with one more
  filter: @JobId NULL means "everybody who has applied to us", and a value
  means "everybody on this posting". Two procedures would be two places for
  the scope join to be forgotten in.

  ---------------------------------------------------------------------------
  🔴 NO CONTACT COLUMNS HERE — NOT NULL, ABSENT
  ---------------------------------------------------------------------------
  Email, mobile and the resume snapshot are not in this SELECT and must not be
  added to it. Every applicant on this list HAS consented, so returning them
  would not be a rule violation — it would be a SHAPE violation, and the shape
  is what has held the line since 3D: a list is a browse surface, forty rows
  wide, that ends up in a log, an export or a screenshot. Contact is a
  deliberate act on ONE person, and that is the detail procedure.

  ⚠️ The same reasoning 010's header gives for USP_GetTeacherPublicProfile.
  A column present-but-empty is one somebody populates later without thinking.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetApplicantList
    @SchoolId   bigint,
    @UserUid    uniqueidentifier,
    @JobId      bigint = NULL,
    @StatusId   int    = NULL,
    @BranchId   bigint = NULL,
    @Top        int    = 200
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (@Top)
        a.ApplicationId,
        a.ApplicationUid,

        a.JobId,
        j.JobTitle,
        j.SubjectId,
        j.DesignationId,

        -- 🔴 BranchId travels; SchoolId never does (2.39). A campus is data
        -- the school itself chose; its tenant id is not.
        a.BranchId,
        b.BranchName,

        -- The teacher, by their PUBLIC identifier. TeacherId stays server-side
        -- for the same reason SchoolId does.
        t.TeacherUid,
        t.FullName            AS TeacherName,
        t.PhotoPath,
        t.DesignationId       AS TeacherDesignationId,
        t.QualificationId     AS TeacherQualificationId,
        t.TotalExperienceMonths,
        t.CurrentCityId,
        t.CurrentStateId,
        t.ProfileCompletionPercent,

        -- 🔴 A BADGE, NOT A GATE (2.9). An unverified teacher is listed like
        -- anybody else; the school is told which is which and decides.
        t.IsVerified,

        a.ApplicationStatusId,
        st.Name               AS StatusName,
        a.AppliedOn,
        a.ViewedOn,

        /*
          The FACT of a resume, never its path. A school that wants to read it
          opens the applicant and downloads it — which is gated on
          RESUME.DOWNLOAD, and a list that carried the path would route round
          that permission entirely.
        */
        CASE WHEN a.ResumePathSnapshot IS NULL THEN CAST(0 AS tinyint)
             ELSE CAST(1 AS tinyint) END AS HasResume,

        CASE WHEN a.CoverNote IS NULL THEN CAST(0 AS tinyint)
             ELSE CAST(1 AS tinyint) END AS HasCoverNote,

        a.RowVersion,
        a.Is_Active AS IsActive          -- 🔴 2.61
    FROM dbo.t_app_applications a
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = a.BranchId
        INNER JOIN dbo.t_app_jobs j             ON j.JobId     = a.JobId
        INNER JOIN dbo.t_app_school_branches b  ON b.BranchId  = a.BranchId
        INNER JOIN dbo.t_app_teachers t         ON t.TeacherId = a.TeacherId
        INNER JOIN dbo.m_app_application_status st ON st.ApplicationStatusId = a.ApplicationStatusId
    WHERE a.SchoolId    = @SchoolId
      AND a.Is_Deleted  = 0
      AND (@JobId    IS NULL OR a.JobId    = @JobId)
      AND (@StatusId IS NULL OR a.ApplicationStatusId = @StatusId)
      AND (@BranchId IS NULL OR a.BranchId = @BranchId)
    ORDER BY
        -- Unopened first — they are the ones with something to do — then
        -- newest. The same reasoning as drafts leading the job list.
        CASE WHEN a.ApplicationStatusId = 1 THEN 0 ELSE 1 END,
        a.AppliedOn DESC,
        a.ApplicationId DESC;
END
GO


/*==============================================================================
  USP_GetApplicantById — one applicant, in full.

  Two result sets: the application (with the teacher's summary and the
  CONTACT block), then the status history.

  ---------------------------------------------------------------------------
  🔴 THE SNAPSHOT, NEVER THE LIVE RESUME
  ---------------------------------------------------------------------------
  a.ResumePathSnapshot, and there is deliberately no join to
  t_app_teachers.ResumePath anywhere in this procedure. A teacher who replaces
  their resume next month must not retroactively change the document a school
  already read and decided on (024).

  ⚠️ That is the single easiest thing in this phase to get wrong, because the
  teacher row is ALREADY JOINED here for the name and the photo, so the live
  column is one keystroke away. If you are adding a resume column, it comes
  from `a.`, never from `t.`.

  ---------------------------------------------------------------------------
  🔴 CONTACT GOES THROUGH fn_TeacherContactUnlocked. ONLY.
  ---------------------------------------------------------------------------
  Not `WHERE EXISTS (an application)` written out again here — that would be a
  second copy of the rule, and the day 2.56 is extended the two would disagree
  with nothing erroring. One function decides, everywhere.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetApplicantById
    @SchoolId       bigint,
    @UserUid        uniqueidentifier,
    @ApplicationId  bigint
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TeacherId bigint, @Unlocked bit = 0, @CurrentStatusId int;

    /*
      Resolve through the scope FIRST. An application at a campus this user
      does not hold leaves @TeacherId null, @Unlocked 0, and all three result
      sets empty — which the API reads as 404.
    */
    SELECT @TeacherId       = a.TeacherId,
           @CurrentStatusId = a.ApplicationStatusId
    FROM dbo.t_app_applications a
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = a.BranchId
    WHERE a.ApplicationId = @ApplicationId
      AND a.SchoolId      = @SchoolId
      AND a.Is_Deleted    = 0;

    IF @TeacherId IS NOT NULL
        SET @Unlocked = dbo.fn_TeacherContactUnlocked(@TeacherId, @SchoolId);

    -- ---- 1. the application, the teacher, and the contact block -----------
    SELECT
        a.ApplicationId,
        a.ApplicationUid,

        a.JobId,
        j.JobTitle,
        j.SubjectId,
        j.DesignationId,
        j.EmploymentTypeId,
        j.NoOfVacancies,
        j.LastDateToApply,
        dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) AS JobStatusId,

        a.BranchId,
        b.BranchName,

        t.TeacherUid,
        t.FullName        AS TeacherName,
        t.PhotoPath,
        t.GenderId,
        t.QualificationId AS TeacherQualificationId,
        t.HighestQualificationText,
        t.DesignationId   AS TeacherDesignationId,
        t.TotalExperienceMonths,
        t.CurrentSchool,
        t.LastSchool,
        t.ExpectedSalaryMin,
        t.ExpectedSalaryMax,
        t.CurrentCityId,
        t.CurrentStateId,
        t.AboutMe,
        t.IsVerified,
        t.ProfileCompletionPercent,

        a.ApplicationStatusId,
        st.Name           AS StatusName,
        a.AppliedOn,
        a.ViewedOn,
        a.CoverNote,

        /*
          The school's own note on a rejection. Shown HERE and nowhere on the
          teacher's side — see this file's header.
        */
        a.RejectionReason,

        a.RowVersion,
        a.Is_Active AS IsActive,          -- 🔴 2.61

        /*
          ---- THE CONTACT BLOCK ------------------------------------------

          🔴 Present and NULL when locked, exactly as USP_GetTeacherContactForSchool
          returns them. Here contact IS part of the purpose, so the columns are
          the contract and IsContactUnlocked says whether they are real. On a
          BROWSE surface the opposite rule applies and the columns do not exist
          at all — USP_GetApplicantList above.

          ⚠️ Email and mobile are read from the jp_sso account, not copied onto
          the profile: a teacher's email is their sign-in identity and a second
          copy would let the two disagree about how to reach somebody.
        */
        CAST(@Unlocked AS tinyint)                            AS IsContactUnlocked,
        CASE WHEN @Unlocked = 1 THEN u.Email  END             AS ContactEmail,
        CASE WHEN @Unlocked = 1 THEN u.Mobile END             AS ContactMobile,

        -- 🔴 THE SNAPSHOT. `a.`, never `t.`.
        CASE WHEN @Unlocked = 1 THEN a.ResumePathSnapshot END AS ResumePathSnapshot,
        CASE WHEN a.ResumePathSnapshot IS NULL THEN CAST(0 AS tinyint)
             ELSE CAST(1 AS tinyint) END                      AS HasResume
    FROM dbo.t_app_applications a
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = a.BranchId
        INNER JOIN dbo.t_app_jobs j             ON j.JobId     = a.JobId
        INNER JOIN dbo.t_app_school_branches b  ON b.BranchId  = a.BranchId
        INNER JOIN dbo.t_app_teachers t         ON t.TeacherId = a.TeacherId
        INNER JOIN dbo.m_app_application_status st ON st.ApplicationStatusId = a.ApplicationStatusId
        LEFT  JOIN jp_sso.dbo.t_sso_users u     ON u.UserUid   = t.UserUid
    WHERE a.ApplicationId = @ApplicationId
      AND a.SchoolId      = @SchoolId
      AND a.Is_Deleted    = 0;

    /*
      ---- 2. the status history ----------------------------------------------

      Append-only, oldest first: how this application got where it is, and who
      moved it.

      ---------------------------------------------------------------------
      🔴 ChangedByName COMES FROM t_app_school_users, AND NEVER FROM AN EMAIL
      ---------------------------------------------------------------------
      The obvious implementation — join jp_sso for the actor and fall back to
      their Email when there is no display name — LEAKS A TEACHER'S EMAIL
      ADDRESS. The FIRST history row on every application is written by the
      TEACHER (USP_ApplyToJob passes their user id as the actor), so that
      fallback would hand the school the teacher's sign-in address on the
      detail screen of every applicant, unlocked or not, gated by nothing.

      ⚠️ So the name is resolved ONLY through this school's own colleague list.
      An actor who is not a colleague of this school — the teacher — resolves
      to NULL, and the screen says "the applicant". There is no fallback, on
      purpose, and there must never be one.
    */
    SELECT
        h.HistoryId,
        h.FromStatusId,
        fs.Name AS FromStatusName,
        h.ToStatusId,
        ts.Name AS ToStatusName,
        h.ChangedOn,
        h.ChangedByUserId,
        csu.FullName AS ChangedByName,     -- 🔴 NULL for the teacher. See above.
        h.Remarks
    FROM dbo.t_app_application_status_history h
        INNER JOIN dbo.t_app_applications a ON a.ApplicationId = h.ApplicationId
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = a.BranchId
        LEFT  JOIN dbo.m_app_application_status fs ON fs.ApplicationStatusId = h.FromStatusId
        INNER JOIN dbo.m_app_application_status ts ON ts.ApplicationStatusId = h.ToStatusId
        LEFT  JOIN jp_sso.dbo.t_sso_users cu       ON cu.UserId  = h.ChangedByUserId
        LEFT  JOIN dbo.t_app_school_users csu      ON csu.UserUid = cu.UserUid
                                                  AND csu.SchoolId  = @SchoolId
                                                  AND csu.Is_Deleted = 0
    WHERE h.ApplicationId = @ApplicationId
      AND a.SchoolId      = @SchoolId
      AND a.Is_Deleted    = 0
      AND h.Is_Deleted    = 0
    ORDER BY h.ChangedOn, h.HistoryId;

    /*
      ---- 3. what this application may become next --------------------------

      -----------------------------------------------------------------------
      🔴 THE SCREEN MUST NOT OWN A SECOND COPY OF THE TRANSITION MAP
      -----------------------------------------------------------------------
      016's header calls fn_ApplicationTransitionAllowed "the whole status
      machine, in one place", and the only way that stays true is if the thing
      DRAWING THE BUTTONS asks it rather than reimplementing it. A TypeScript
      copy of "Applied -> 2, 3, 6" would be a second source of truth for a rule
      the database already enforces, and the two would drift the first time
      anybody edited one — silently, because the server would simply refuse an
      action the screen had offered.

      This CROSS APPLY runs the real function against every reachable status,
      so the answer is the function's by construction rather than by agreement.

      ⚠️ AN EMPTY SET IS A REAL ANSWER, NOT A MISSING ONE. A Rejected
      application is terminal, so nothing comes back and the screen draws no
      actions at all — which is the 3F/3G rule (a move that will never be
      allowed is ABSENT, not disabled). Do not let a caller read empty as
      "unknown, show everything".

      ⚠️ The offer chain cannot appear here whatever the master says: the
      function refuses 7..10 outright until Phase 6 (016).

      🔴 st.Name, never st.TeacherFacingName — these are the SCHOOL's buttons.
    */
    SELECT
        st.ApplicationStatusId,
        st.Code,
        st.Name,
        st.DisplayOrder
    FROM dbo.m_app_application_status st
        CROSS APPLY (SELECT dbo.fn_ApplicationTransitionAllowed(
                                @CurrentStatusId, st.ApplicationStatusId) AS Allowed) t
    WHERE st.Is_Deleted  = 0
      AND st.Is_Active   = 1
      AND st.IsReachable = 1
      AND t.Allowed      = 1
      AND @CurrentStatusId IS NOT NULL      -- out of scope: no rows, like the two above
    ORDER BY st.DisplayOrder;
END
GO


/*==============================================================================
  USP_GetApplicantResumeSnapshot — the path of the file a school may download.

  🔴 Returns the SNAPSHOT and nothing else. One column, so there is nothing
  else on the row to leak, and the API serves the bytes behind RESUME.DOWNLOAD.

  ⚠️ Scoped like every other school-side read. Another school's application, or
  one at a campus the caller does not hold, returns no row — and the API turns
  "no row" into 404 rather than into an empty file.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetApplicantResumeSnapshot
    @SchoolId       bigint,
    @UserUid        uniqueidentifier,
    @ApplicationId  bigint
AS
BEGIN
    SET NOCOUNT ON;

    SELECT a.ResumePathSnapshot
    FROM dbo.t_app_applications a
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = a.BranchId
    WHERE a.ApplicationId = @ApplicationId
      AND a.SchoolId      = @SchoolId
      AND a.Is_Deleted    = 0
      AND a.ResumePathSnapshot IS NOT NULL;
END
GO


/*==============================================================================
  USP_GetSchoolApplicantStats — the dashboard's applicants area.

  🔴 3I shipped this area as an honest not-yet empty state, because a zero with
  no table behind it is a placeholder wearing a number's clothes (2.62). There
  is a table now, so it counts — and a school with no applicants shows a real
  zero, which is a measurement.

  ⚠️ Branch-scoped like everything else, so a branch-bound HR's tile counts
  THEIR campuses. A total that disagreed with the list underneath it would be
  read as a bug in the list.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetSchoolApplicantStats
    @SchoolId   bigint,
    @UserUid    uniqueidentifier,
    @RecentTop  int = 5
AS
BEGIN
    SET NOCOUNT ON;

    /*
      ISNULL around every SUM. COUNT over zero rows is 0; SUM over zero rows is
      NULL, and a NULL arriving in a non-nullable int is the kind of thing that
      fails on the first school with no applicants rather than in testing.
    */
    SELECT
        COUNT(*)                                                                   AS TotalApplications,
        ISNULL(SUM(CASE WHEN a.ApplicationStatusId = 1 THEN 1 ELSE 0 END), 0)      AS NewCount,
        ISNULL(SUM(CASE WHEN a.ApplicationStatusId = 2 THEN 1 ELSE 0 END), 0)      AS ViewedCount,
        ISNULL(SUM(CASE WHEN a.ApplicationStatusId = 3 THEN 1 ELSE 0 END), 0)      AS ShortlistedCount,
        ISNULL(SUM(CASE WHEN a.ApplicationStatusId = 4 THEN 1 ELSE 0 END), 0)      AS InterviewCount,
        ISNULL(SUM(CASE WHEN a.ApplicationStatusId = 5 THEN 1 ELSE 0 END), 0)      AS SelectedCount,
        ISNULL(SUM(CASE WHEN a.ApplicationStatusId = 6 THEN 1 ELSE 0 END), 0)      AS RejectedCount,

        -- How many distinct postings have somebody on them. The useful second
        -- number: "forty applicants" reads differently across two jobs than
        -- across twenty.
        COUNT(DISTINCT a.JobId)                                                    AS JobsWithApplicants
    FROM dbo.t_app_applications a
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = a.BranchId
    WHERE a.SchoolId = @SchoolId AND a.Is_Deleted = 0;

    -- 🔴 No contact columns. A dashboard tile is the widest browse surface in
    -- the product.
    SELECT TOP (@RecentTop)
        a.ApplicationId,
        a.ApplicationUid,
        a.JobId,
        j.JobTitle,
        b.BranchName,
        t.TeacherUid,
        t.FullName AS TeacherName,
        t.PhotoPath,
        t.IsVerified,
        a.ApplicationStatusId,
        st.Name    AS StatusName,
        a.AppliedOn,
        a.ViewedOn
    FROM dbo.t_app_applications a
        INNER JOIN dbo.fn_VisibleBranches(@SchoolId, @UserUid) v ON v.BranchId = a.BranchId
        INNER JOIN dbo.t_app_jobs j            ON j.JobId     = a.JobId
        INNER JOIN dbo.t_app_school_branches b ON b.BranchId  = a.BranchId
        INNER JOIN dbo.t_app_teachers t        ON t.TeacherId = a.TeacherId
        INNER JOIN dbo.m_app_application_status st ON st.ApplicationStatusId = a.ApplicationStatusId
    WHERE a.SchoolId = @SchoolId AND a.Is_Deleted = 0
    ORDER BY a.AppliedOn DESC, a.ApplicationId DESC;
END
GO


/*==============================================================================
  USP_BrowseJobs — what a teacher can see of the job market.

  ---------------------------------------------------------------------------
  🔴 ACTIVE ONLY, BY THE EFFECTIVE STATUS. AN EXPIRED JOB MUST NOT LIST.
  ---------------------------------------------------------------------------
  The filter is written as TWO predicates on purpose:

      j.JobStatusId = 2                                   -- the indexed seek
      AND dbo.fn_EffectiveJobStatusId(...) = 2            -- the date narrowing

  The first is sargable and does the work; the second removes the Active rows
  whose closing date has passed. That is the exact shape 014's header asks a
  public search to use — the stored status first, the derivation after — so the
  index still seeks on a table that will be the largest in the product.

  ⚠️ Writing only the second would be correct and would scan. Writing only the
  first would be fast and WRONG: a teacher would apply to a closed posting and
  be refused by the server, which is a bug that looks like a rude product.

  🔴 A SUSPENDED OR DEACTIVATED SCHOOL'S JOBS DO NOT LIST. Suspension is an
  administrative decision about that organisation, and it has to reach the
  listing or it is cosmetic — the same rule 010 applies to a suspended teacher.

  ⚠️ ViewCount is NOT incremented here. A read that writes cannot be retried,
  cached or verified, and a browse that bumps a counter would make every list
  render a write. Phase 6 can add it deliberately if it is wanted.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_BrowseJobs
    @UserUid           uniqueidentifier = NULL,
    @Search            nvarchar(150)    = NULL,
    @SubjectId         int              = NULL,
    @DesignationId     int              = NULL,
    @EmploymentTypeId  int              = NULL,
    @CityId            int              = NULL,
    @StateId           int              = NULL,
    @MinSalary         decimal(18, 2)   = NULL,
    @PageNumber        int              = 1,
    @PageSize          int              = 20
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize   IS NULL OR @PageSize   < 1 SET @PageSize   = 20;
    IF @PageSize > 200 SET @PageSize = 200;

    /*
      The caller's own teacher row, so each card can say "you have applied" and
      "you saved this". NULL @UserUid — a signed-out browse, which Phase 6's
      public search will want — simply leaves both flags 0.
    */
    DECLARE @TeacherId bigint = NULL;

    IF @UserUid IS NOT NULL
        SELECT @TeacherId = t.TeacherId
        FROM dbo.t_app_teachers t
        WHERE t.UserUid = @UserUid AND t.Is_Deleted = 0 AND t.Is_Active = 1 AND t.IsSuspended = 0;

    SELECT
        j.JobId,
        j.JobUid,
        j.JobTitle,
        j.SubjectId,
        j.DesignationId,
        j.QualificationId,
        j.EmploymentTypeId,
        j.NoOfVacancies,
        j.MinExperienceMonths,
        j.MaxExperienceMonths,
        j.SalaryMin,
        j.SalaryMax,
        j.IsSalaryNegotiable,
        j.CityId,
        j.StateId,
        j.LastDateToApply,
        j.ExpectedJoiningDate,
        j.PublishedOn,

        -- 🔴 SchoolUid, never SchoolId (2.39). The public identifier is what
        -- the teacher's screen links to the school profile with.
        s.SchoolUid,
        s.SchoolName,
        s.LogoPath        AS SchoolLogoPath,
        s.IsVerified      AS IsSchoolVerified,
        b.BranchName,

        -- 🔴 DERIVED. t_app_jobs.ApplicationCount is never read and never
        -- written (024).
        (SELECT COUNT(*) FROM dbo.t_app_applications ac
         WHERE ac.JobId = j.JobId AND ac.Is_Deleted = 0)                AS ApplicationCount,

        CASE WHEN @TeacherId IS NOT NULL AND EXISTS (
                SELECT 1 FROM dbo.t_app_applications ap
                WHERE ap.JobId = j.JobId AND ap.TeacherId = @TeacherId AND ap.Is_Deleted = 0)
             THEN CAST(1 AS tinyint) ELSE CAST(0 AS tinyint) END        AS HasApplied,

        CASE WHEN @TeacherId IS NOT NULL AND EXISTS (
                SELECT 1 FROM dbo.t_app_saved_jobs sj
                WHERE sj.JobId = j.JobId AND sj.TeacherId = @TeacherId AND sj.Is_Deleted = 0)
             THEN CAST(1 AS tinyint) ELSE CAST(0 AS tinyint) END        AS IsSaved,

        j.Is_Active AS IsActive          -- 🔴 2.61
    FROM dbo.t_app_jobs j
        INNER JOIN dbo.t_app_schools s         ON s.SchoolId = j.SchoolId
        INNER JOIN dbo.t_app_school_branches b ON b.BranchId = j.BranchId
    WHERE j.Is_Deleted   = 0
      AND j.Is_Active    = 1
      AND j.JobStatusId  = 2                                            -- the seek
      AND dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) = 2   -- the date
      AND s.Is_Deleted   = 0 AND s.Is_Active = 1 AND s.IsSuspended = 0
      AND b.Is_Deleted   = 0
      AND (@SubjectId        IS NULL OR j.SubjectId        = @SubjectId
           OR EXISTS (SELECT 1 FROM dbo.t_app_job_subjects js
                      WHERE js.JobId = j.JobId AND js.SubjectId = @SubjectId AND js.Is_Deleted = 0))
      AND (@DesignationId    IS NULL OR j.DesignationId    = @DesignationId)
      AND (@EmploymentTypeId IS NULL OR j.EmploymentTypeId = @EmploymentTypeId)
      AND (@CityId           IS NULL OR j.CityId           = @CityId)
      AND (@StateId          IS NULL OR j.StateId          = @StateId)
      AND (@MinSalary        IS NULL OR j.SalaryMax IS NULL OR j.SalaryMax >= @MinSalary)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = ''
           OR j.JobTitle  LIKE '%' + @Search + '%'
           OR s.SchoolName LIKE '%' + @Search + '%')
    ORDER BY j.PublishedOn DESC, j.JobId DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;

    /*
      The total, under the SAME predicate. Written out rather than factored
      into a CTE because a CTE reused for both would be evaluated twice anyway,
      and the duplication is at least visible — 2.30's rule for list procedures.
    */
    SELECT COUNT_BIG(*) AS TotalRecords
    FROM dbo.t_app_jobs j
        INNER JOIN dbo.t_app_schools s         ON s.SchoolId = j.SchoolId
        INNER JOIN dbo.t_app_school_branches b ON b.BranchId = j.BranchId
    WHERE j.Is_Deleted   = 0
      AND j.Is_Active    = 1
      AND j.JobStatusId  = 2
      AND dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) = 2
      AND s.Is_Deleted   = 0 AND s.Is_Active = 1 AND s.IsSuspended = 0
      AND b.Is_Deleted   = 0
      AND (@SubjectId        IS NULL OR j.SubjectId        = @SubjectId
           OR EXISTS (SELECT 1 FROM dbo.t_app_job_subjects js
                      WHERE js.JobId = j.JobId AND js.SubjectId = @SubjectId AND js.Is_Deleted = 0))
      AND (@DesignationId    IS NULL OR j.DesignationId    = @DesignationId)
      AND (@EmploymentTypeId IS NULL OR j.EmploymentTypeId = @EmploymentTypeId)
      AND (@CityId           IS NULL OR j.CityId           = @CityId)
      AND (@StateId          IS NULL OR j.StateId          = @StateId)
      AND (@MinSalary        IS NULL OR j.SalaryMax IS NULL OR j.SalaryMax >= @MinSalary)
      AND (@Search IS NULL OR LTRIM(RTRIM(@Search)) = ''
           OR j.JobTitle  LIKE '%' + @Search + '%'
           OR s.SchoolName LIKE '%' + @Search + '%');
END
GO


/*==============================================================================
  USP_GetJobForTeacher — one job, as an applicant sees it.

  🔴 THE SAME ACTIVE-ONLY RULE AS THE BROWSE, AND FOR A SHARPER REASON. This is
  the URL somebody bookmarks, mails to a friend, or opens from a month-old
  notification. An expired posting must return nothing here — the same answer a
  job that never existed gives — rather than a page with an Apply button that
  the server will refuse.

  ⚠️ NOT the school's USP_GetJobById. That one is scoped to the owning school
  and returns drafts and closed jobs; this one is scoped to "published and
  still open" and returns the school's public face alongside it. One procedure
  with an audience flag would eventually show a draft to a teacher.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetJobForTeacher
    @JobId    bigint,
    @UserUid  uniqueidentifier = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TeacherId bigint = NULL;

    IF @UserUid IS NOT NULL
        SELECT @TeacherId = t.TeacherId
        FROM dbo.t_app_teachers t
        WHERE t.UserUid = @UserUid AND t.Is_Deleted = 0 AND t.Is_Active = 1 AND t.IsSuspended = 0;

    SELECT
        j.JobId,
        j.JobUid,
        j.JobTitle,
        j.SubjectId,
        j.DesignationId,
        j.QualificationId,
        j.EmploymentTypeId,
        j.NoOfVacancies,
        j.MinExperienceMonths,
        j.MaxExperienceMonths,
        j.SalaryMin,
        j.SalaryMax,
        j.IsSalaryNegotiable,
        j.CityId,
        j.StateId,
        j.WorkingDays,
        j.TimingFrom,
        j.TimingTo,
        j.LastDateToApply,
        j.ExpectedJoiningDate,
        j.JobDescription,
        j.PublishedOn,

        s.SchoolUid,                      -- 🔴 never SchoolId (2.39)
        s.SchoolName,
        s.LogoPath   AS SchoolLogoPath,
        s.AboutSchool,
        s.IsVerified AS IsSchoolVerified,
        b.BranchName,
        b.CityId     AS BranchCityId,
        b.StateId    AS BranchStateId,

        (SELECT COUNT(*) FROM dbo.t_app_applications ac
         WHERE ac.JobId = j.JobId AND ac.Is_Deleted = 0)                AS ApplicationCount,

        CASE WHEN @TeacherId IS NOT NULL AND EXISTS (
                SELECT 1 FROM dbo.t_app_applications ap
                WHERE ap.JobId = j.JobId AND ap.TeacherId = @TeacherId AND ap.Is_Deleted = 0)
             THEN CAST(1 AS tinyint) ELSE CAST(0 AS tinyint) END        AS HasApplied,

        CASE WHEN @TeacherId IS NOT NULL AND EXISTS (
                SELECT 1 FROM dbo.t_app_saved_jobs sj
                WHERE sj.JobId = j.JobId AND sj.TeacherId = @TeacherId AND sj.Is_Deleted = 0)
             THEN CAST(1 AS tinyint) ELSE CAST(0 AS tinyint) END        AS IsSaved,

        j.Is_Active AS IsActive          -- 🔴 2.61
    FROM dbo.t_app_jobs j
        INNER JOIN dbo.t_app_schools s         ON s.SchoolId = j.SchoolId
        INNER JOIN dbo.t_app_school_branches b ON b.BranchId = j.BranchId
    WHERE j.JobId        = @JobId
      AND j.Is_Deleted   = 0
      AND j.Is_Active    = 1
      AND j.JobStatusId  = 2
      AND dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) = 2
      AND s.Is_Deleted   = 0 AND s.Is_Active = 1 AND s.IsSuspended = 0
      AND b.Is_Deleted   = 0;

    -- The sets a teacher matches themselves against.
    SELECT js.SubjectId FROM dbo.t_app_job_subjects js
    WHERE js.JobId = @JobId AND js.Is_Deleted = 0;

    SELECT jc.ClassLevelId FROM dbo.t_app_job_class_levels jc
    WHERE jc.JobId = @JobId AND jc.Is_Deleted = 0;
END
GO


/*==============================================================================
  USP_GetMyApplications — the teacher's own list.

  ---------------------------------------------------------------------------
  🔴 TeacherFacingName, AND NO RejectionReason. EVER.
  ---------------------------------------------------------------------------
  The teacher sees "Not selected". The school's own note on why is stored on
  the row and is not in this SELECT — absent rather than blanked, because a
  column that is present and empty is one somebody populates later.

  ⚠️ st.Name is deliberately NOT returned either. Returning both names would
  put "Rejected" on the wire next to "Not selected" and leave the choice to a
  screen, which is exactly the decision this master column exists to take away
  from screens (023).

  🔴 The teacher is resolved from @UserUid inside the procedure. There is no
  parameter for whose list it is, so "somebody else's applications" cannot be
  expressed — the 3D property, held.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetMyApplications
    @UserUid    uniqueidentifier,
    @StatusId   int = NULL,
    @Top        int = 200
AS
BEGIN
    SET NOCOUNT ON;

    SELECT TOP (@Top)
        a.ApplicationId,
        a.ApplicationUid,

        a.JobId,
        j.JobUid,
        j.JobTitle,
        j.SubjectId,
        j.DesignationId,
        j.EmploymentTypeId,
        j.SalaryMin,
        j.SalaryMax,
        j.IsSalaryNegotiable,
        j.LastDateToApply,

        -- 🔴 What the job EFFECTIVELY is now. A teacher's list showing
        -- "Active" for a posting that closed last week is a lie by omission.
        dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) AS JobStatusId,

        s.SchoolUid,                      -- 🔴 never SchoolId (2.39)
        s.SchoolName,
        s.LogoPath AS SchoolLogoPath,
        b.BranchName,
        b.CityId   AS BranchCityId,
        b.StateId  AS BranchStateId,

        a.ApplicationStatusId,
        -- 🔴 The teacher's word for it, and the ONLY one on this row.
        st.TeacherFacingName AS StatusName,

        a.AppliedOn,
        a.ViewedOn,
        a.CoverNote,

        CASE WHEN a.ResumePathSnapshot IS NULL THEN CAST(0 AS tinyint)
             ELSE CAST(1 AS tinyint) END AS HasResume,

        a.Is_Active AS IsActive          -- 🔴 2.61
    FROM dbo.t_app_applications a
        INNER JOIN dbo.t_app_teachers t        ON t.TeacherId = a.TeacherId
        INNER JOIN dbo.t_app_jobs j            ON j.JobId     = a.JobId
        INNER JOIN dbo.t_app_schools s         ON s.SchoolId  = a.SchoolId
        INNER JOIN dbo.t_app_school_branches b ON b.BranchId  = a.BranchId
        INNER JOIN dbo.m_app_application_status st ON st.ApplicationStatusId = a.ApplicationStatusId
    WHERE t.UserUid    = @UserUid
      AND t.Is_Deleted = 0
      AND a.Is_Deleted = 0
      AND (@StatusId IS NULL OR a.ApplicationStatusId = @StatusId)
    ORDER BY a.AppliedOn DESC, a.ApplicationId DESC;
END
GO


/*==============================================================================
  USP_GetMyApplicationById — one of the teacher's own applications.

  ⚠️ Takes @ApplicationId AND @UserUid, and matches both. Another teacher's id
  resolves to zero rows, which the API answers 404 for — the same status a row
  that never existed gets (2.6). This is the child-row rule 3D established for
  experiences and documents, applied to an application.

  🔴 The history here carries NO Remarks and NO actor. The remarks are the
  school's internal note (this file's header), and which colleague pressed the
  button is the school's business. What the teacher gets is the shape of their
  own journey: when it was seen, when it moved, and to what — in their words.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetMyApplicationById
    @UserUid        uniqueidentifier,
    @ApplicationId  bigint
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        a.ApplicationId,
        a.ApplicationUid,

        a.JobId,
        j.JobUid,
        j.JobTitle,
        j.SubjectId,
        j.DesignationId,
        j.QualificationId,
        j.EmploymentTypeId,
        j.NoOfVacancies,
        j.MinExperienceMonths,
        j.MaxExperienceMonths,
        j.SalaryMin,
        j.SalaryMax,
        j.IsSalaryNegotiable,
        j.WorkingDays,
        j.TimingFrom,
        j.TimingTo,
        j.LastDateToApply,
        j.ExpectedJoiningDate,
        j.JobDescription,
        dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) AS JobStatusId,

        s.SchoolUid,
        s.SchoolName,
        s.LogoPath AS SchoolLogoPath,
        b.BranchName,
        b.CityId   AS BranchCityId,
        b.StateId  AS BranchStateId,

        a.ApplicationStatusId,
        st.TeacherFacingName AS StatusName,     -- 🔴 never st.Name
        a.AppliedOn,
        a.ViewedOn,
        a.CoverNote,

        CASE WHEN a.ResumePathSnapshot IS NULL THEN CAST(0 AS tinyint)
             ELSE CAST(1 AS tinyint) END AS HasResume,

        a.Is_Active AS IsActive          -- 🔴 2.61
    FROM dbo.t_app_applications a
        INNER JOIN dbo.t_app_teachers t        ON t.TeacherId = a.TeacherId
        INNER JOIN dbo.t_app_jobs j            ON j.JobId     = a.JobId
        INNER JOIN dbo.t_app_schools s         ON s.SchoolId  = a.SchoolId
        INNER JOIN dbo.t_app_school_branches b ON b.BranchId  = a.BranchId
        INNER JOIN dbo.m_app_application_status st ON st.ApplicationStatusId = a.ApplicationStatusId
    WHERE a.ApplicationId = @ApplicationId
      AND t.UserUid       = @UserUid
      AND t.Is_Deleted    = 0
      AND a.Is_Deleted    = 0;

    -- The journey, in the teacher's words. No Remarks, no actor.
    SELECT
        h.ToStatusId,
        ts.TeacherFacingName AS StatusName,
        h.ChangedOn
    FROM dbo.t_app_application_status_history h
        INNER JOIN dbo.t_app_applications a ON a.ApplicationId = h.ApplicationId
        INNER JOIN dbo.t_app_teachers t     ON t.TeacherId     = a.TeacherId
        INNER JOIN dbo.m_app_application_status ts ON ts.ApplicationStatusId = h.ToStatusId
    WHERE h.ApplicationId = @ApplicationId
      AND t.UserUid       = @UserUid
      AND t.Is_Deleted    = 0
      AND a.Is_Deleted    = 0
      AND h.Is_Deleted    = 0
    ORDER BY h.ChangedOn, h.HistoryId;
END
GO


/*==============================================================================
  USP_GetMySavedJobs — the teacher's private shortlist.

  🔴 PRIVATE. Nothing in this result set reaches a school, and a saved row must
  never appear in any question fn_TeacherContactUnlocked asks (024). Saving is
  interest; applying is consent.

  ⚠️ A saved job that has since EXPIRED or CLOSED is still returned, with its
  effective status, rather than silently disappearing. The teacher put it
  there; telling them it closed is information, and removing it without a word
  looks like the feature losing their data.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetMySavedJobs
    @UserUid uniqueidentifier,
    @Top     int = 200
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TeacherId bigint;

    SELECT @TeacherId = t.TeacherId
    FROM dbo.t_app_teachers t
    WHERE t.UserUid = @UserUid AND t.Is_Deleted = 0;

    SELECT TOP (@Top)
        sj.Id AS SavedJobId,
        sj.SavedOn,

        j.JobId,
        j.JobUid,
        j.JobTitle,
        j.SubjectId,
        j.DesignationId,
        j.EmploymentTypeId,
        j.SalaryMin,
        j.SalaryMax,
        j.IsSalaryNegotiable,
        j.CityId,
        j.StateId,
        j.LastDateToApply,

        -- 🔴 Effective, so a saved posting that has closed says so.
        dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) AS JobStatusId,

        s.SchoolUid,
        s.SchoolName,
        s.LogoPath AS SchoolLogoPath,
        b.BranchName,

        CASE WHEN EXISTS (
                SELECT 1 FROM dbo.t_app_applications ap
                WHERE ap.JobId = j.JobId AND ap.TeacherId = @TeacherId AND ap.Is_Deleted = 0)
             THEN CAST(1 AS tinyint) ELSE CAST(0 AS tinyint) END AS HasApplied,

        sj.Is_Active AS IsActive          -- 🔴 2.61
    FROM dbo.t_app_saved_jobs sj
        INNER JOIN dbo.t_app_jobs j            ON j.JobId    = sj.JobId
        INNER JOIN dbo.t_app_schools s         ON s.SchoolId = j.SchoolId
        INNER JOIN dbo.t_app_school_branches b ON b.BranchId = j.BranchId
    WHERE sj.TeacherId  = @TeacherId
      AND sj.Is_Deleted = 0
      AND j.Is_Deleted  = 0
    ORDER BY sj.SavedOn DESC, sj.Id DESC;
END
GO


/*==============================================================================
  USP_GetTeacherApplicationStats — the teacher dashboard's applications area.

  Like the school's, 3I left this an honest not-yet empty state because there
  was nothing to count (2.62). There is now.

  ⚠️ The counts are keyed by status id, and the SCREEN decides what to call
  them — it has TeacherFacingName from the master for that. Naming them here
  would be a third place the teacher-facing wording lives.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetTeacherApplicationStats
    @UserUid   uniqueidentifier,
    @RecentTop int = 5
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TeacherId bigint;

    SELECT @TeacherId = t.TeacherId
    FROM dbo.t_app_teachers t
    WHERE t.UserUid = @UserUid AND t.Is_Deleted = 0;

    SELECT
        COUNT(*)                                                                AS TotalApplications,
        ISNULL(SUM(CASE WHEN a.ApplicationStatusId = 1 THEN 1 ELSE 0 END), 0)   AS AppliedCount,
        ISNULL(SUM(CASE WHEN a.ApplicationStatusId = 2 THEN 1 ELSE 0 END), 0)   AS ViewedCount,
        ISNULL(SUM(CASE WHEN a.ApplicationStatusId = 3 THEN 1 ELSE 0 END), 0)   AS ShortlistedCount,
        ISNULL(SUM(CASE WHEN a.ApplicationStatusId = 4 THEN 1 ELSE 0 END), 0)   AS InterviewCount,
        ISNULL(SUM(CASE WHEN a.ApplicationStatusId = 5 THEN 1 ELSE 0 END), 0)   AS SelectedCount,
        ISNULL(SUM(CASE WHEN a.ApplicationStatusId = 6 THEN 1 ELSE 0 END), 0)   AS RejectedCount,

        (SELECT COUNT(*) FROM dbo.t_app_saved_jobs sj
         WHERE sj.TeacherId = @TeacherId AND sj.Is_Deleted = 0)                 AS SavedJobCount
    FROM dbo.t_app_applications a
    WHERE a.TeacherId = @TeacherId AND a.Is_Deleted = 0;

    SELECT TOP (@RecentTop)
        a.ApplicationId,
        a.ApplicationUid,
        a.JobId,
        j.JobTitle,
        s.SchoolUid,
        s.SchoolName,
        s.LogoPath AS SchoolLogoPath,
        a.ApplicationStatusId,
        st.TeacherFacingName AS StatusName,     -- 🔴 never st.Name
        a.AppliedOn,
        a.ViewedOn
    FROM dbo.t_app_applications a
        INNER JOIN dbo.t_app_jobs j    ON j.JobId    = a.JobId
        INNER JOIN dbo.t_app_schools s ON s.SchoolId = a.SchoolId
        INNER JOIN dbo.m_app_application_status st ON st.ApplicationStatusId = a.ApplicationStatusId
    WHERE a.TeacherId = @TeacherId AND a.Is_Deleted = 0
    ORDER BY a.AppliedOn DESC, a.ApplicationId DESC;
END
GO

PRINT '    Application read procedures ready.';
GO
