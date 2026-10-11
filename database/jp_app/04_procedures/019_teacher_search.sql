/*==============================================================================
  jp_app — 04_procedures / 019_teacher_search.sql

  USP_SearchTeachers — the school finds teachers.

  Phase 6B.

  ---------------------------------------------------------------------------
  🔒 NO CONTACT COLUMN APPEARS IN THIS FILE. NOT ONE. (2.56, LOCKED)
  ---------------------------------------------------------------------------
  Not email, not mobile, not ResumePath, not UserUid. Not nulled out — ABSENT
  from the SELECT, which is the rule 3D set for the browse surface and 5A
  restated for the applicant list.

  ⚠️ AND THE REASON IS DIFFERENT HERE, which is why it is worth saying twice.
  On the applicant list every row HAS consented, so a contact column would
  break the shape without breaking the rule. In SEARCH, almost nobody has
  consented: a school can search the entire teacher base, and the people it
  finds have never heard of it. A contact column here would break the rule
  itself — for every teacher on the platform, at once.

  🔴 So there is no "unlocked" branch in this procedure, no CASE WHEN, no
  fn_TeacherContactUnlocked call. The question is not asked because the answer
  must not be acted on: search is a browse surface and a browse surface has no
  business carrying a phone number, even one it would be allowed to show.
  Contact lives on exactly two reads — USP_GetTeacherContactForSchool and
  USP_GetApplicantById — and both go through that function.

  ⚠️ No plan, no flag, no role changes this. A school with every feature
  enabled and a paid subscription sees exactly the same columns as one with
  nothing: 2.56 sells the CAPABILITY to search, never the contact details of
  the people found.

  ---------------------------------------------------------------------------
  🔴 PAGING AND FILTERING ARE SERVER-SIDE, FROM THE FIRST COMMIT (G29)
  ---------------------------------------------------------------------------
  G29 recorded the opposite choice on the applicant list — search and paging
  there run over the rows already fetched, under a 200-row cap, and the screen
  says so. That was defensible because a school has tens of applicants.

  Teacher search is the one place in this product where the volume is REAL: a
  school searches the whole platform, and "fetch everything and filter in the
  browser" would ship the entire teacher base to a laptop to render twenty
  rows. So OFFSET/FETCH and a windowed total, here, now — not when it starts
  hurting.

  ⚠️ The total is computed with COUNT(*) OVER() in the same pass rather than a
  second query, so the count and the page cannot describe different result
  sets — which is what two queries against a moving table eventually do.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


CREATE OR ALTER PROCEDURE dbo.USP_SearchTeachers
    /*
      🔴 The viewer's school. Taken so the result can say whether THIS school
      already has an open invite with each teacher — not to decide what columns
      come back. Nothing about the school changes the projection.
    */
    @SchoolId           bigint,

    @SubjectId          int = NULL,
    @DesignationId      int = NULL,
    @QualificationId    int = NULL,
    @ClassLevelId       int = NULL,
    @CityId             int = NULL,
    @StateId            int = NULL,

    /*
      ⚠️ A RANGE ID, NOT A PAIR OF NUMBERS. The boundaries live in
      m_mdm_experience_range (MinMonths / MaxMonths) so the client can change
      what "3 - 5 years" means without a deployment (2.7). A procedure carrying
      its own month arithmetic would be the second definition.
    */
    @ExperienceRangeId  int = NULL,

    /** Only teachers whose documents have been verified. A filter, never a gate. */
    @VerifiedOnly       bit = 0,

    @PageNumber         int = 1,
    @PageSize           int = 20
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;

    /*
      ⚠️ CLAMPED, not trusted. A page size arriving as 100000 from a query
      string would turn a paged endpoint back into "fetch everything" — which
      is the exact thing this procedure exists to avoid.
    */
    IF @PageSize IS NULL OR @PageSize < 1 SET @PageSize = 20;
    IF @PageSize > 100 SET @PageSize = 100;

    DECLARE @MinMonths int = NULL, @MaxMonths int = NULL;

    IF @ExperienceRangeId IS NOT NULL
        SELECT @MinMonths = r.MinMonths, @MaxMonths = r.MaxMonths
        FROM jp_mdm.dbo.m_mdm_experience_range r
        WHERE r.ExperienceRangeId = @ExperienceRangeId
          AND r.Is_Deleted = 0
          AND r.Is_Active  = 1;

    SELECT
        /*
          🔒 THE PUBLIC PROJECTION, and it is the same set of columns
          USP_GetTeacherPublicProfile publishes — deliberately, so there is one
          answer to "what may a school see about a teacher who has not
          consented" rather than two that drift.
        */
        t.TeacherUid,
        t.FullName,
        t.PhotoPath,
        t.GenderId,
        t.QualificationId,
        t.HighestQualificationText,
        t.DesignationId,
        t.TotalExperienceMonths,
        t.CurrentSchool,
        t.ExpectedSalaryMin,
        t.ExpectedSalaryMax,
        t.CurrentCityId,
        t.CurrentStateId,

        /*
          ⚠️ A SIGNAL, NOT A GATE (2.9, a locked stance). An unverified teacher
          appears in search unless the school explicitly filters them out, and
          the badge tells a school what has been checked. The product must not
          decide for them.
        */
        t.IsVerified,
        t.ProfileCompletionPercent,

        /*
          🔴 WHAT THIS SCHOOL ALREADY HAS WITH THIS TEACHER — so the screen can
          show "invited" instead of offering a button that would be refused by
          the unique index.

          ⚠️ These are facts about the SCHOOL's own rows, which is why they are
          allowed here: they say nothing about the teacher that the school does
          not already know it did.
        */
        CAST(CASE WHEN EXISTS (
            SELECT 1 FROM dbo.t_app_teacher_invites i
            WHERE i.TeacherId = t.TeacherId AND i.SchoolId = @SchoolId
              AND i.InviteStatusId IN (1, 2) AND i.Is_Deleted = 0
        ) THEN 1 ELSE 0 END AS bit)                           AS HasOpenInvite,

        CAST(CASE WHEN EXISTS (
            SELECT 1 FROM dbo.t_app_applications a
            WHERE a.TeacherId = t.TeacherId AND a.SchoolId = @SchoolId
              AND a.Is_Deleted = 0
        ) THEN 1 ELSE 0 END AS bit)                           AS HasApplied,

        t.Is_Active                                           AS IsActive,   -- 🔴 2.61

        -- 🔴 The total, in the same pass. See the header.
        COUNT(*) OVER ()                                      AS TotalRecords

    FROM dbo.t_app_teachers t

    WHERE t.Is_Deleted  = 0
      AND t.Is_Active   = 1

      /*
        🔴 SUSPENDED TEACHERS ARE EXCLUDED, and this is an administrative
        decision that has to reach the listing or it is cosmetic — the same
        argument 5A made for a suspended school's jobs.
      */
      AND t.IsSuspended = 0

      AND (@VerifiedOnly = 0 OR t.IsVerified = 1)
      AND (@DesignationId IS NULL OR t.DesignationId = @DesignationId)
      AND (@QualificationId IS NULL OR t.QualificationId = @QualificationId)
      AND (@CityId IS NULL OR t.CurrentCityId = @CityId)
      AND (@StateId IS NULL OR t.CurrentStateId = @StateId)

      -- ⚠️ MaxMonths is NULL on the open-ended top range (10+ years).
      AND (@MinMonths IS NULL OR ISNULL(t.TotalExperienceMonths, 0) >= @MinMonths)
      AND (@MaxMonths IS NULL OR ISNULL(t.TotalExperienceMonths, 0) <= @MaxMonths)

      AND (@SubjectId IS NULL OR EXISTS (
            SELECT 1 FROM dbo.t_app_teacher_subjects ts
            WHERE ts.TeacherId = t.TeacherId AND ts.SubjectId = @SubjectId AND ts.Is_Deleted = 0))

      AND (@ClassLevelId IS NULL OR EXISTS (
            SELECT 1 FROM dbo.t_app_teacher_class_levels tc
            WHERE tc.TeacherId = t.TeacherId AND tc.ClassLevelId = @ClassLevelId AND tc.Is_Deleted = 0))

    /*
      ⚠️ A DETERMINISTIC ORDER, and the tiebreaker is not decoration. Paging
      over a non-unique sort means a row can appear on page 1 and page 2 while
      another never appears at all — and nobody notices, because each page
      looks fine on its own.

      Completeness first because it is what makes a profile useful to a school;
      TeacherId last because it is unique.
    */
    ORDER BY t.ProfileCompletionPercent DESC, t.TeacherId
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO


PRINT '    Teacher search procedure ready.';
GO
