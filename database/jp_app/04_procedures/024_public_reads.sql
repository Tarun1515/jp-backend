/*==============================================================================
  jp_app — 04_procedures / 024_public_reads.sql

  The PUBLIC surface's reads. Phase 7A.

    USP_SearchPublicJobs       the listing, server-paged
    USP_GetPublicJobByUid      one job, or NOTHING
    USP_GetPublicJobFilters    the filter masters the listing offers
    USP_GetPublicFaqs          the FAQ page
    USP_GetPublicContentBlocks designated copy, by key
    USP_IncrementJobViews      the batched view counter (2.81)
    USP_SubmitContactEnquiry   the contact form

  ---------------------------------------------------------------------------
  🔒 THIS FILE IS READ BY REQUESTS THAT CARRY NO IDENTITY
  ---------------------------------------------------------------------------
  Every other read in this product starts from a caller — a UserUid, an
  OrganizationUid, a TeacherId resolved from a token (2.39). These do not. There
  is no caller, so there is nothing to scope BY, which means the scoping has to
  be in the WHERE clause of each procedure and nowhere else.

  Consequences, all deliberate:

    · no parameter here takes a user, an organisation or a teacher;
    · nothing projects a column belonging to a teacher — not a name, not an
      application count, not a saved-job flag;
    · nothing projects a school's private contact, its plan, its quota or any
      entitlement. The 2.56 greps and the raw-bytes sweep assert both.

  ---------------------------------------------------------------------------
  🔴 WHY THESE ARE NOT USP_BrowseJobs WITH A NULL CALLER
  ---------------------------------------------------------------------------
  USP_BrowseJobs already accepts @UserUid = NULL and its own header says a
  signed-out browse "which Phase 6's public search will want" would work. It
  was still not reused, for one reason that outweighs the duplication:

      A shared procedure makes the PUBLIC contract change whenever the
      TEACHER contract changes — additively and silently.

  The day somebody adds a field to the teacher's job card, it appears on the
  anonymous surface too, and nothing fails. USP_BrowseJobs returns HasApplied,
  IsSaved and ApplicationCount today; the first two are zero for an anonymous
  caller but still SHAPE the public response around a teacher, and the third is
  a number a public page must not show (a job with no applications reads as
  unwanted).

  ⚠️ So the projections below are narrower ON PURPOSE and the overlap with
  USP_BrowseJobs is accepted. What is NOT duplicated is the business rule:
  "is this job live" is fn_EffectiveJobStatusId, one definition, called here
  exactly as the authenticated procedures call it (2.65's rule).

  ---------------------------------------------------------------------------
  ⚠️ MASTER NAMES — WRONG ONCE, AND WORTH RECORDING
  ---------------------------------------------------------------------------
  The first version of this file joined jp_mdm.dbo.m_mdm_subjectS,
  m_mdm_citieS, m_mdm_stateS … all PLURAL, and projected SubjectName,
  CityName … all of which looked right and none of which exist. The masters
  are SINGULAR and each carries Code / Name / DisplayOrder, so the display
  name is Name, aliased at the projection.

  🔴 IT COMPILED. SQL Server resolves names in a procedure body lazily, so
  every one of those was a clean CREATE and a runtime Msg 208 on the first
  call. The lesson is the project's own: a procedure that compiles has not
  been run.

  ⚠️ Two more things the real schema settled: employment types are LOCAL to
  jp_app (dbo.m_app_employment_types), not a jp_mdm master; and m_mdm_city
  joins a DISTRICT, not a state — so the city filter carries no state name and
  state is its own filter.

  ⚠️ Cross-database READS through three-part names are the established
  practice here (018_offers and 019_teacher_search both do it). 2.2 forbids
  physical FKs between databases, copied masters, and cross-DB WRITES in one
  procedure — not reads.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*==============================================================================
  USP_SearchPublicJobs — the listing.

  ---------------------------------------------------------------------------
  🔴 THE 404 WALL IS THIS WHERE CLAUSE
  ---------------------------------------------------------------------------
  A job is PUBLIC only when every one of these is true:

      j.JobStatusId = 2                    stored ACTIVE  (indexed, FIRST)
      fn_EffectiveJobStatusId(...) = 2     and not expired by IST date
      j.Is_Active = 1 AND j.Is_Deleted = 0
      the school is active, not deleted, not suspended

  ⚠️ THE ORDER OF THOSE TWO MATTERS FOR THE PLAN, and 014's header predicted
  it: the stored status is indexed and sargable, the function is not. Filtering
  on JobStatusId = 2 first keeps the seek and the date narrowing then applies to
  the rows that survived. Written the other way round this is a scan.

  🔴 A SUSPENDED SCHOOL'S JOBS VANISH FROM THE PUBLIC SITE. That is a decision,
  not a side effect: suspension is the platform saying "we are not standing
  behind this account", and a live advert is exactly the thing that should stop.
  The school's own screens still show the job — it has not been deleted.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SearchPublicJobs
    @Search       nvarchar(150) = NULL,
    @SubjectId    int           = NULL,
    @CityId       int           = NULL,
    @StateId      int           = NULL,
    @ClassLevelId int           = NULL,
    @PageNumber   int           = 1,
    @PageSize     int           = 20
AS
BEGIN
    SET NOCOUNT ON;

    IF @PageNumber IS NULL OR @PageNumber < 1 SET @PageNumber = 1;
    IF @PageSize   IS NULL OR @PageSize   < 1 SET @PageSize   = 20;

    /*
      ⚠️ A TIGHTER CEILING THAN THE AUTHENTICATED LISTS (which allow 200).

      This endpoint is anonymous and will be found by scrapers. 50 rows is a
      generous page for a human and makes "fetch the whole table in one call"
      cost a scraper fifty times more requests — which the rate limiter then
      meets. The number is here rather than in config on purpose: it is a
      shape decision about the contract, not an operational dial.
    */
    IF @PageSize > 50 SET @PageSize = 50;

    SELECT
        /*
          🔴 JobUid, never JobId (2.39). The public URL carries the uid; an
          incrementing integer in a public URL tells a competitor how many jobs
          the platform has and how fast that number grows.
        */
        j.JobUid,
        j.JobTitle,
        j.SubjectId,
        sub.Name                                                             AS SubjectName,
        j.DesignationId,
        des.Name                                                             AS DesignationName,
        j.EmploymentTypeId,
        et.Name                                                              AS EmploymentTypeName,
        j.NoOfVacancies,
        j.MinExperienceMonths,
        j.MaxExperienceMonths,
        j.SalaryMin,
        j.SalaryMax,
        j.IsSalaryNegotiable,
        j.CityId,
        c.Name                                                               AS CityName,
        j.StateId,
        st.Name                                                              AS StateName,
        j.LastDateToApply,
        j.PublishedOn,

        /* The school's PUBLIC identity. No contact, no plan — see the header. */
        s.SchoolUid,
        s.SchoolName,
        s.LogoPath   AS SchoolLogoPath,
        s.IsVerified AS IsSchoolVerified,

        TotalRecords = COUNT(*) OVER ()
    FROM dbo.t_app_jobs j
    INNER JOIN dbo.t_app_schools s ON s.SchoolId = j.SchoolId
    LEFT  JOIN jp_mdm.dbo.m_mdm_subject         sub ON sub.SubjectId        = j.SubjectId
    LEFT  JOIN jp_mdm.dbo.m_mdm_designation     des ON des.DesignationId    = j.DesignationId
    LEFT  JOIN dbo.m_app_employment_types et  ON et.EmploymentTypeId  = j.EmploymentTypeId
    LEFT  JOIN jp_mdm.dbo.m_mdm_city           c   ON c.CityId             = j.CityId
    LEFT  JOIN jp_mdm.dbo.m_mdm_state           st  ON st.StateId           = j.StateId
    WHERE j.JobStatusId = 2                       -- indexed, first
      AND j.Is_Active   = 1
      AND j.Is_Deleted  = 0
      AND dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) = 2
      AND s.Is_Active   = 1
      AND s.Is_Deleted  = 0
      AND s.IsSuspended = 0

      /*
        🔴 PRIMARY SUBJECT **OR** THE BRIDGE, exactly as USP_BrowseJobs does.

        A job carries one primary SubjectId and may carry more through
        t_app_job_subjects. Filtering on the column alone would hide every job
        whose match is a secondary subject — the visitor searching "physics"
        would silently miss jobs that are genuinely for them, and the only
        symptom is a thinner result list nobody can tell is wrong.
      */
      AND (@SubjectId IS NULL OR j.SubjectId = @SubjectId
           OR EXISTS (SELECT 1 FROM dbo.t_app_job_subjects js
                      WHERE js.JobId = j.JobId AND js.SubjectId = @SubjectId
                        AND js.Is_Deleted = 0))
      AND (@CityId       IS NULL OR j.CityId     = @CityId)
      AND (@StateId      IS NULL OR j.StateId    = @StateId)

      /*
        Class level lives on the job's own bridge table, so the filter is an
        EXISTS rather than a join — a job teaching three levels must appear
        once, not three times.
      */
      AND (@ClassLevelId IS NULL OR EXISTS (
              SELECT 1 FROM dbo.t_app_job_class_levels jcl
              WHERE jcl.JobId = j.JobId
                AND jcl.ClassLevelId = @ClassLevelId
                AND jcl.Is_Deleted = 0))

      /*
        ⚠️ Title and school name only. Not the description: a LIKE over
        nvarchar(max) on an anonymous endpoint is the cheapest way for somebody
        to make the database work hard, and a visitor searching "physics" means
        the role, not a word buried in paragraph four.
      */
      AND (@Search IS NULL OR @Search = N''
           OR j.JobTitle  LIKE N'%' + @Search + N'%'
           OR s.SchoolName LIKE N'%' + @Search + N'%')

    /*
      🔴 FEATURED FIRST, THEN NEWEST. Phase 7B.

      7A left this note in place of the clause: "Featured ordering arrives in 7B
      and goes in FRONT of this ORDER BY, derived from the featured row's date
      window — not by a column on the job and not by a sweep." This is that.

      🔴 DERIVED, AND THE IST DATE IS WHY fn_IstToday IS HERE.

      A featured row says "from this date to that date". Whether it applies
      TODAY is a comparison, made here, every time the listing is read. There
      is no IsFeatured column to keep in step — 034 fails the build if either
      featured table grows one, and 026 fails it if a procedure mentions one.

      ⚠️ fn_IstToday(), never CAST(SYSUTCDATETIME() AS date). Between 00:00 and
      05:30 IST the UTC date is still yesterday, so a UTC comparison would end
      a paid placement five and a half hours early and start one five and a
      half hours late — every night, for everybody. 2.28: storage UTC, rules
      IST. 026 carries a structural guard that every featured read depends on
      this function.

      ⚠️ EXISTS, not a JOIN. A join to the featured table would multiply a job
      by its historical windows — a job featured in January and again in March
      would appear twice in the listing, which is the kind of bug that looks
      like a paging fault.

      ⚠️ DisplayOrder is read with a correlated subquery rather than carried by
      the EXISTS, and it is NULL for an unfeatured job — which sorts last among
      the featured group and never affects the rest, because the group key
      above it has already separated them.
    */
    ORDER BY
        CASE WHEN EXISTS (SELECT 1
                            FROM dbo.t_app_featured_jobs f
                           WHERE f.JobId = j.JobId
                             AND f.Is_Deleted = 0
                             AND f.FromDate <= dbo.fn_IstToday()
                             AND f.ToDate   >= dbo.fn_IstToday())
             THEN 0 ELSE 1 END,

        (SELECT MIN(f.DisplayOrder)
           FROM dbo.t_app_featured_jobs f
          WHERE f.JobId = j.JobId
            AND f.Is_Deleted = 0
            AND f.FromDate <= dbo.fn_IstToday()
            AND f.ToDate   >= dbo.fn_IstToday()),

        j.PublishedOn DESC, j.JobId DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY;
END
GO

/*==============================================================================
  USP_GetPublicJobByUid — one job, or NOTHING.

  ---------------------------------------------------------------------------
  🔴 "NOTHING" IS THE WHOLE POINT, AND IT IS DECIDED HERE
  ---------------------------------------------------------------------------
  A draft, an expired, a closed, a soft-deleted or a moderation-pulled job
  returns ZERO ROWS from this procedure. The API turns zero rows into 404.

  ⚠️ The alternative the brief names and forbids — read it with a shared
  procedure and filter in C# — fails in a way nobody sees: the row has already
  crossed the boundary into a DTO, and the next person who adds a code path
  (an export, a cache warmer, a log line) reads a job that is not public. The
  WHERE clause cannot be forgotten by a caller.

  🔴 It takes a Uid, never an id, and there is no "include unpublished" switch.
  A parameter that can turn the wall off is a parameter somebody will pass.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetPublicJobByUid
    @JobUid uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        j.JobUid,
        j.JobTitle,
        j.JobDescription,
        j.SubjectId,
        sub.Name                                                             AS SubjectName,
        j.DesignationId,
        des.Name                                                             AS DesignationName,
        j.QualificationId,
        q.Name                                                               AS QualificationName,
        j.EmploymentTypeId,
        et.Name                                                              AS EmploymentTypeName,
        j.NoOfVacancies,
        j.MinExperienceMonths,
        j.MaxExperienceMonths,
        j.SalaryMin,
        j.SalaryMax,
        j.IsSalaryNegotiable,
        j.CityId,
        c.Name                                                               AS CityName,
        j.StateId,
        st.Name                                                              AS StateName,
        j.LastDateToApply,
        j.ExpectedJoiningDate,
        j.PublishedOn,

        /*
          The school's PUBLIC profile summary — identity and description.

          🔒 NOT ContactEmail and NOT ContactMobile, although both exist on
          t_app_schools and the brief would permit them. Two reasons:

            1. A phone number on an anonymous page is scraped within a day.
            2. It routes applications AROUND the platform — and the application
               is consent path 1 (2.56). A product whose public page invites a
               direct call has quietly removed the step its whole consent model
               is built on.

          Website is included: a school's own site is public by nature and
          bypasses nothing.
        */
        s.SchoolUid,
        s.SchoolName,
        s.LogoPath       AS SchoolLogoPath,
        s.IsVerified     AS IsSchoolVerified,
        s.AboutSchool,
        s.Website,
        s.EstablishedYear,
        s.SchoolTypeId,
        sty.Name                                                             AS SchoolTypeName,
        s.BoardId,
        brd.Name                                                             AS BoardName,

        b.BranchName,
        bc.Name          AS BranchCityName
    FROM dbo.t_app_jobs j
    INNER JOIN dbo.t_app_schools s ON s.SchoolId = j.SchoolId
    LEFT  JOIN dbo.t_app_school_branches b ON b.BranchId = j.BranchId
    LEFT  JOIN jp_mdm.dbo.m_mdm_city           bc  ON bc.CityId           = b.CityId
    LEFT  JOIN jp_mdm.dbo.m_mdm_subject         sub ON sub.SubjectId       = j.SubjectId
    LEFT  JOIN jp_mdm.dbo.m_mdm_designation     des ON des.DesignationId   = j.DesignationId
    LEFT  JOIN jp_mdm.dbo.m_mdm_qualification   q   ON q.QualificationId   = j.QualificationId
    LEFT  JOIN dbo.m_app_employment_types et  ON et.EmploymentTypeId = j.EmploymentTypeId
    LEFT  JOIN jp_mdm.dbo.m_mdm_city           c   ON c.CityId            = j.CityId
    LEFT  JOIN jp_mdm.dbo.m_mdm_state           st  ON st.StateId          = j.StateId
    LEFT  JOIN jp_mdm.dbo.m_mdm_school_type     sty ON sty.SchoolTypeId    = s.SchoolTypeId
    LEFT  JOIN jp_mdm.dbo.m_mdm_board           brd ON brd.BoardId         = s.BoardId
    WHERE j.JobUid      = @JobUid
      AND j.JobStatusId = 2
      AND j.Is_Active   = 1
      AND j.Is_Deleted  = 0
      AND dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) = 2
      AND s.Is_Active   = 1
      AND s.Is_Deleted  = 0
      AND s.IsSuspended = 0;

    /*
      The job's class levels, as a second result set. A job teaching three
      levels is three rows here and one row above — flattening them into a
      comma string would be a display decision made in SQL.
    */
    SELECT cl.ClassLevelId, cl.Name AS ClassLevelName
    FROM dbo.t_app_job_class_levels jcl
    INNER JOIN dbo.t_app_jobs j ON j.JobId = jcl.JobId
    INNER JOIN dbo.t_app_schools s ON s.SchoolId = j.SchoolId
    INNER JOIN jp_mdm.dbo.m_mdm_class_level cl ON cl.ClassLevelId = jcl.ClassLevelId
    WHERE j.JobUid     = @JobUid
      AND jcl.Is_Deleted = 0
      AND j.JobStatusId  = 2
      AND j.Is_Active    = 1
      AND j.Is_Deleted   = 0
      AND dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) = 2
      AND s.Is_Active    = 1
      AND s.Is_Deleted   = 0
      AND s.IsSuspended  = 0
    ORDER BY cl.DisplayOrder, cl.ClassLevelId;
END
GO

/*==============================================================================
  USP_GetPublicJobFilters — what the listing may be filtered by.

  ⚠️ ONLY VALUES THAT CAN RETURN A JOB. A filter listing every subject in the
  master gives a visitor forty options, thirty-eight of which produce an empty
  page — and an empty result on a public site reads as a broken product rather
  than a narrow filter. Same discipline as the app-master whitelist's
  "reachable rows only".
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetPublicJobFilters
AS
BEGIN
    SET NOCOUNT ON;

    /*
      The live-job predicate repeated across four small reads. It is the one
      place in this file that repeats, and the alternative — a temp table of
      live JobIds — costs more than it saves at this size. The PREDICATE itself
      is still fn_EffectiveJobStatusId; only the surrounding filter is typed
      out, and if that ever drifts the 404 wall's own suite catches it.
    */
    SELECT sub.SubjectId AS Id, sub.Name AS Name, COUNT(*) AS JobCount
    FROM dbo.t_app_jobs j
    INNER JOIN dbo.t_app_schools s ON s.SchoolId = j.SchoolId
    INNER JOIN jp_mdm.dbo.m_mdm_subject sub ON sub.SubjectId = j.SubjectId
    WHERE j.JobStatusId = 2 AND j.Is_Active = 1 AND j.Is_Deleted = 0
      AND dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) = 2
      AND s.Is_Active = 1 AND s.Is_Deleted = 0 AND s.IsSuspended = 0
    GROUP BY sub.SubjectId, sub.Name
    ORDER BY sub.Name;

    SELECT c.CityId AS Id, c.Name AS Name, COUNT(*) AS JobCount
    FROM dbo.t_app_jobs j
    INNER JOIN dbo.t_app_schools s ON s.SchoolId = j.SchoolId
    INNER JOIN jp_mdm.dbo.m_mdm_city c ON c.CityId = j.CityId
    WHERE j.JobStatusId = 2 AND j.Is_Active = 1 AND j.Is_Deleted = 0
      AND dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) = 2
      AND s.Is_Active = 1 AND s.Is_Deleted = 0 AND s.IsSuspended = 0
    GROUP BY c.CityId, c.Name
    ORDER BY c.Name;

    SELECT st.StateId AS Id, st.Name AS Name, COUNT(*) AS JobCount
    FROM dbo.t_app_jobs j
    INNER JOIN dbo.t_app_schools s ON s.SchoolId = j.SchoolId
    INNER JOIN jp_mdm.dbo.m_mdm_state st ON st.StateId = j.StateId
    WHERE j.JobStatusId = 2 AND j.Is_Active = 1 AND j.Is_Deleted = 0
      AND dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) = 2
      AND s.Is_Active = 1 AND s.Is_Deleted = 0 AND s.IsSuspended = 0
    GROUP BY st.StateId, st.Name
    ORDER BY st.Name;

    SELECT cl.ClassLevelId AS Id, cl.Name AS Name, COUNT(DISTINCT j.JobId) AS JobCount
    FROM dbo.t_app_jobs j
    INNER JOIN dbo.t_app_schools s ON s.SchoolId = j.SchoolId
    INNER JOIN dbo.t_app_job_class_levels jcl ON jcl.JobId = j.JobId AND jcl.Is_Deleted = 0
    INNER JOIN jp_mdm.dbo.m_mdm_class_level cl ON cl.ClassLevelId = jcl.ClassLevelId
    WHERE j.JobStatusId = 2 AND j.Is_Active = 1 AND j.Is_Deleted = 0
      AND dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) = 2
      AND s.Is_Active = 1 AND s.Is_Deleted = 0 AND s.IsSuspended = 0
    GROUP BY cl.ClassLevelId, cl.Name, cl.DisplayOrder
    ORDER BY cl.DisplayOrder, cl.Name;
END
GO

/*==============================================================================
  USP_GetPublicFaqs — the FAQ page's content.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetPublicFaqs
AS
BEGIN
    SET NOCOUNT ON;

    SELECT f.FaqId, f.Category, f.Question, f.Answer, f.DisplayOrder
    FROM dbo.t_app_faqs f
    WHERE f.Is_Active = 1 AND f.Is_Deleted = 0
    ORDER BY
        /*
          ⚠️ Category order is the PRODUCT's, not alphabetical: the page reads
          Teachers, then Schools, then General, because that is the order of
          how many people are asking. Alphabetical would put General first.
        */
        CASE f.Category WHEN 'TEACHER' THEN 1 WHEN 'SCHOOL' THEN 2 ELSE 3 END,
        f.DisplayOrder,
        f.FaqId;
END
GO

/*==============================================================================
  USP_GetPublicContentBlocks — designated copy, by key.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetPublicContentBlocks
AS
BEGIN
    SET NOCOUNT ON;

    SELECT b.BlockKey, b.BlockTitle, b.BlockContent, b.ImagePath, b.DisplayOrder
    FROM dbo.t_app_cms_content_blocks b
    WHERE b.Is_Active = 1 AND b.Is_Deleted = 0
    ORDER BY b.DisplayOrder, b.BlockKey;
END
GO

/*==============================================================================
  USP_IncrementJobViews — the batched view counter (2.81).

  ---------------------------------------------------------------------------
  🔴 A TABLE-VALUED PARAMETER, BECAUSE THE CALLER BATCHES
  ---------------------------------------------------------------------------
  2.81 decided ViewCount is the ONE stored counter in a system where every
  other count is derived, and that its write path keeps the read PURE: the API
  writes job uids to a channel and a background service drains them every ten
  seconds into one call here.

  So this takes a SET of uids and does one UPDATE. A hot job viewed two hundred
  times in ten seconds is one row touched once, with +200 — not two hundred
  updates racing for its page latch.

  ⚠️ It is the only procedure in this file that WRITES, and it writes a number
  nothing branches on. The guard at the foot of this file asserts that nothing
  filters or orders by ViewCount, which is the boundary 2.81's acceptance
  depends on.

  🔴 It does NOT check whether the job is public. By the time a uid reaches
  here the public read has already allowed it — and re-checking would make the
  counter lie differently (a job pulled between the view and the flush would
  lose a view that genuinely happened).
==============================================================================*/
IF TYPE_ID(N'dbo.JobViewBatch') IS NULL
BEGIN
    PRINT '    Creating type [JobViewBatch] ...';

    CREATE TYPE dbo.JobViewBatch AS TABLE
    (
        JobUid    uniqueidentifier NOT NULL,
        ViewCount int              NOT NULL,
        PRIMARY KEY (JobUid)
    );
END
ELSE
    PRINT '    Type [JobViewBatch] already exists — skipped.';
GO

CREATE OR ALTER PROCEDURE dbo.USP_IncrementJobViews
    @Views dbo.JobViewBatch READONLY
AS
BEGIN
    SET NOCOUNT ON;

    UPDATE j
       SET j.ViewCount = j.ViewCount + v.ViewCount
    FROM dbo.t_app_jobs j
    INNER JOIN @Views v ON v.JobUid = j.JobUid
    WHERE j.Is_Deleted = 0;

    /* Rows actually touched, so the service can log a flush that found nothing. */
    SELECT @@ROWCOUNT AS JobsUpdated;
END
GO

/*==============================================================================
  USP_SubmitContactEnquiry — the contact form.

  ---------------------------------------------------------------------------
  🔒 NO HONEYPOT PARAMETER, AND THAT IS NOT AN OVERSIGHT
  ---------------------------------------------------------------------------
  The honeypot is decided in the API layer: a filled hidden field returns 200
  and NEVER REACHES HERE. Passing it down would mean this procedure deciding
  whether to insert — and the first person to read it would reasonably add a
  row "for analysis", which is the table-full-of-bots this avoids.

  ⚠️ No identity parameter either. There is no caller (033's header), and the
  build guard there fails if an identity column ever appears.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SubmitContactEnquiry
    @Name    nvarchar(100),
    @Email   nvarchar(256),
    @Mobile  varchar(15)    = NULL,
    @Subject nvarchar(200),
    @Message nvarchar(2000)
AS
BEGIN
    SET NOCOUNT ON;

    INSERT INTO dbo.t_app_contact_enquiries (Name, Email, Mobile, [Subject], [Message])
    VALUES (@Name, @Email, NULLIF(LTRIM(RTRIM(ISNULL(@Mobile, ''))), ''), @Subject, @Message);

    /*
      ⚠️ The id is returned but the API does NOT show it to the visitor. A
      reference number on a contact form promises a tracking system that does
      not exist; what the visitor gets is "we have it, we will reply to this
      address". The id is for the log line.
    */
    SELECT Status = 1, Code = NULL,
           [Message] = N'Thank you — we have your message and will reply by email.',
           EnquiryId = CAST(SCOPE_IDENTITY() AS bigint);
END
GO

/*==============================================================================
  BUILD GUARDS
==============================================================================*/
DECLARE @missing nvarchar(400) = N'';

IF OBJECT_ID('dbo.USP_SearchPublicJobs', 'P')       IS NULL SET @missing = @missing + N'SearchPublicJobs ';
IF OBJECT_ID('dbo.USP_GetPublicJobByUid', 'P')      IS NULL SET @missing = @missing + N'GetPublicJobByUid ';
IF OBJECT_ID('dbo.USP_GetPublicJobFilters', 'P')    IS NULL SET @missing = @missing + N'GetPublicJobFilters ';
IF OBJECT_ID('dbo.USP_GetPublicFaqs', 'P')          IS NULL SET @missing = @missing + N'GetPublicFaqs ';
IF OBJECT_ID('dbo.USP_GetPublicContentBlocks', 'P') IS NULL SET @missing = @missing + N'GetPublicContentBlocks ';
IF OBJECT_ID('dbo.USP_IncrementJobViews', 'P')      IS NULL SET @missing = @missing + N'IncrementJobViews ';
IF OBJECT_ID('dbo.USP_SubmitContactEnquiry', 'P')   IS NULL SET @missing = @missing + N'SubmitContactEnquiry ';

IF @missing <> N''
    RAISERROR('024_public_reads: missing after run: %s', 16, 1, @missing);
GO

/*==============================================================================
  🔒 THE PUBLIC PROCEDURES MAY NOT NAME A TEACHER OR AN ENTITLEMENT.

  2.56's grep runs over the FILES; this runs over what the server actually
  compiled, which is the half a comment cannot fake. Checked by DEPENDENCY, not
  by text — 6.5A learned that a guard naming what it bans is itself code naming
  it, and sys.sql_expression_dependencies cannot be fooled by a comment and
  catches an indirect reference through a view.
==============================================================================*/
DECLARE @breach nvarchar(1000) = N'';

SELECT @breach = STRING_AGG(
           OBJECT_NAME(d.referencing_id) + ' -> ' + d.referenced_entity_name, ', ')
  FROM sys.sql_expression_dependencies d
 WHERE d.referencing_id IN (
           OBJECT_ID('dbo.USP_SearchPublicJobs'),
           OBJECT_ID('dbo.USP_GetPublicJobByUid'),
           OBJECT_ID('dbo.USP_GetPublicJobFilters'),
           OBJECT_ID('dbo.USP_GetPublicFaqs'),
           OBJECT_ID('dbo.USP_GetPublicContentBlocks'),
           OBJECT_ID('dbo.USP_SubmitContactEnquiry'))
   AND d.referenced_entity_name IN (
           't_app_teachers', 't_app_teacher_subjects', 't_app_teacher_experiences',
           't_app_teacher_documents', 't_app_teacher_languages',
           't_app_applications', 't_app_saved_jobs', 't_app_teacher_invites',
           'fn_TeacherContactUnlocked',
           't_app_subscriptions', 't_app_feature_ledger');

IF ISNULL(@breach, N'') <> N''
    RAISERROR('024_public_reads: 🔒 A PUBLIC PROCEDURE DEPENDS ON TEACHER OR ENTITLEMENT DATA: %s. The public surface carries zero teacher data and no entitlement (2.81, 2.56 LOCKED).', 16, 1, @breach);
GO

/*
  🔴 ViewCount MAY NOT BE FILTERED OR ORDERED BY — the boundary 2.81's
  acceptance rests on.

  2.81 accepted ONE stored counter in a system where every other count is
  derived, and the acceptance was explicitly bounded: nothing branches on
  ViewCount. The day a procedure sorts by it, the number stops being a vanity
  display and starts deciding what a visitor sees — and then a drifted counter
  is a drifted product.

  ⚠️ A text check, deliberately, because that is the only way to see an ORDER
  BY — dependency metadata records the column, not the clause it appears in.

  🔴 AND THE FIRST VERSION OF IT WAS WRONG, IN THE WAY TEXT GUARDS ARE ALWAYS
  WRONG. It asked for '%ORDER BY%ViewCount%' and '%WHERE%j.ViewCount%', where
  each % spans the ENTIRE procedure body: any WHERE clause anywhere, followed
  by the column anywhere later, matched. So it could not tell a filter from a
  projection.

  It passed for two phases because no single procedure happened to contain
  both. 8A's run_all audit put 025 in the same database, and 025 PROJECTS
  j.ViewCount for the moderator — a column on a queue, not a decision — and
  this guard failed the whole build over it.

  ⚠️ WHY THAT WAS ONLY FOUND NOW, which is the more useful half: when 024 was
  deployed by hand in 7A, 025 did not exist yet. A guard that reads
  sys.sql_modules sees whatever is in the DATABASE, so its result depends on
  what else has been deployed — and a full ordered build is the only run that
  shows it. The audit that found eleven files missing from run_all found this
  too.

  So the patterns below name the SYNTAX that can only be a filter or a sort,
  never a projection: a comparison operator beside the column, or an ordering
  keyword. A projection reads "j.ViewCount," and matches none of them.
*/
/*
  ⚠️ ONE PATTERN LIST, NOT TWO. The first tightening duplicated the whole OR
  chain — once to decide whether to fail and once to name the offender — which
  is two places for the next person to update and one of them to forget. The
  offenders are collected first; having them IS the decision.

  ⚠️ AND ONE NAME IS ALLOWED, because the tightened guard immediately caught
  the writer: USP_IncrementJobViews says SET ViewCount = ViewCount + 1, which
  matches a comparison pattern and is the one procedure in this system whose
  job is to maintain this counter. LIKE cannot tell SET from WHERE, so the
  writer is named here instead — and a SECOND procedure assigning to it fails
  this, which is the thing worth catching.
*/
DECLARE @vc nvarchar(1000) = N'';

SELECT @vc = STRING_AGG(CAST(OBJECT_NAME(m.object_id) AS nvarchar(128)), N', ')
  FROM sys.sql_modules m
 WHERE OBJECT_NAME(m.object_id) <> 'USP_IncrementJobViews'
   AND (m.definition LIKE '%ViewCount DESC%'
     OR m.definition LIKE '%ViewCount ASC%'
     OR m.definition LIKE '%BY ViewCount%'
     OR m.definition LIKE '%BY j.ViewCount%'
     OR m.definition LIKE '%ViewCount >%'
     OR m.definition LIKE '%ViewCount <%'
     OR m.definition LIKE '%ViewCount =%'
     OR m.definition LIKE '%ViewCount>%'
     OR m.definition LIKE '%ViewCount<%'
     OR m.definition LIKE '%ViewCount BETWEEN%'
     OR m.definition LIKE '%ViewCount IN (%');

IF ISNULL(@vc, N'') <> N''
BEGIN
    DECLARE @vcMsg nvarchar(1400) =
        N'024_public_reads: 🔴 A PROCEDURE FILTERS OR ORDERS BY ViewCount: '
        + @vc
        + N'. 2.81 accepted one stored counter in a system where every other count is derived, on the stated condition that nothing branches on it — a maintained counter that decides what a visitor sees is a drifted product. Derive it first. Projecting the column is fine; sorting or filtering on it is not.';

    RAISERROR('%s', 16, 1, @vcMsg);
END
GO

PRINT '    Public reads ready (jobs, filters, faqs, blocks, views, enquiry).';
GO
