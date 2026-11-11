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

  ---------------------------------------------------------------------------
  🔴 P5. ONE CANDIDATE SET, BUILT ONCE, READ TWICE — AND THAT IS THE WHOLE
     POINT OF THIS PROCEDURE'S SHAPE
  ---------------------------------------------------------------------------
  This used to be two SELECTs repeating one WHERE clause: the page, then
  COUNT_BIG(*) "under the SAME predicate", kept in step by eye. P5 adds a
  qualification filter, three mode variants and a keyword to that predicate —
  and a companion procedure that counts all three variants. Written the old way
  that is FIVE copies of one predicate across two files, agreeing by eye.

  🔴 This project has already shipped one number that drifted from the rows
  under it. t_app_jobs.ApplicationCount is deliberately dead and re-derived on
  every read (024, and rule 3 at the top of this file) precisely because a
  maintained tally stops matching reality and nothing errors when it does. Five
  hand-kept copies of a predicate is that same bug wearing a different hat.

  So the predicate is written ONCE, into @Candidates, and everything else
  reads that table:

      the page       ->  JOIN @Candidates
      TotalRecords   ->  COUNT_BIG(*) FROM @Candidates
      the tab counts ->  SUM of its three bit columns (USP_BrowseJobCounts)

  🔴 SO TotalRecords CANNOT DISAGREE WITH THE PAGE: it is the row count of the
  exact set the page is a window onto, not a second evaluation of the same rule.
  The mode is applied by DELETING what the tab does not show, so even the mode
  cannot be applied to one and not the other.

  ⚠️ THE COST, HONESTLY. This materialises every matching JobId before paging,
  where the old shape could in principle have satisfied a page from an index
  alone. But it could not in practice: the second SELECT already counted every
  match on every call. So the trade is one materialisation instead of two
  evaluations, and at this product's scale — open postings in the hundreds — it
  is not close. If open jobs ever reach six figures, the thing to revisit is
  paging the predicate inline and accepting a second evaluation for the count.
  Measured, not guessed.

  ---------------------------------------------------------------------------
  🔴 P5. THE THREE MODES. @Mode IS A CODE, NOT A NUMBER.
  ---------------------------------------------------------------------------
      MATCHES     the strict match — the teacher's subjects AND class levels AND
                  qualification AND state. All four.
      MIGHT_LIKE  the loose match — ANY of their subjects, class levels or saved
                  preferred locations, MINUS everything MATCHES returns.
      PREFERRED   jobs in the teacher's saved preferred locations.

  NULL or '' is "no mode": the plain browse that existed before this phase, so
  every existing caller keeps working untouched — the same courtesy the SR-5
  table parameters were given.

  ⚠️ A CODE RATHER THAN A SMALL INT, DELIBERATELY. The value travels through a
  query string, a log line and a profiler trace; `MIGHT_LIKE` says what it is in
  all three and `2` says nothing in any of them. An int would also want a master
  table to be legible, and this is a QUERY SHAPE rather than reference data — so
  that table would carry rows nobody administers. The project already prefers
  codes for exactly this (m_app_application_status.Code is "the stable contract
  a client branches on", 2.47 / 2.21).

  🔴 AN UNKNOWN MODE RAISES. It does not fall back to "no mode". The fallback
  would put the ENTIRE job market under a tab labelled "Matches your profile
  (812)" — which is the precise failure JobBrowseFilter's int[] remark exists to
  prevent: an empty set means "do not filter", so a filter that silently stops
  filtering LIES rather than breaking. Loud, like USP_GetJobForTeacher's
  two-ids guard, and for the same reason: a caller bug that would otherwise look
  like a legitimate answer.

  ⚠️ @Mode IS THIS PROCEDURE'S ALONE. USP_BrowseJobCounts has no such parameter
  and must not grow one: one row of three counts answers all three tabs, so
  passing the tab currently open would be asking "how many are in each tab,
  given we are only looking at this one". That is also why the normalisation and
  the validation live HERE rather than in the shared block below.

  ⚠️ THE ORDERING IS THE SAME IN EVERY MODE WITH ONE ADDITION: in PREFERRED,
  jobs are ordered by the teacher's own PreferenceOrder first, so their
  first-choice place leads the tab named after it. Argued at the ORDER BY.

  ---------------------------------------------------------------------------
  🔴 THE EMPTY-SET IDIOM IS USED IN THE CONJUNCTION AND REFUSED IN THE
     DISJUNCTION. THE ASYMMETRY IS LOAD-BEARING.
  ---------------------------------------------------------------------------
  `NOT EXISTS (SELECT 1 FROM @Ids) OR <membership>` means "an empty set does not
  narrow". Correct inside MATCHES: a conjunct we know nothing about simply stops
  narrowing, which is also what an omitted READONLY TVP gives us.

  ⚠️ The SAME idiom inside MIGHT_LIKE's OR-arms would read "an empty set matches
  EVERYTHING", and one empty set would drag the whole market into that tab. So
  the loose arms are bare EXISTS. Do not tidy the two shapes into one.

  ---------------------------------------------------------------------------
  🔴 MIGHT_LIKE SUBTRACTS MATCHES IN SQL, NOT IN THE CLIENT
  ---------------------------------------------------------------------------
      IsMightLike = (AnySubject OR AnyLevel OR AnyLocation) AND NOT IsMatch

  IsMatch is computed once and the subtraction reads that one column, so "never
  in both tabs" is true by construction rather than by two expressions agreeing.
  A client could not do it at all: it sees one page of one tab and cannot know
  what the other tab's later pages hold.

  ⚠️ BOTH TABS RUN OFF THE SAME @SubjectIds / @ClassLevelIds THE CALLER SENT.
  That is what makes the subtraction exact. If MIGHT_LIKE resolved the teacher's
  subjects from their profile while MATCHES used the caller's sets, the two
  would be computed from different inputs and a job could land in both.

  ⚠️ PREFERRED DELIBERATELY OVERLAPS BOTH AND IS SUBTRACTED FROM NOTHING. "What
  work suits me" and "where am I willing to live" are different questions.
  Subtracting MATCHES from PREFERRED would hide a teacher's best possible job —
  right subject, right city — from the tab named after the city they chose. 🔴 So
  the three counts DO NOT SUM TO A TOTAL and no screen may add them up.

  🔴 A JOB MATCHING NOTHING IS IN NO TAB. With a populated profile, a job that
  hits none of the subjects, none of the levels, the wrong qualification, the
  wrong state and no preferred location carries IsMatch 0, IsMightLike 0 and
  IsPreferred 0, and all three tabs omit it. It stays reachable in the unmoded
  browse and by keyword, which is right: it exists, it is simply not being
  recommended.

  ⚠️ AN EMPTY PROFILE IS THE ONE HONEST EXCEPTION, AND IT IS NOT A LOOPHOLE. A
  teacher who sends no subjects, no class levels and no qualification, and who
  has saved no locations, has no criterion to fail: every conjunct stops
  narrowing, so MATCHES is the whole open market, MIGHT_LIKE is EMPTY (every
  loose arm contributes nothing) and PREFERRED is EMPTY. That is the right
  answer — the alternative, an empty Matches tab, is a blank job board on the
  first screen a brand-new teacher ever sees.

  🔴 If the product wants "Matches (0)" until a profile exists, that belongs to
  the SCREEN — do not offer the tab yet — and not to this predicate. The server
  cannot tell "this teacher has no subjects" from "this caller sent none", and
  inventing that difference here would change what an empty TVP means for every
  other caller of this procedure.

  ---------------------------------------------------------------------------
  🔴 P4. HOW A JOB EXPRESSES ITS REQUIRED QUALIFICATION
  ---------------------------------------------------------------------------
  A single nullable COLUMN, not a child table:

      t_app_jobs.QualificationId   int   NULL      -- 022_t_app_jobs.sql

  There is no t_app_job_qualifications bridge anywhere in the schema — subjects
  and class levels have one (t_app_job_subjects, t_app_job_class_levels),
  qualification does not. The predicate is therefore a plain column test with no
  "OR the bridge" arm beside it, and a NULL is treated as "requires nothing of
  you". Both decisions are argued at the predicate itself.

  ---------------------------------------------------------------------------
  @Keyword, @Search, AND THE INDEX A LEADING WILDCARD CANNOT USE
  ---------------------------------------------------------------------------
  ⚠️ @Search ALREADY DID THIS LIKE, so @Keyword did NOT get a second one. They
  are coalesced into one local and there is exactly one search predicate, so
  there is nothing for two to drift apart over. @Keyword is the name the API
  contract asked for; @Search is the name the existing caller sends; both work.

  The sargability cost is stated where the predicate is written, along with why
  no index was added for it.

  ---------------------------------------------------------------------------
  🔴 THE COUNTS ARE A SEPARATE PROCEDURE AND A GUARDED COPY, NOT A SECOND
     OPINION — see USP_BrowseJobCounts immediately below, and the build guard at
     the foot of this file that fails the build if the two drift.
  ---------------------------------------------------------------------------
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_BrowseJobs
    @UserUid           uniqueidentifier = NULL,
    @Search            nvarchar(150)    = NULL,

    /*--------------------------------------------------------------------------
      P5. THE KEYWORD AND THE MODE.

      ⚠️ ADDED, NOT REPLACING. @Search keeps working and is folded into the same
      single LIKE; @Mode NULL is the unmoded browse every existing caller
      already performs. Nothing a current caller passes changes meaning.
    --------------------------------------------------------------------------*/
    @Keyword           nvarchar(150)    = NULL,
    @Mode              varchar(16)      = NULL,   -- MATCHES | MIGHT_LIKE | PREFERRED | NULL

    @SubjectId         int              = NULL,
    @DesignationId     int              = NULL,
    @EmploymentTypeId  int              = NULL,
    @CityId            int              = NULL,
    @StateId           int              = NULL,
    @MinSalary         decimal(18, 2)   = NULL,
    @PageNumber        int              = 1,
    @PageSize          int              = 20,

    /*--------------------------------------------------------------------------
      SR-5 / P4. THE TEACHER'S OWN SUBJECTS, CLASS LEVELS AND QUALIFICATIONS,
      AS SETS.

      The client asked that a teacher opening the job list sees work matching
      THEIR subjects and THEIR class levels — plural in both cases. A maths and
      physics teacher of classes 9-12 teaches two subjects and four levels, and
      the singular @SubjectId above can only ever express one of them.

      @QualificationIds joins them in P4. The job side is singular (one nullable
      column), but the TEACHER side is the set that may grow — somebody holding
      a B.Ed and an M.A. has two — so the parameter is a set from the start
      rather than a scalar that has to be widened later under live callers.

      ⚠️ ADDED, NOT REPLACED. @SubjectId stays exactly as it was, because the
      manual single-subject filter and every existing caller still use it, and
      changing a parameter's meaning under callers that pass it is how a read
      starts answering a different question than the one asked.

      ⚠️ A READONLY TABLE PARAMETER MAY BE OMITTED ENTIRELY — SQL Server gives
      the procedure an empty table. So every existing caller keeps working
      untouched, and "empty" and "not filtering" are the same state, which is
      what the NOT EXISTS predicates rely on.
    --------------------------------------------------------------------------*/
    @SubjectIds        dbo.IntIdList    READONLY,
    @ClassLevelIds     dbo.IntIdList    READONLY,
    @QualificationIds  dbo.IntIdList    READONLY
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize   IS NULL OR @PageSize   < 1 SET @PageSize   = 20;
    IF @PageSize > 200 SET @PageSize = 200;

    /*
      ---------------------------------------------------------------------
      THE MODE, NORMALISED AND THEN VALIDATED. THE LIST'S BUSINESS ONLY.
      ---------------------------------------------------------------------
      ⚠️ 'might-like' -> 'MIGHT_LIKE'. Lifted from USP_GetMaster, which
      normalises the same way and for the same reason it had to learn to: the
      client sends a URL segment, which is kebab, and the codes here are
      SQL-ish. 2.49 is the incident — SCHOOL-TYPE matched no branch, returned
      200 with no rows, and was found weeks later by a human noticing a blank
      dropdown.

      🔴 AND THEN IT RAISES ON ANYTHING ELSE, rather than falling back. See the
      header: a mode that quietly becomes "no mode" shows the whole market under
      a tab that claims to be a match.
    */
    DECLARE @EffMode varchar(16) = NULLIF(LTRIM(RTRIM(ISNULL(@Mode, ''))), '');

    IF @EffMode IS NOT NULL
        SET @EffMode = UPPER(REPLACE(@EffMode, '-', '_'));

    IF @EffMode IS NOT NULL AND @EffMode NOT IN ('MATCHES', 'MIGHT_LIKE', 'PREFERRED')
    BEGIN
        RAISERROR('USP_BrowseJobs: @Mode must be MATCHES, MIGHT_LIKE or PREFERRED (kebab-case accepted), or NULL for an unmoded browse. A mode this procedure does not know is a CALLER BUG, and it RAISES rather than falling back to "no mode" — because falling back would put the entire job market under a tab labelled "Matches your profile".', 16, 1);
        RETURN;
    END

    -- >>> SHARED CANDIDATE CLASSIFICATION - BEGIN
    /*
      🔴 EVERYTHING BETWEEN THESE TWO MARKERS IS BYTE-FOR-BYTE IDENTICAL IN
      USP_BrowseJobs AND USP_BrowseJobCounts, AND A BUILD GUARD AT THE FOOT OF
      THIS FILE FAILS THE BUILD THE MOMENT IT STOPS BEING.

      That guard is the real answer to "how do the counts and the list stay in
      step?" — not "they were copied carefully", but: they are compared, on
      every build, out of sys.sql_modules. If you change one of these blocks,
      change the other by COPYING it. Anything else, down to a renamed alias,
      is a failed build with a message naming the procedure you forgot.

      ⚠️ DO NOT FACTOR THIS INTO A FUNCTION INSTEAD. A user-defined function
      cannot take a table-valued parameter, and @SubjectIds, @ClassLevelIds and
      @QualificationIds are TVPs. That is the actual reason this is a guarded
      duplicate rather than one callable definition, and it was checked rather
      than assumed.

      ⚠️ THE MODE IS NOT DECIDED IN HERE. @Mode belongs to the LIST procedure
      alone — the counts procedure has no such parameter, because one row of
      three counts answers all three tabs at once. What IS in here is the
      keyword override, so that a keyword cannot neutralise the mode on the
      list side while the counts side carries on classifying.
    */

    /*
      ONE search term, two accepted spellings. @Keyword is the name the API
      contract asked for; @Search is the name every existing caller already
      sends, and it has done this exact LIKE since Phase 5. Coalesced here so
      there is exactly ONE search predicate below and nothing for a second one
      to drift from. A caller sending both gets @Keyword.
    */
    DECLARE @Needle nvarchar(150) = COALESCE(
        NULLIF(LTRIM(RTRIM(@Keyword)), N''),
        NULLIF(LTRIM(RTRIM(@Search)),  N''));

    /*
      ---------------------------------------------------------------------
      🔴 WHOSE LISTS AND WHOSE SAVED LOCATIONS: RESOLVED HERE, FROM THE TOKEN
      ---------------------------------------------------------------------
      @TeacherId is a LOCAL, derived from @UserUid. Neither procedure has a
      teacher-id PARAMETER and neither may ever grow one, so "read somebody
      else's preferred locations" is not expressible — there is no slot to put
      another teacher's id in. That is the 3D property this file's header
      describes for USP_GetMyApplications, applied to a table that has never
      had a reader on this surface before.

      ⚠️ A NULL @UserUid — the signed-out browse the header mentions — leaves
      both locals NULL, which turns the per-card flags off, makes every
      preferred-location test false, and stops the state conjunct narrowing
      anything. It does NOT fall back to "everybody's preferences".

      🔴 @ProfileStateId IS THE TEACHER'S OWN STATE, READ FROM THEIR OWN ROW,
      and it is the state MATCHES is measured against. There is no request
      field a client could set instead — the rule every identity value in this
      file follows (2.39). @StateId is a different thing and keeps its old
      meaning: the toolbar's state filter, applied to all three modes.

      ⚠️ The suspension and soft-delete tests are the same ones
      USP_GetTeacherIdForUser applies. A suspended teacher resolves to nothing
      here too, so their browse degrades to the signed-out shape rather than
      quietly keeping its personalisation.
    */
    DECLARE @TeacherId bigint = NULL, @ProfileStateId int = NULL;

    IF @UserUid IS NOT NULL
        SELECT @TeacherId = t.TeacherId, @ProfileStateId = t.CurrentStateId
        FROM dbo.t_app_teachers t
        WHERE t.UserUid = @UserUid AND t.Is_Deleted = 0 AND t.Is_Active = 1 AND t.IsSuspended = 0;

    /*
      ---------------------------------------------------------------------
      ⚠️ A TABLE VARIABLE RATHER THAN A #TEMP TABLE, AND THE REASON IS NOT
         TASTE
      ---------------------------------------------------------------------
      The usual objection to a table variable is cardinality: pre-2019 the
      optimiser assumed one row and picked plans to match. This file targets
      SQL Server 2019 at compatibility level 150, where TABLE VARIABLE DEFERRED
      COMPILATION gives it the real row count — so the objection does not apply
      on the platform this ships to.

      🔴 AND NOTHING ELSE IN THIS CODEBASE USES A #TEMP TABLE — not one
      procedure in jp_app, jp_mdm or jp_sso. That means 999_cross_file_guards'
      sweep, which CROSS APPLYs sys.dm_sql_referenced_entities over EVERY
      procedure in the database, has never been run against a module that owns
      one. A table variable is invisible to dependency metadata, so this change
      cannot be the one that makes a whole-build guard raise on a correct
      procedure. 024's header records exactly that kind of surprise — a guard
      failing a from-scratch build over code that was right.

      ⚠️ The trade: an INSERT into a table variable cannot go parallel. At this
      product's scale that is nothing, and it belongs in the same measurement
      as the paging note in the header if open jobs ever reach six figures.
    */
    DECLARE @Candidates TABLE
    (
        /*
          ⚠️ THE PRIMARY KEY IS NOT "AN INDEX I DID NOT MEASURE". It is the key
          of a variable that lives for one procedure call, and it is what the
          join back to t_app_jobs and the mode DELETE seek on. Nothing in this
          change adds an index to t_app_jobs, t_app_job_subjects or anything
          else that ships.
        */
        JobId          bigint    NOT NULL PRIMARY KEY CLUSTERED,
        PublishedOn    datetime2 NULL,
        IsMatch        bit       NOT NULL,
        IsMightLike    bit       NOT NULL,
        IsPreferred    bit       NOT NULL,

        /* The three set filters without the state — see SetsOk above. Unused
           by the counts reader, and carried there anyway so the two blocks
           between the SHARED markers stay byte-identical. */
        SetsOk         bit       NOT NULL,

        /*
          The BEST (lowest) PreferenceOrder among the teacher's saved locations
          that this job satisfies; NULL when it satisfies none.

          ⚠️ PreferenceOrder is a VALUE IN THE ROW, not a position in a result
          set, so it has to be carried here deliberately — it would not survive
          as "the order the join happened to return". It is what orders the
          PREFERRED tab, so a teacher's first-choice city leads their own tab.
        */
        PreferenceRank int       NULL
    );

    INSERT INTO @Candidates
        (JobId, PublishedOn, IsMatch, IsMightLike, IsPreferred, SetsOk, PreferenceRank)
    SELECT  f.JobId,
            f.PublishedOn,
            f.IsMatch,

            /*
              🔴 THE SUBTRACTION, IN SQL, ONCE. MIGHT_LIKE is the loose hit
              MINUS everything MATCHES already returns — and it reads the single
              IsMatch column computed one level down rather than restating the
              four-way conjunction. So "a job is never in both tabs" is true by
              construction, not by two expressions agreeing.

              It cannot be done in the client at all: a client sees one page of
              one tab and has no way to know what the other tab's later pages
              hold.
            */
            CAST(CASE WHEN f.IsLooseHit = 1 AND f.IsMatch = 0 THEN 1 ELSE 0 END AS bit),

            f.AnyLocation,
            f.SetsOk,
            f.BestPreference
    FROM (
        SELECT  m.JobId,
                m.PublishedOn,
                m.BestPreference,

                -- 🔴 MATCHES: subjects AND class levels AND qualification AND
                -- state. All four, ANDed, computed ONCE — here.
                CAST(CASE WHEN m.SubjectOk = 1 AND m.LevelOk = 1
                           AND m.QualOk = 1 AND m.StateOk = 1
                          THEN 1 ELSE 0 END AS bit)                          AS IsMatch,

                /*----------------------------------------------------------
                  🔴 THE SAME THREE SETS WITHOUT THE STATE — AND THIS COLUMN
                  EXISTS BECAUSE ITS ABSENCE WAS A LIVE REGRESSION.

                  An UNMODED browse (`@Mode` NULL) is the oldest contract this
                  procedure has: `?subjectIds=3&subjectIds=7` NARROWS the list,
                  full stop, with no tabs involved. When the modes were added,
                  the three set filters moved out of the WHERE clause and into
                  the classification above — so they stopped filtering anything
                  unless a mode asked for them, and `?subjectIds=999999` began
                  returning every open job.

                  Nothing was red: the sets still worked in every moded call,
                  which is all the new code exercised. `browse-sets.mjs` is what
                  caught it, on the first regression it had ever been part of.

                  ⚠️ IT DELIBERATELY EXCLUDES StateOk. The state is resolved
                  from the teacher's own row for MATCHES; an unmoded browse must
                  not be silently confined to where the caller happens to live.
                  That is the difference between a filter the caller asked for
                  and one nobody did.
                ----------------------------------------------------------*/
                CAST(CASE WHEN m.SubjectOk = 1 AND m.LevelOk = 1 AND m.QualOk = 1
                          THEN 1 ELSE 0 END AS bit)                          AS SetsOk,

                -- MIGHT_LIKE's raw side: ANY of subjects, class levels or saved
                -- preferred locations. ORed.
                CAST(CASE WHEN m.AnySubject = 1 OR m.AnyLevel = 1
                           OR m.BestPreference IS NOT NULL
                          THEN 1 ELSE 0 END AS bit)                          AS IsLooseHit,

                -- PREFERRED: "this job is somewhere I said I would work".
                CAST(CASE WHEN m.BestPreference IS NOT NULL
                          THEN 1 ELSE 0 END AS bit)                          AS AnyLocation
        FROM (
            SELECT  j.JobId,
                    j.PublishedOn,

                    /*----------------------------------------------------------
                      THE STRICT CONJUNCTS — "an empty set does not narrow".

                      ⚠️ `NOT EXISTS (SELECT 1 FROM @Ids) OR <membership>` is
                      the idiom an omitted READONLY TVP relies on: SQL Server
                      hands the procedure an EMPTY TABLE rather than NULL, and
                      empty means "not filtering on this". Keep it.

                      ⚠️ SUBJECTS MATCH THE PRIMARY COLUMN **OR** THE BRIDGE. A
                      job carries one primary subject and a set of others;
                      matching only the column would hide a physics job from a
                      physics teacher because physics was listed second.
                    ----------------------------------------------------------*/
                    CAST(CASE WHEN NOT EXISTS (SELECT 1 FROM @SubjectIds)
                                OR j.SubjectId IN (SELECT Id FROM @SubjectIds)
                                OR EXISTS (SELECT 1 FROM dbo.t_app_job_subjects js
                                           WHERE js.JobId = j.JobId AND js.Is_Deleted = 0
                                             AND js.SubjectId IN (SELECT Id FROM @SubjectIds))
                              THEN 1 ELSE 0 END AS bit)                      AS SubjectOk,

                    CAST(CASE WHEN NOT EXISTS (SELECT 1 FROM @ClassLevelIds)
                                OR EXISTS (SELECT 1 FROM dbo.t_app_job_class_levels jc
                                           WHERE jc.JobId = j.JobId AND jc.Is_Deleted = 0
                                             AND jc.ClassLevelId IN (SELECT Id FROM @ClassLevelIds))
                              THEN 1 ELSE 0 END AS bit)                      AS LevelOk,

                    /*
                      P4. QUALIFICATION IS A COLUMN ON THE JOB, NOT A BRIDGE —
                      t_app_jobs.QualificationId int NULL (022_t_app_jobs.sql).
                      There is no t_app_job_qualifications table anywhere in the
                      schema, which is why there is no "OR the bridge" arm here
                      beside the subject one.

                      🔴 A JOB WITH QualificationId NULL MATCHES EVERY SET. The
                      obvious spelling — a bare IN — is WRONG, because NULL
                      never satisfies IN: a posting that asks for no particular
                      degree would vanish from every teacher's matches the
                      moment they filtered on their own qualification. An
                      UNSTATED requirement is not an UNMET one.
                    */
                    CAST(CASE WHEN NOT EXISTS (SELECT 1 FROM @QualificationIds)
                                OR j.QualificationId IS NULL
                                OR j.QualificationId IN (SELECT Id FROM @QualificationIds)
                              THEN 1 ELSE 0 END AS bit)                      AS QualOk,

                    /*
                      ⚠️ STATE GETS THE OPPOSITE NULL TREATMENT, DELIBERATELY. A
                      job with StateId NULL is NOT a state match. Qualification
                      NULL means "we require nothing of you"; location NULL
                      means "we did not say where this is", and we must not
                      claim it is where the teacher lives. Two NULLs, two
                      meanings, two answers.

                      ⚠️ j.StateId, not b.StateId, because the existing @StateId
                      filter and 024's public search both read the job's own
                      column — taking the branch's here would make "in this
                      state" mean two different things on two tabs.
                    */
                    CAST(CASE WHEN @ProfileStateId IS NULL OR j.StateId = @ProfileStateId
                              THEN 1 ELSE 0 END AS bit)                      AS StateOk,

                    /*----------------------------------------------------------
                      THE LOOSE ARMS — "an empty set contributes NOTHING".

                      🔴 THE ASYMMETRY WITH THE CONJUNCTS ABOVE IS LOAD-BEARING
                      AND MUST NOT BE TIDIED AWAY. `NOT EXISTS (@Ids) OR ...`
                      inside a DISJUNCTION would read "an empty set matches
                      EVERYTHING", and one empty set would drag the whole job
                      market into the "You might like" tab. So these are bare
                      EXISTS with no escape clause.
                    ----------------------------------------------------------*/
                    CAST(CASE WHEN j.SubjectId IN (SELECT Id FROM @SubjectIds)
                                OR EXISTS (SELECT 1 FROM dbo.t_app_job_subjects js
                                           WHERE js.JobId = j.JobId AND js.Is_Deleted = 0
                                             AND js.SubjectId IN (SELECT Id FROM @SubjectIds))
                              THEN 1 ELSE 0 END AS bit)                      AS AnySubject,

                    CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.t_app_job_class_levels jc
                                           WHERE jc.JobId = j.JobId AND jc.Is_Deleted = 0
                                             AND jc.ClassLevelId IN (SELECT Id FROM @ClassLevelIds))
                              THEN 1 ELSE 0 END AS bit)                      AS AnyLevel,

                    /*
                      P5. THE TEACHER'S SAVED PREFERRED LOCATIONS — the first
                      read of t_app_teacher_preferred_locations on this surface,
                      so there is no precedent to copy and the reasoning is
                      written out in full.

                      🔴 SCOPED TO @TeacherId, WHICH CAME FROM THE TOKEN. See
                      the DECLARE above: there is no teacher-id parameter on
                      either procedure, so another teacher's locations cannot be
                      named. `@TeacherId IS NOT NULL` is inside the subquery on
                      purpose — without it, a signed-out browse would compare
                      TeacherId against NULL, which is never true, but the
                      intent would rest on an accident of three-valued logic
                      instead of being stated.

                      ⚠️ Is_Deleted = 0 AND Is_Active = 1, both. A preference
                      the teacher switched off is not a preference.

                      ---------------------------------------------------------
                      🔴 HOW CityId AND StateId COMBINE. THREE CASES, AND THEY
                         ARE NOT THE SAME STRENGTH OF CLAIM.
                      ---------------------------------------------------------
                      A row is (StateId NOT NULL, CityId nullable). So:

                        1. BOTH NAME A CITY, AND THEY ARE THE SAME CITY
                           -> a match, exactly. The narrow case, and the one
                              that must not be widened: treating every row as a
                              state match would hand the tab most of the state
                              and make "In places you want" meaningless.

                        2. THE PREFERENCE NAMES NO CITY — "anywhere in this
                           state". That is a REAL preference and not a
                           placeholder for one (016's header argues it at
                           length: the city dataset is unimported, the forms
                           degrade to state-only, and a teacher who genuinely
                           means the whole state should not have to list twelve
                           cities to say so). So it matches any job in that
                           state. Read as anything narrower, this row would
                           match nothing at all and today most rows look like
                           this.

                        3. THE JOB NAMES NO CITY. Symmetrically: the posting
                           declined to say which town, so the state is the
                           finest grain BOTH sides actually agree on, and the
                           job matches a city preference in that same state.
                           The alternative — requiring a city on both sides —
                           would hide state-only postings from every teacher who
                           answered the city question precisely, i.e. punish the
                           more careful answer.

                      ⚠️ AND THE STATE USED IN CASES 2 AND 3 IS THE ONE ON THE
                      PREFERENCE ROW, because m_mdm_city lives in jp_mdm and no
                      query here may join across databases (2.2). The row
                      carrying its own StateId beside its CityId is the only
                      reason this is answerable at all.

                      ⚠️ TehsilId ON THIS TABLE IS DELIBERATELY NOT READ, and
                      not because it was missed: t_app_jobs HAS NO TEHSIL
                      COLUMN — 036_alter_address_columns.sql says "t_app_jobs
                      DELIBERATELY GETS NOTHING" — so there is nothing on the
                      job side to compare it against. A tehsil-only preference
                      therefore degrades to its STATE through case 2, which is
                      WIDER than the teacher asked for. That is the honest
                      degradation: the alternative is a row that matches nothing
                      and a teacher who answered more precisely seeing an empty
                      tab. 🔴 If tehsil is ever added to t_app_jobs, this
                      predicate is one of the places that must learn about it.

                      ⚠️ MIN(PreferenceOrder) RATHER THAN EXISTS, so one
                      subquery answers both "does this job sit anywhere I want"
                      (NOT NULL) and "how high up my list is the best such
                      place". MIN over no rows is NULL, and PreferenceOrder is
                      NOT NULL, so no null-elimination warning can fire.
                    */
                    (SELECT MIN(p.PreferenceOrder)
                       FROM dbo.t_app_teacher_preferred_locations p
                      WHERE @TeacherId IS NOT NULL
                        AND p.TeacherId  = @TeacherId
                        AND p.Is_Deleted = 0
                        AND p.Is_Active  = 1
                        AND (j.CityId = p.CityId
                             OR ((p.CityId IS NULL OR j.CityId IS NULL)
                                 AND j.StateId = p.StateId)))                AS BestPreference

            FROM dbo.t_app_jobs j
                INNER JOIN dbo.t_app_schools s         ON s.SchoolId = j.SchoolId
                INNER JOIN dbo.t_app_school_branches b ON b.BranchId = j.BranchId
            WHERE j.Is_Deleted   = 0
              AND j.Is_Active    = 1
              AND j.JobStatusId  = 2                                          -- the seek
              AND dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) = 2   -- the date
              AND s.Is_Deleted   = 0 AND s.Is_Active = 1 AND s.IsSuspended = 0
              AND b.Is_Deleted   = 0

              /*
                THE TOOLBAR'S OWN FILTERS. These narrow EVERY mode, including a
                keyword search: somebody who set a salary floor and then typed a
                word has not withdrawn the floor.
              */
              AND (@SubjectId        IS NULL OR j.SubjectId        = @SubjectId
                   OR EXISTS (SELECT 1 FROM dbo.t_app_job_subjects js
                              WHERE js.JobId = j.JobId AND js.SubjectId = @SubjectId AND js.Is_Deleted = 0))
              AND (@DesignationId    IS NULL OR j.DesignationId    = @DesignationId)
              AND (@EmploymentTypeId IS NULL OR j.EmploymentTypeId = @EmploymentTypeId)
              AND (@CityId           IS NULL OR j.CityId           = @CityId)
              AND (@StateId          IS NULL OR j.StateId          = @StateId)
              AND (@MinSalary        IS NULL OR j.SalaryMax IS NULL OR j.SalaryMax >= @MinSalary)

              /*
                🔴 THE ONE SEARCH PREDICATE, AND IT CANNOT SEEK. A leading
                wildcard makes this non-sargable: no index on JobTitle or
                SchoolName can be used, and the string comparison is evaluated
                per candidate row. Said plainly rather than dressed up — and NO
                INDEX HAS BEEN ADDED for it, because none would be used and a
                measurement nobody took is not a justification.

                What bounds the cost is the shape already here: this is one
                conjunct beside `j.JobStatusId = 2`, which IS the sargable seek,
                so the comparison runs over OPEN postings rather than the whole
                table. At hundreds of open jobs that is noise. When it stops
                being noise the answer is full-text (CONTAINS) or a precomputed
                search column — chosen after measuring.

                ⚠️ A % or _ TYPED BY A USER IS STILL A WILDCARD. Pre-existing
                behaviour of @Search, left alone on purpose: escaping it now
                would change what the existing caller's searches return. It is a
                parameter, so there is no injection question here — only a
                slightly surprising search.
              */
              AND (@Needle IS NULL
                   OR j.JobTitle   LIKE N'%' + @Needle + N'%'
                   OR s.SchoolName LIKE N'%' + @Needle + N'%')
        ) m
    ) f;

    /*
      🔴 THE KEYWORD OVERRIDES THE MODE, AND IT DOES IT HERE — ONCE, FOR BOTH
      READERS.

      When somebody types a search the tabs stop being the question, so every
      mode must return the same plain search. Setting all three bits does that
      with one statement inside the shared block: USP_BrowseJobs' mode DELETE
      then removes nothing whatever the mode, and USP_BrowseJobCounts' three
      SUMs all come back equal to the result count. The list and the counts
      still agree, which is the invariant this whole file shape exists for.

      ⚠️ The alternative — an `IF @Needle IS NOT NULL` branch in each reader —
      is two branches, and one of them would eventually be edited alone.

      ⚠️ SO THE TABS ARE NOT DISJOINT WHILE A KEYWORD IS ACTIVE. That is the
      override working, not a bug: the screen should show one result count while
      somebody is searching, not three identical ones.

      ⚠️ PreferenceRank IS LEFT ALONE. A keyword makes every row eligible for
      every tab, but it does not invent a preference the teacher never saved —
      so jobs with no matching location still sort last within the preferred
      ordering rather than being given a rank they did not earn.
    */
    IF @Needle IS NOT NULL
        UPDATE @Candidates SET IsMatch = 1, IsMightLike = 1, IsPreferred = 1;
    -- <<< SHARED CANDIDATE CLASSIFICATION - END

    /*
      🔴 THE MODE IS APPLIED BY REMOVING WHAT THE TAB DOES NOT SHOW — ONCE.

      Not as a predicate on the page query and again on the count query. That
      duplication is what this phase exists to avoid: the page and the total
      must be a window onto, and the size of, ONE set. After this DELETE there
      is no mode predicate anywhere below, so there is nothing to forget.

      ⚠️ @EffMode NULL deletes nothing, which is the unmoded browse.

      ⚠️ Under an active keyword all three bits are 1 (see the shared block), so
      this deletes nothing whatever the mode — that IS the override.
    */
    IF @EffMode IS NOT NULL
        DELETE FROM @Candidates
         WHERE (@EffMode = 'MATCHES'    AND IsMatch     = 0)
            OR (@EffMode = 'MIGHT_LIKE' AND IsMightLike = 0)
            OR (@EffMode = 'PREFERRED'  AND IsPreferred = 0);

    /*
      🔴 AND THE UNMODED BROWSE STILL FILTERS ON THE THREE SETS.

      This is the contract that predates the tabs: `?subjectIds=3&subjectIds=7`
      narrows the list. When the modes arrived, the set filters moved from the
      WHERE clause into the classification, and an unmoded call stopped honouring
      them — `?subjectIds=999999` returned every open job while the screen said
      it was showing the teacher's subjects.

      ⚠️ IT CANNOT GO IN THE SHARED BLOCK. USP_BrowseJobCounts has no @Mode and
      must classify the WHOLE candidate set — narrowing it there would make the
      three counts describe a list nobody is looking at. The classification is
      shared; what each reader DOES with it is not, which is why the mode DELETE
      above lives here too.

      ⚠️ A MODED CALL IS LEFT ALONE. MATCHES already ANDs the same three sets
      (plus the state) into IsMatch, and MIGHT_LIKE must see jobs that fail them
      — subtracting them here would empty the tab whose entire job is to hold
      the near-misses.
    */
    IF @EffMode IS NULL
        DELETE FROM @Candidates WHERE SetsOk = 0;

    /*
      The page. The joins here are PROJECTION ONLY — every liveness and
      eligibility rule was already applied when @Candidates was built, and
      both joins are on primary keys so neither can change the row count. 🔴 Do
      not add a WHERE clause to this SELECT: a row that should not be visible
      must be kept out of @Candidates, where the count sees it too.
    */
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
    FROM @Candidates c
        INNER JOIN dbo.t_app_jobs j              ON j.JobId    = c.JobId
        INNER JOIN dbo.t_app_schools s           ON s.SchoolId = j.SchoolId
        INNER JOIN dbo.t_app_school_branches b   ON b.BranchId = j.BranchId
    /*
      Newest first, as every mode did before this phase — with ONE addition.

      🔴 IN PREFERRED, THE TEACHER'S OWN RANKING LEADS. PreferenceOrder is a
      value in the row and 1 is their first choice (016's header), so a tab
      named after the places somebody chose should open on the place they chose
      first. Any other ordering here would be "whatever the join returned",
      which is not an ordering.

      ⚠️ ONE ORDER BY, NOT TWO QUERIES. The CASE collapses to a constant NULL in
      every other mode, so it cannot reorder them — and a second paging SELECT
      for one tab would be a second place the projection and the paging could
      drift.

      ⚠️ ISNULL(..., 2147483647) RATHER THAN A BARE COLUMN, because NULLs sort
      FIRST in ASC on SQL Server. A rank only exists for jobs that actually sit
      somewhere the teacher named; under an active keyword every row is eligible
      for every tab, so unranked rows DO appear here and must sort LAST rather
      than leading the list they have no claim on.
    */
    ORDER BY CASE WHEN @EffMode = 'PREFERRED'
                  THEN ISNULL(c.PreferenceRank, 2147483647) END ASC,
             c.PublishedOn DESC,
             c.JobId DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS FETCH NEXT @PageSize ROWS ONLY;

    /*
      🔴 THE TOTAL IS THE SIZE OF THE SET THE PAGE CAME FROM. One statement, no
      predicate, nothing to keep in step — the older shape re-stated the whole
      WHERE clause here and relied on the two copies agreeing. They cannot
      disagree now because there is only one.
    */
    SELECT COUNT_BIG(*) AS TotalRecords FROM @Candidates;
END
GO


/*==============================================================================
  USP_BrowseJobCounts — the three tab labels' numbers, derived on every call.

  "Matches your profile (12)" · "You might like (31)" · "In places you want (7)"

  ---------------------------------------------------------------------------
  🔴 DERIVED. THERE IS NO COUNTER COLUMN HERE AND THERE MUST NEVER BE ONE.
  ---------------------------------------------------------------------------
  Rule 3 at the top of this file already says this about applications:
  t_app_jobs.ApplicationCount is left at zero and never written, because a
  maintained tally drifts from the rows underneath it and nothing errors when it
  does. These three numbers are the same kind of number, so they get the same
  treatment — three SUMs over the candidate set this call just built, every
  call, with nothing stored and nothing to go stale.

  ---------------------------------------------------------------------------
  🔴 HOW THESE NUMBERS CANNOT DISAGREE WITH THE LISTS
  ---------------------------------------------------------------------------
  Not "the same filters are passed in". Not "the predicate was copied
  carefully". Mechanically, three ways:

    1. The classification between the SHARED markers below is byte-for-byte
       identical to USP_BrowseJobs', and the BUILD GUARD at the foot of this
       file reads both definitions out of sys.sql_modules and FAILS THE BUILD if
       they differ by so much as a renamed alias. The lead runs the build twice;
       a drifted copy never reaches a screen.

    2. Each count is the SUM of the very bit column USP_BrowseJobs' mode DELETE
       filters its page by. The count and the list are two readings of ONE
       expression, not two expressions that happen to agree.

    3. The keyword override lives inside the shared block, so a keyword cannot
       override the mode on the list side while the counts side keeps
       classifying.

  ⚠️ IT TAKES THE SAME FILTER PARAMETERS AS THE LIST, MINUS PAGING. A count has
  no page. Carrying @PageNumber / @PageSize here would invite somebody to read
  these as per-page numbers, which is the opposite of what a tab label is.

  🔴 AND MINUS @Mode, WHICH IS NOT AN OVERSIGHT. One row of three counts answers
  all three tabs at once; handing it the tab currently open would be asking "how
  many are in each tab, given we are only looking at this one". There is no
  @Mode parameter here, so that question cannot be asked — and the API's counts
  action does not accept a mode either. 🔴 Do not add one "for symmetry": a mode
  on this procedure is a filter somebody would eventually apply, and the three
  numbers would start describing a subset of themselves.

  ⚠️ THE THREE NUMBERS DO NOT SUM TO A TOTAL. MATCHES and MIGHT_LIKE are
  disjoint by construction; PREFERRED deliberately overlaps both, because "where
  am I willing to work" is a different question from "what work suits me" (see
  USP_BrowseJobs' header). A screen that adds them up is wrong.

  ⚠️ WITH A KEYWORD ACTIVE ALL THREE ARE EQUAL, and equal to the search's own
  result count. That is the mode override, faithfully reported; the screen
  should show one number while somebody is searching rather than three identical
  ones.

  🔴 ISNULL AROUND EVERY SUM. COUNT over zero rows is 0; SUM over zero rows is
  NULL, and a NULL arriving in a non-nullable int fails on the first teacher
  whose filters match nothing rather than in testing — the same note
  USP_GetSchoolApplicantStats carries further up this file.

  ⚠️ ONE ROW, ALWAYS. Three zeroes is a real answer and a measurement; the API
  must not turn it into a 404 or an absent object, because the tab strip has to
  render either way.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_BrowseJobCounts
    @UserUid           uniqueidentifier = NULL,
    @Search            nvarchar(150)    = NULL,
    @Keyword           nvarchar(150)    = NULL,
    -- 🔴 NO @Mode. See the header — all three tabs at once, deliberately.
    @SubjectId         int              = NULL,
    @DesignationId     int              = NULL,
    @EmploymentTypeId  int              = NULL,
    @CityId            int              = NULL,
    @StateId           int              = NULL,
    @MinSalary         decimal(18, 2)   = NULL,

    -- 🔴 THE SAME THREE SETS, SPELLED THE SAME WAY. The shared block below
    -- names these parameters, so a rename here is a failed build rather than a
    -- quietly different count.
    @SubjectIds        dbo.IntIdList    READONLY,
    @ClassLevelIds     dbo.IntIdList    READONLY,
    @QualificationIds  dbo.IntIdList    READONLY
AS
BEGIN
    SET NOCOUNT ON;

    -- >>> SHARED CANDIDATE CLASSIFICATION - BEGIN
    /*
      🔴 EVERYTHING BETWEEN THESE TWO MARKERS IS BYTE-FOR-BYTE IDENTICAL IN
      USP_BrowseJobs AND USP_BrowseJobCounts, AND A BUILD GUARD AT THE FOOT OF
      THIS FILE FAILS THE BUILD THE MOMENT IT STOPS BEING.

      That guard is the real answer to "how do the counts and the list stay in
      step?" — not "they were copied carefully", but: they are compared, on
      every build, out of sys.sql_modules. If you change one of these blocks,
      change the other by COPYING it. Anything else, down to a renamed alias,
      is a failed build with a message naming the procedure you forgot.

      ⚠️ DO NOT FACTOR THIS INTO A FUNCTION INSTEAD. A user-defined function
      cannot take a table-valued parameter, and @SubjectIds, @ClassLevelIds and
      @QualificationIds are TVPs. That is the actual reason this is a guarded
      duplicate rather than one callable definition, and it was checked rather
      than assumed.

      ⚠️ THE MODE IS NOT DECIDED IN HERE. @Mode belongs to the LIST procedure
      alone — the counts procedure has no such parameter, because one row of
      three counts answers all three tabs at once. What IS in here is the
      keyword override, so that a keyword cannot neutralise the mode on the
      list side while the counts side carries on classifying.
    */

    /*
      ONE search term, two accepted spellings. @Keyword is the name the API
      contract asked for; @Search is the name every existing caller already
      sends, and it has done this exact LIKE since Phase 5. Coalesced here so
      there is exactly ONE search predicate below and nothing for a second one
      to drift from. A caller sending both gets @Keyword.
    */
    DECLARE @Needle nvarchar(150) = COALESCE(
        NULLIF(LTRIM(RTRIM(@Keyword)), N''),
        NULLIF(LTRIM(RTRIM(@Search)),  N''));

    /*
      ---------------------------------------------------------------------
      🔴 WHOSE LISTS AND WHOSE SAVED LOCATIONS: RESOLVED HERE, FROM THE TOKEN
      ---------------------------------------------------------------------
      @TeacherId is a LOCAL, derived from @UserUid. Neither procedure has a
      teacher-id PARAMETER and neither may ever grow one, so "read somebody
      else's preferred locations" is not expressible — there is no slot to put
      another teacher's id in. That is the 3D property this file's header
      describes for USP_GetMyApplications, applied to a table that has never
      had a reader on this surface before.

      ⚠️ A NULL @UserUid — the signed-out browse the header mentions — leaves
      both locals NULL, which turns the per-card flags off, makes every
      preferred-location test false, and stops the state conjunct narrowing
      anything. It does NOT fall back to "everybody's preferences".

      🔴 @ProfileStateId IS THE TEACHER'S OWN STATE, READ FROM THEIR OWN ROW,
      and it is the state MATCHES is measured against. There is no request
      field a client could set instead — the rule every identity value in this
      file follows (2.39). @StateId is a different thing and keeps its old
      meaning: the toolbar's state filter, applied to all three modes.

      ⚠️ The suspension and soft-delete tests are the same ones
      USP_GetTeacherIdForUser applies. A suspended teacher resolves to nothing
      here too, so their browse degrades to the signed-out shape rather than
      quietly keeping its personalisation.
    */
    DECLARE @TeacherId bigint = NULL, @ProfileStateId int = NULL;

    IF @UserUid IS NOT NULL
        SELECT @TeacherId = t.TeacherId, @ProfileStateId = t.CurrentStateId
        FROM dbo.t_app_teachers t
        WHERE t.UserUid = @UserUid AND t.Is_Deleted = 0 AND t.Is_Active = 1 AND t.IsSuspended = 0;

    /*
      ---------------------------------------------------------------------
      ⚠️ A TABLE VARIABLE RATHER THAN A #TEMP TABLE, AND THE REASON IS NOT
         TASTE
      ---------------------------------------------------------------------
      The usual objection to a table variable is cardinality: pre-2019 the
      optimiser assumed one row and picked plans to match. This file targets
      SQL Server 2019 at compatibility level 150, where TABLE VARIABLE DEFERRED
      COMPILATION gives it the real row count — so the objection does not apply
      on the platform this ships to.

      🔴 AND NOTHING ELSE IN THIS CODEBASE USES A #TEMP TABLE — not one
      procedure in jp_app, jp_mdm or jp_sso. That means 999_cross_file_guards'
      sweep, which CROSS APPLYs sys.dm_sql_referenced_entities over EVERY
      procedure in the database, has never been run against a module that owns
      one. A table variable is invisible to dependency metadata, so this change
      cannot be the one that makes a whole-build guard raise on a correct
      procedure. 024's header records exactly that kind of surprise — a guard
      failing a from-scratch build over code that was right.

      ⚠️ The trade: an INSERT into a table variable cannot go parallel. At this
      product's scale that is nothing, and it belongs in the same measurement
      as the paging note in the header if open jobs ever reach six figures.
    */
    DECLARE @Candidates TABLE
    (
        /*
          ⚠️ THE PRIMARY KEY IS NOT "AN INDEX I DID NOT MEASURE". It is the key
          of a variable that lives for one procedure call, and it is what the
          join back to t_app_jobs and the mode DELETE seek on. Nothing in this
          change adds an index to t_app_jobs, t_app_job_subjects or anything
          else that ships.
        */
        JobId          bigint    NOT NULL PRIMARY KEY CLUSTERED,
        PublishedOn    datetime2 NULL,
        IsMatch        bit       NOT NULL,
        IsMightLike    bit       NOT NULL,
        IsPreferred    bit       NOT NULL,

        /* The three set filters without the state — see SetsOk above. Unused
           by the counts reader, and carried there anyway so the two blocks
           between the SHARED markers stay byte-identical. */
        SetsOk         bit       NOT NULL,

        /*
          The BEST (lowest) PreferenceOrder among the teacher's saved locations
          that this job satisfies; NULL when it satisfies none.

          ⚠️ PreferenceOrder is a VALUE IN THE ROW, not a position in a result
          set, so it has to be carried here deliberately — it would not survive
          as "the order the join happened to return". It is what orders the
          PREFERRED tab, so a teacher's first-choice city leads their own tab.
        */
        PreferenceRank int       NULL
    );

    INSERT INTO @Candidates
        (JobId, PublishedOn, IsMatch, IsMightLike, IsPreferred, SetsOk, PreferenceRank)
    SELECT  f.JobId,
            f.PublishedOn,
            f.IsMatch,

            /*
              🔴 THE SUBTRACTION, IN SQL, ONCE. MIGHT_LIKE is the loose hit
              MINUS everything MATCHES already returns — and it reads the single
              IsMatch column computed one level down rather than restating the
              four-way conjunction. So "a job is never in both tabs" is true by
              construction, not by two expressions agreeing.

              It cannot be done in the client at all: a client sees one page of
              one tab and has no way to know what the other tab's later pages
              hold.
            */
            CAST(CASE WHEN f.IsLooseHit = 1 AND f.IsMatch = 0 THEN 1 ELSE 0 END AS bit),

            f.AnyLocation,
            f.SetsOk,
            f.BestPreference
    FROM (
        SELECT  m.JobId,
                m.PublishedOn,
                m.BestPreference,

                -- 🔴 MATCHES: subjects AND class levels AND qualification AND
                -- state. All four, ANDed, computed ONCE — here.
                CAST(CASE WHEN m.SubjectOk = 1 AND m.LevelOk = 1
                           AND m.QualOk = 1 AND m.StateOk = 1
                          THEN 1 ELSE 0 END AS bit)                          AS IsMatch,

                /*----------------------------------------------------------
                  🔴 THE SAME THREE SETS WITHOUT THE STATE — AND THIS COLUMN
                  EXISTS BECAUSE ITS ABSENCE WAS A LIVE REGRESSION.

                  An UNMODED browse (`@Mode` NULL) is the oldest contract this
                  procedure has: `?subjectIds=3&subjectIds=7` NARROWS the list,
                  full stop, with no tabs involved. When the modes were added,
                  the three set filters moved out of the WHERE clause and into
                  the classification above — so they stopped filtering anything
                  unless a mode asked for them, and `?subjectIds=999999` began
                  returning every open job.

                  Nothing was red: the sets still worked in every moded call,
                  which is all the new code exercised. `browse-sets.mjs` is what
                  caught it, on the first regression it had ever been part of.

                  ⚠️ IT DELIBERATELY EXCLUDES StateOk. The state is resolved
                  from the teacher's own row for MATCHES; an unmoded browse must
                  not be silently confined to where the caller happens to live.
                  That is the difference between a filter the caller asked for
                  and one nobody did.
                ----------------------------------------------------------*/
                CAST(CASE WHEN m.SubjectOk = 1 AND m.LevelOk = 1 AND m.QualOk = 1
                          THEN 1 ELSE 0 END AS bit)                          AS SetsOk,

                -- MIGHT_LIKE's raw side: ANY of subjects, class levels or saved
                -- preferred locations. ORed.
                CAST(CASE WHEN m.AnySubject = 1 OR m.AnyLevel = 1
                           OR m.BestPreference IS NOT NULL
                          THEN 1 ELSE 0 END AS bit)                          AS IsLooseHit,

                -- PREFERRED: "this job is somewhere I said I would work".
                CAST(CASE WHEN m.BestPreference IS NOT NULL
                          THEN 1 ELSE 0 END AS bit)                          AS AnyLocation
        FROM (
            SELECT  j.JobId,
                    j.PublishedOn,

                    /*----------------------------------------------------------
                      THE STRICT CONJUNCTS — "an empty set does not narrow".

                      ⚠️ `NOT EXISTS (SELECT 1 FROM @Ids) OR <membership>` is
                      the idiom an omitted READONLY TVP relies on: SQL Server
                      hands the procedure an EMPTY TABLE rather than NULL, and
                      empty means "not filtering on this". Keep it.

                      ⚠️ SUBJECTS MATCH THE PRIMARY COLUMN **OR** THE BRIDGE. A
                      job carries one primary subject and a set of others;
                      matching only the column would hide a physics job from a
                      physics teacher because physics was listed second.
                    ----------------------------------------------------------*/
                    CAST(CASE WHEN NOT EXISTS (SELECT 1 FROM @SubjectIds)
                                OR j.SubjectId IN (SELECT Id FROM @SubjectIds)
                                OR EXISTS (SELECT 1 FROM dbo.t_app_job_subjects js
                                           WHERE js.JobId = j.JobId AND js.Is_Deleted = 0
                                             AND js.SubjectId IN (SELECT Id FROM @SubjectIds))
                              THEN 1 ELSE 0 END AS bit)                      AS SubjectOk,

                    CAST(CASE WHEN NOT EXISTS (SELECT 1 FROM @ClassLevelIds)
                                OR EXISTS (SELECT 1 FROM dbo.t_app_job_class_levels jc
                                           WHERE jc.JobId = j.JobId AND jc.Is_Deleted = 0
                                             AND jc.ClassLevelId IN (SELECT Id FROM @ClassLevelIds))
                              THEN 1 ELSE 0 END AS bit)                      AS LevelOk,

                    /*
                      P4. QUALIFICATION IS A COLUMN ON THE JOB, NOT A BRIDGE —
                      t_app_jobs.QualificationId int NULL (022_t_app_jobs.sql).
                      There is no t_app_job_qualifications table anywhere in the
                      schema, which is why there is no "OR the bridge" arm here
                      beside the subject one.

                      🔴 A JOB WITH QualificationId NULL MATCHES EVERY SET. The
                      obvious spelling — a bare IN — is WRONG, because NULL
                      never satisfies IN: a posting that asks for no particular
                      degree would vanish from every teacher's matches the
                      moment they filtered on their own qualification. An
                      UNSTATED requirement is not an UNMET one.
                    */
                    CAST(CASE WHEN NOT EXISTS (SELECT 1 FROM @QualificationIds)
                                OR j.QualificationId IS NULL
                                OR j.QualificationId IN (SELECT Id FROM @QualificationIds)
                              THEN 1 ELSE 0 END AS bit)                      AS QualOk,

                    /*
                      ⚠️ STATE GETS THE OPPOSITE NULL TREATMENT, DELIBERATELY. A
                      job with StateId NULL is NOT a state match. Qualification
                      NULL means "we require nothing of you"; location NULL
                      means "we did not say where this is", and we must not
                      claim it is where the teacher lives. Two NULLs, two
                      meanings, two answers.

                      ⚠️ j.StateId, not b.StateId, because the existing @StateId
                      filter and 024's public search both read the job's own
                      column — taking the branch's here would make "in this
                      state" mean two different things on two tabs.
                    */
                    CAST(CASE WHEN @ProfileStateId IS NULL OR j.StateId = @ProfileStateId
                              THEN 1 ELSE 0 END AS bit)                      AS StateOk,

                    /*----------------------------------------------------------
                      THE LOOSE ARMS — "an empty set contributes NOTHING".

                      🔴 THE ASYMMETRY WITH THE CONJUNCTS ABOVE IS LOAD-BEARING
                      AND MUST NOT BE TIDIED AWAY. `NOT EXISTS (@Ids) OR ...`
                      inside a DISJUNCTION would read "an empty set matches
                      EVERYTHING", and one empty set would drag the whole job
                      market into the "You might like" tab. So these are bare
                      EXISTS with no escape clause.
                    ----------------------------------------------------------*/
                    CAST(CASE WHEN j.SubjectId IN (SELECT Id FROM @SubjectIds)
                                OR EXISTS (SELECT 1 FROM dbo.t_app_job_subjects js
                                           WHERE js.JobId = j.JobId AND js.Is_Deleted = 0
                                             AND js.SubjectId IN (SELECT Id FROM @SubjectIds))
                              THEN 1 ELSE 0 END AS bit)                      AS AnySubject,

                    CAST(CASE WHEN EXISTS (SELECT 1 FROM dbo.t_app_job_class_levels jc
                                           WHERE jc.JobId = j.JobId AND jc.Is_Deleted = 0
                                             AND jc.ClassLevelId IN (SELECT Id FROM @ClassLevelIds))
                              THEN 1 ELSE 0 END AS bit)                      AS AnyLevel,

                    /*
                      P5. THE TEACHER'S SAVED PREFERRED LOCATIONS — the first
                      read of t_app_teacher_preferred_locations on this surface,
                      so there is no precedent to copy and the reasoning is
                      written out in full.

                      🔴 SCOPED TO @TeacherId, WHICH CAME FROM THE TOKEN. See
                      the DECLARE above: there is no teacher-id parameter on
                      either procedure, so another teacher's locations cannot be
                      named. `@TeacherId IS NOT NULL` is inside the subquery on
                      purpose — without it, a signed-out browse would compare
                      TeacherId against NULL, which is never true, but the
                      intent would rest on an accident of three-valued logic
                      instead of being stated.

                      ⚠️ Is_Deleted = 0 AND Is_Active = 1, both. A preference
                      the teacher switched off is not a preference.

                      ---------------------------------------------------------
                      🔴 HOW CityId AND StateId COMBINE. THREE CASES, AND THEY
                         ARE NOT THE SAME STRENGTH OF CLAIM.
                      ---------------------------------------------------------
                      A row is (StateId NOT NULL, CityId nullable). So:

                        1. BOTH NAME A CITY, AND THEY ARE THE SAME CITY
                           -> a match, exactly. The narrow case, and the one
                              that must not be widened: treating every row as a
                              state match would hand the tab most of the state
                              and make "In places you want" meaningless.

                        2. THE PREFERENCE NAMES NO CITY — "anywhere in this
                           state". That is a REAL preference and not a
                           placeholder for one (016's header argues it at
                           length: the city dataset is unimported, the forms
                           degrade to state-only, and a teacher who genuinely
                           means the whole state should not have to list twelve
                           cities to say so). So it matches any job in that
                           state. Read as anything narrower, this row would
                           match nothing at all and today most rows look like
                           this.

                        3. THE JOB NAMES NO CITY. Symmetrically: the posting
                           declined to say which town, so the state is the
                           finest grain BOTH sides actually agree on, and the
                           job matches a city preference in that same state.
                           The alternative — requiring a city on both sides —
                           would hide state-only postings from every teacher who
                           answered the city question precisely, i.e. punish the
                           more careful answer.

                      ⚠️ AND THE STATE USED IN CASES 2 AND 3 IS THE ONE ON THE
                      PREFERENCE ROW, because m_mdm_city lives in jp_mdm and no
                      query here may join across databases (2.2). The row
                      carrying its own StateId beside its CityId is the only
                      reason this is answerable at all.

                      ⚠️ TehsilId ON THIS TABLE IS DELIBERATELY NOT READ, and
                      not because it was missed: t_app_jobs HAS NO TEHSIL
                      COLUMN — 036_alter_address_columns.sql says "t_app_jobs
                      DELIBERATELY GETS NOTHING" — so there is nothing on the
                      job side to compare it against. A tehsil-only preference
                      therefore degrades to its STATE through case 2, which is
                      WIDER than the teacher asked for. That is the honest
                      degradation: the alternative is a row that matches nothing
                      and a teacher who answered more precisely seeing an empty
                      tab. 🔴 If tehsil is ever added to t_app_jobs, this
                      predicate is one of the places that must learn about it.

                      ⚠️ MIN(PreferenceOrder) RATHER THAN EXISTS, so one
                      subquery answers both "does this job sit anywhere I want"
                      (NOT NULL) and "how high up my list is the best such
                      place". MIN over no rows is NULL, and PreferenceOrder is
                      NOT NULL, so no null-elimination warning can fire.
                    */
                    (SELECT MIN(p.PreferenceOrder)
                       FROM dbo.t_app_teacher_preferred_locations p
                      WHERE @TeacherId IS NOT NULL
                        AND p.TeacherId  = @TeacherId
                        AND p.Is_Deleted = 0
                        AND p.Is_Active  = 1
                        AND (j.CityId = p.CityId
                             OR ((p.CityId IS NULL OR j.CityId IS NULL)
                                 AND j.StateId = p.StateId)))                AS BestPreference

            FROM dbo.t_app_jobs j
                INNER JOIN dbo.t_app_schools s         ON s.SchoolId = j.SchoolId
                INNER JOIN dbo.t_app_school_branches b ON b.BranchId = j.BranchId
            WHERE j.Is_Deleted   = 0
              AND j.Is_Active    = 1
              AND j.JobStatusId  = 2                                          -- the seek
              AND dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) = 2   -- the date
              AND s.Is_Deleted   = 0 AND s.Is_Active = 1 AND s.IsSuspended = 0
              AND b.Is_Deleted   = 0

              /*
                THE TOOLBAR'S OWN FILTERS. These narrow EVERY mode, including a
                keyword search: somebody who set a salary floor and then typed a
                word has not withdrawn the floor.
              */
              AND (@SubjectId        IS NULL OR j.SubjectId        = @SubjectId
                   OR EXISTS (SELECT 1 FROM dbo.t_app_job_subjects js
                              WHERE js.JobId = j.JobId AND js.SubjectId = @SubjectId AND js.Is_Deleted = 0))
              AND (@DesignationId    IS NULL OR j.DesignationId    = @DesignationId)
              AND (@EmploymentTypeId IS NULL OR j.EmploymentTypeId = @EmploymentTypeId)
              AND (@CityId           IS NULL OR j.CityId           = @CityId)
              AND (@StateId          IS NULL OR j.StateId          = @StateId)
              AND (@MinSalary        IS NULL OR j.SalaryMax IS NULL OR j.SalaryMax >= @MinSalary)

              /*
                🔴 THE ONE SEARCH PREDICATE, AND IT CANNOT SEEK. A leading
                wildcard makes this non-sargable: no index on JobTitle or
                SchoolName can be used, and the string comparison is evaluated
                per candidate row. Said plainly rather than dressed up — and NO
                INDEX HAS BEEN ADDED for it, because none would be used and a
                measurement nobody took is not a justification.

                What bounds the cost is the shape already here: this is one
                conjunct beside `j.JobStatusId = 2`, which IS the sargable seek,
                so the comparison runs over OPEN postings rather than the whole
                table. At hundreds of open jobs that is noise. When it stops
                being noise the answer is full-text (CONTAINS) or a precomputed
                search column — chosen after measuring.

                ⚠️ A % or _ TYPED BY A USER IS STILL A WILDCARD. Pre-existing
                behaviour of @Search, left alone on purpose: escaping it now
                would change what the existing caller's searches return. It is a
                parameter, so there is no injection question here — only a
                slightly surprising search.
              */
              AND (@Needle IS NULL
                   OR j.JobTitle   LIKE N'%' + @Needle + N'%'
                   OR s.SchoolName LIKE N'%' + @Needle + N'%')
        ) m
    ) f;

    /*
      🔴 THE KEYWORD OVERRIDES THE MODE, AND IT DOES IT HERE — ONCE, FOR BOTH
      READERS.

      When somebody types a search the tabs stop being the question, so every
      mode must return the same plain search. Setting all three bits does that
      with one statement inside the shared block: USP_BrowseJobs' mode DELETE
      then removes nothing whatever the mode, and USP_BrowseJobCounts' three
      SUMs all come back equal to the result count. The list and the counts
      still agree, which is the invariant this whole file shape exists for.

      ⚠️ The alternative — an `IF @Needle IS NOT NULL` branch in each reader —
      is two branches, and one of them would eventually be edited alone.

      ⚠️ SO THE TABS ARE NOT DISJOINT WHILE A KEYWORD IS ACTIVE. That is the
      override working, not a bug: the screen should show one result count while
      somebody is searching, not three identical ones.

      ⚠️ PreferenceRank IS LEFT ALONE. A keyword makes every row eligible for
      every tab, but it does not invent a preference the teacher never saved —
      so jobs with no matching location still sort last within the preferred
      ordering rather than being given a rank they did not earn.
    */
    IF @Needle IS NOT NULL
        UPDATE @Candidates SET IsMatch = 1, IsMightLike = 1, IsPreferred = 1;
    -- <<< SHARED CANDIDATE CLASSIFICATION - END

    /*
      One row, three ints, in the order the tab strip reads left to right.

      🔴 No DELETE here, unlike the list procedure: this reports ALL THREE
      buckets of the one candidate set, which is why there is a single row
      rather than three calls.
    */
    SELECT
        ISNULL(SUM(CAST(c.IsMatch     AS int)), 0)  AS [Matches],
        ISNULL(SUM(CAST(c.IsMightLike AS int)), 0)  AS MightLike,
        ISNULL(SUM(CAST(c.IsPreferred AS int)), 0)  AS Preferred
    FROM @Candidates c;
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

  ---------------------------------------------------------------------------
  🔴 ADDRESSABLE BY UID AS WELL AS BY ID (7B-0), AND THE SAME RULE EITHER WAY
  ---------------------------------------------------------------------------
  The public website sends a teacher here through its Apply button, and the
  public surface deliberately exposes only uids (2.47) — public-contract.mjs's
  allowlist FAILS on a "jobId" key. So the funnel arrives holding a uid.

  🔴 Resolved INSIDE this procedure rather than by a lookup endpoint beside it.
  A "uid -> id" route would be a second place that decides which jobs a
  teacher may name, and the day the two disagree the lenient one wins. Here the
  uid becomes an id and then meets the SAME WHERE clause as before: published,
  still open, school not suspended.

  ⚠️ A uid that resolves to nothing leaves @JobId NULL, and all three result
  sets come back empty — which is the answer a job that never existed gives,
  and what the teacher's screen already handles.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetJobForTeacher
    @JobId    bigint = NULL,
    @JobUid   uniqueidentifier = NULL,
    @UserUid  uniqueidentifier = NULL
AS
BEGIN
    SET NOCOUNT ON;

    /*
      🔴 EXACTLY ONE OF THE TWO, AND THIS IS A PROGRAMMER ERROR RATHER THAN A
      USER ONE — so it is loud rather than silently empty.

      Both supplied is the dangerous shape: it reads as "find this id, or this
      uid" and whichever won would be an accident. Neither supplied would
      return empty from every set below, which looks exactly like a job that
      does not exist — the worst way to learn that a caller forgot an argument.

      ⚠️ The C# side cannot reach this: IPublicRepository exposes two named
      methods rather than one with two nullable parameters, precisely so a call
      site cannot put the wrong value in the wrong slot.
    */
    IF (@JobId IS NULL AND @JobUid IS NULL)
        OR (@JobId IS NOT NULL AND @JobUid IS NOT NULL)
    BEGIN
        RAISERROR('USP_GetJobForTeacher: supply EXACTLY ONE of @JobId or @JobUid. Both or neither is a caller bug, and returning empty would look like a job that does not exist.', 16, 1);
        RETURN;
    END

    IF @JobUid IS NOT NULL
        SELECT @JobId = j.JobId
          FROM dbo.t_app_jobs j
         WHERE j.JobUid = @JobUid
           AND j.Is_Deleted = 0;

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

/*==============================================================================
  🔒 BUILD GUARD — THE TAB COUNTS AND THE TAB LISTS SHARE ONE PREDICATE

  ---------------------------------------------------------------------------
  🔴 WHAT THIS PROTECTS, AND THE INCIDENT IT IS NAMED AFTER
  ---------------------------------------------------------------------------
  USP_BrowseJobs draws the three tabs; USP_BrowseJobCounts draws the numbers in
  their labels. The moment those two answer from different predicates, the
  product has a count that disagrees with the rows under it — which is exactly
  what t_app_jobs.ApplicationCount did, and why rule 3 at the top of this file
  forbids a maintained tally outright.

  SQL Server gives us no way to SHARE the predicate: a user-defined function
  cannot take a table-valued parameter, and the three set filters are TVPs. So
  the predicate is a deliberate duplicate — and this guard is the price of that,
  paid at build time instead of in production.

  ⚠️ IT LIVES HERE, BESIDE THE CODE, NOT IN 999_cross_file_guards.sql. 999's own
  header draws the line: "no procedure anywhere may X" goes there; "this
  procedure must not X" belongs where somebody editing it will read it. Both
  procedures exist by this point in this file, so the rule is judgeable here —
  and here is where it will actually be seen.

  ---------------------------------------------------------------------------
  WHAT IT COMPARES
  ---------------------------------------------------------------------------
  The text between the two SHARED CANDIDATE CLASSIFICATION markers, read out of
  sys.sql_modules via OBJECT_DEFINITION, with layout whitespace collapsed and
  then compared under a BINARY collation.

  ⚠️ BINARY, SO EVEN A CASE CHANGE FAILS. That is stricter than correctness
  strictly requires, and it is the point: "identical" is a rule a reviewer can
  check in one second, while "equivalent" is a rule nobody can check at all. The
  fix when it fires is always the same and always trivial — copy the block.

  ⚠️ Whitespace IS normalised, because re-indenting a block is not a semantic
  change and a guard that fired on it would be switched off within a week.

  ⚠️ A MISSING MARKER FAILS TOO. Deleting the markers would silently disable the
  guard, which is worse than the drift it exists to catch.
==============================================================================*/
DECLARE @mkBegin nvarchar(100) = N'-- >>> SHARED CANDIDATE CLASSIFICATION - BEGIN';
DECLARE @mkEnd   nvarchar(100) = N'-- <<< SHARED CANDIDATE CLASSIFICATION - END';

DECLARE @listSrc nvarchar(max) = ISNULL(OBJECT_DEFINITION(OBJECT_ID(N'dbo.USP_BrowseJobs')), N'');
DECLARE @cntSrc  nvarchar(max) = ISNULL(OBJECT_DEFINITION(OBJECT_ID(N'dbo.USP_BrowseJobCounts')), N'');

DECLARE @lb int = CHARINDEX(@mkBegin, @listSrc),
        @le int = CHARINDEX(@mkEnd,   @listSrc),
        @cb int = CHARINDEX(@mkBegin, @cntSrc),
        @ce int = CHARINDEX(@mkEnd,   @cntSrc);

IF @lb = 0 OR @le <= @lb OR @cb = 0 OR @ce <= @cb
BEGIN
    DECLARE @missing nvarchar(1200) =
        N'017_application_reads: 🔒 THE SHARED CLASSIFICATION MARKERS ARE MISSING OR OUT OF ORDER in USP_BrowseJobs and/or USP_BrowseJobCounts. Those two comment lines are what lets the build prove the tab counts and the tab lists answer from ONE predicate; without them the guard silently stops checking, which is worse than the drift it exists to catch. Put both markers back around the classification block in BOTH procedures, unchanged.';

    RAISERROR('%s', 16, 1, @missing);
END
ELSE
BEGIN
    DECLARE @lBlk nvarchar(max) = SUBSTRING(@listSrc, @lb + LEN(@mkBegin), @le - (@lb + LEN(@mkBegin)));
    DECLARE @cBlk nvarchar(max) = SUBSTRING(@cntSrc,  @cb + LEN(@mkBegin), @ce - (@cb + LEN(@mkBegin)));

    -- Layout is not the rule; the TEXT is. Newlines and tabs to spaces, then
    -- collapse runs of spaces — each pass halves the longest run, so an
    -- indented block settles in a handful of iterations.
    SET @lBlk = REPLACE(REPLACE(REPLACE(@lBlk, CHAR(13), N' '), CHAR(10), N' '), CHAR(9), N' ');
    SET @cBlk = REPLACE(REPLACE(REPLACE(@cBlk, CHAR(13), N' '), CHAR(10), N' '), CHAR(9), N' ');

    WHILE CHARINDEX(N'  ', @lBlk) > 0 SET @lBlk = REPLACE(@lBlk, N'  ', N' ');
    WHILE CHARINDEX(N'  ', @cBlk) > 0 SET @cBlk = REPLACE(@cBlk, N'  ', N' ');

    SET @lBlk = LTRIM(RTRIM(@lBlk));
    SET @cBlk = LTRIM(RTRIM(@cBlk));

    IF @lBlk COLLATE Latin1_General_BIN2 <> @cBlk COLLATE Latin1_General_BIN2
    BEGIN
        DECLARE @drift nvarchar(1800) =
            N'017_application_reads: 🔒 USP_BrowseJobs AND USP_BrowseJobCounts NO LONGER SHARE THE SAME CANDIDATE CLASSIFICATION. One of the two blocks between the SHARED CANDIDATE CLASSIFICATION markers has been edited without the other, so the number in a tab label can now disagree with the rows in that tab — which is t_app_jobs.ApplicationCount''s bug rebuilt (see rule 3 in this file''s header). Fix it by COPYING the block from one procedure into the other; do not re-derive it. A function would be the better answer and is not available: a user-defined function cannot take a table-valued parameter, and the three set filters are TVPs.';

        RAISERROR('%s', 16, 1, @drift);
    END
END
GO

PRINT '    Application read procedures ready.';
GO
