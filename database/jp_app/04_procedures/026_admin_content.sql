/*==============================================================================
  jp_app — 04_procedures / 026_admin_content.sql

  PHASE 7B — featured placement, the site's copy, and the enquiries queue.

    USP_SaveFeaturedJob        / USP_SaveFeaturedSchool
    USP_ListFeatured           both kinds, with "is it live today"
    USP_RemoveFeatured         soft-deletes one window
    USP_SaveFaq                / USP_DeleteFaq / USP_ListFaqsForAdmin
    USP_SaveContentBlock       / USP_ListContentBlocksForAdmin
    USP_SearchEnquiries        / USP_ResolveEnquiry

  ---------------------------------------------------------------------------
  🔴 "FEATURED TODAY" IS A COMPARISON, AND TODAY IS AN IST DATE
  ---------------------------------------------------------------------------
  Nothing stores whether a row is currently featured. Every read computes it:

      FromDate <= dbo.fn_IstToday() AND ToDate >= dbo.fn_IstToday()

  ⚠️ fn_IstToday(), NEVER CAST(SYSUTCDATETIME() AS date). Between 00:00 and
  05:30 IST the UTC date is still YESTERDAY, so a UTC comparison would end a
  feature five and a half hours early and start one five and a half hours late
  — every night, for everybody. It is the same trap 7A's job-expiry boundary
  had, and 2.28 is the rule it breaks (storage UTC, rules IST).

  🔴 AND THERE IS NO SWEEP. A window that has ended is simply a row whose
  ToDate has passed; nothing runs to notice. 2.5 made this choice for quota
  periods and 021 for job expiry, with the same reasoning: a scheduled job is
  one that will eventually not run, and its failure is silent. 034's guard
  fails the build if either table grows a stored flag.

  ---------------------------------------------------------------------------
  ⚠️ OVERLAPPING WINDOWS ARE REFUSED, AND THAT IS NOT FUSSINESS
  ---------------------------------------------------------------------------
  A job may be featured in January and again in March — two rows, no problem.
  What is refused is two windows for one job that overlap, because then two
  rows are live at once and which DisplayOrder applies is undefined. The
  listing would order by whichever the query happened to read first.
==============================================================================*/

USE jp_app;
GO

SET NOCOUNT ON;
GO

/*==============================================================================
  USP_SaveFeaturedJob
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveFeaturedJob
    @FeaturedUid   uniqueidentifier = NULL,   -- reserved; windows are addressed by id today
    @JobUid        uniqueidentifier,
    @FromDate      date,
    @ToDate        date,
    @DisplayOrder  int = 0,
    @ActorUserId   bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @JobId bigint = NULL;

    SELECT @JobId = JobId FROM dbo.t_app_jobs WHERE JobUid = @JobUid AND Is_Deleted = 0;

    IF @JobId IS NULL
    BEGIN
        SELECT Status = 0, Code = 'NOT_FOUND', [Message] = N'That job was not found.';
        RETURN;
    END

    IF @ToDate < @FromDate
    BEGIN
        SELECT Status = 0, Code = 'BAD_WINDOW',
               [Message] = N'The end date cannot be before the start date.';
        RETURN;
    END

    /*
      ⚠️ OVERLAP, not duplication. Two live windows for one job make
      DisplayOrder ambiguous — see this file's header. Standard interval
      overlap: the new window starts before the old one ends AND ends after the
      old one starts.
    */
    IF EXISTS (SELECT 1 FROM dbo.t_app_featured_jobs f
                WHERE f.JobId = @JobId
                  AND f.Is_Deleted = 0
                  AND f.FromDate <= @ToDate
                  AND f.ToDate   >= @FromDate)
    BEGIN
        SELECT Status = 0, Code = 'WINDOW_OVERLAPS',
               [Message] = N'This job already has a featured window overlapping those dates.';
        RETURN;
    END

    /*
      ⚠️ A PULLED job may not be featured. Promoting an advert that moderation
      has taken down would put it back in front of people through a different
      door — and the public listing filters on status anyway, so the row would
      be a promise the site does not keep.
    */
    IF EXISTS (SELECT 1 FROM dbo.t_app_jobs WHERE JobId = @JobId AND JobStatusId = 5)
    BEGIN
        SELECT Status = 0, Code = 'JOB_PULLED',
               [Message] = N'That job has been pulled by moderation and cannot be featured.';
        RETURN;
    END

    INSERT INTO dbo.t_app_featured_jobs (JobId, FromDate, ToDate, DisplayOrder, CreatedBy)
    VALUES (@JobId, @FromDate, @ToDate, ISNULL(@DisplayOrder, 0), @ActorUserId);

    SELECT Status = 1, Code = NULL, [Message] = N'The job will be featured for those dates.';
END
GO

/*==============================================================================
  USP_SaveFeaturedSchool
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveFeaturedSchool
    @SchoolUid    uniqueidentifier,
    @FromDate     date,
    @ToDate       date,
    @DisplayOrder int = 0,
    @ActorUserId  bigint
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @SchoolId bigint = NULL;

    SELECT @SchoolId = SchoolId FROM dbo.t_app_schools WHERE SchoolUid = @SchoolUid AND Is_Deleted = 0;

    IF @SchoolId IS NULL
    BEGIN
        SELECT Status = 0, Code = 'NOT_FOUND', [Message] = N'That school was not found.';
        RETURN;
    END

    IF @ToDate < @FromDate
    BEGIN
        SELECT Status = 0, Code = 'BAD_WINDOW',
               [Message] = N'The end date cannot be before the start date.';
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.t_app_featured_schools f
                WHERE f.SchoolId = @SchoolId
                  AND f.Is_Deleted = 0
                  AND f.FromDate <= @ToDate
                  AND f.ToDate   >= @FromDate)
    BEGIN
        SELECT Status = 0, Code = 'WINDOW_OVERLAPS',
               [Message] = N'This school already has a featured window overlapping those dates.';
        RETURN;
    END

    /*
      ⚠️ A SUSPENDED school may not be featured, for the same reason a pulled
      job may not: the public reads exclude it, so the row would promise a
      placement the site does not honour.
    */
    IF EXISTS (SELECT 1 FROM dbo.t_app_schools WHERE SchoolId = @SchoolId AND IsSuspended = 1)
    BEGIN
        SELECT Status = 0, Code = 'SCHOOL_SUSPENDED',
               [Message] = N'That school is suspended and cannot be featured.';
        RETURN;
    END

    INSERT INTO dbo.t_app_featured_schools (SchoolId, FromDate, ToDate, DisplayOrder, CreatedBy)
    VALUES (@SchoolId, @FromDate, @ToDate, ISNULL(@DisplayOrder, 0), @ActorUserId);

    SELECT Status = 1, Code = NULL, [Message] = N'The school will be featured for those dates.';
END
GO

/*==============================================================================
  USP_ListFeatured — both kinds, with "is it live today".

  🔴 IsLiveToday IS COMPUTED HERE AND STORED NOWHERE. The admin screen shows a
  window's state; the state is a comparison against the IST date, made at read
  time. See this file's header.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ListFeatured
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today date = dbo.fn_IstToday();

    /* Jobs. */
    SELECT
        f.FeaturedJobId AS FeaturedId,
        'JOB'           AS FeaturedType,
        j.JobUid        AS EntityUid,
        j.JobTitle      AS EntityName,
        s.SchoolName    AS OwnerName,
        f.FromDate,
        f.ToDate,
        f.DisplayOrder,

        CASE WHEN f.FromDate <= @Today AND f.ToDate >= @Today
             THEN CAST(1 AS tinyint) ELSE CAST(0 AS tinyint) END AS IsLiveToday,

        /*
          ⚠️ The job's own status travels with it, because a featured window on
          a job that has since been closed or pulled is a window that will
          never show — and the admin should see why without opening the job.
        */
        js.Name AS EntityStatusName
      FROM dbo.t_app_featured_jobs f
      INNER JOIN dbo.t_app_jobs j        ON j.JobId = f.JobId
      INNER JOIN dbo.t_app_schools s     ON s.SchoolId = j.SchoolId
      INNER JOIN dbo.m_app_job_status js ON js.JobStatusId = j.JobStatusId
     WHERE f.Is_Deleted = 0
     ORDER BY
        CASE WHEN f.FromDate <= @Today AND f.ToDate >= @Today THEN 0 ELSE 1 END,
        f.FromDate DESC,
        f.DisplayOrder;

    /* Schools. */
    SELECT
        f.FeaturedSchoolId AS FeaturedId,
        'SCHOOL'           AS FeaturedType,
        s.SchoolUid        AS EntityUid,
        s.SchoolName       AS EntityName,
        CAST(NULL AS nvarchar(200)) AS OwnerName,
        f.FromDate,
        f.ToDate,
        f.DisplayOrder,

        CASE WHEN f.FromDate <= @Today AND f.ToDate >= @Today
             THEN CAST(1 AS tinyint) ELSE CAST(0 AS tinyint) END AS IsLiveToday,

        CASE WHEN s.IsSuspended = 1 THEN N'Suspended' ELSE N'Active' END AS EntityStatusName
      FROM dbo.t_app_featured_schools f
      INNER JOIN dbo.t_app_schools s ON s.SchoolId = f.SchoolId
     WHERE f.Is_Deleted = 0
     ORDER BY
        CASE WHEN f.FromDate <= @Today AND f.ToDate >= @Today THEN 0 ELSE 1 END,
        f.FromDate DESC,
        f.DisplayOrder;
END
GO

/*==============================================================================
  USP_RemoveFeatured — one window, soft-deleted.

  ⚠️ SOFT, not hard. "Who featured this school in March, and when did somebody
  take it down?" is a question about a commercial placement, and a deleted row
  cannot answer it.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_RemoveFeatured
    @FeaturedType varchar(10),
    @FeaturedId   bigint,
    @ActorUserId  bigint
AS
BEGIN
    SET NOCOUNT ON;

    IF @FeaturedType NOT IN ('JOB', 'SCHOOL')
    BEGIN
        SELECT Status = 0, Code = 'BAD_TYPE', [Message] = N'That is not a featured type.';
        RETURN;
    END

    DECLARE @Affected int = 0;

    IF @FeaturedType = 'JOB'
    BEGIN
        UPDATE dbo.t_app_featured_jobs
           SET Is_Deleted = 1, ModifiedOn = SYSUTCDATETIME(), ModifiedBy = @ActorUserId
         WHERE FeaturedJobId = @FeaturedId AND Is_Deleted = 0;

        SET @Affected = @@ROWCOUNT;
    END
    ELSE
    BEGIN
        UPDATE dbo.t_app_featured_schools
           SET Is_Deleted = 1, ModifiedOn = SYSUTCDATETIME(), ModifiedBy = @ActorUserId
         WHERE FeaturedSchoolId = @FeaturedId AND Is_Deleted = 0;

        SET @Affected = @@ROWCOUNT;
    END

    IF @Affected = 0
    BEGIN
        SELECT Status = 0, Code = 'NOT_FOUND', [Message] = N'That featured window was not found.';
        RETURN;
    END

    SELECT Status = 1, Code = NULL, [Message] = N'The featured window has been removed.';
END
GO

/*==============================================================================
  USP_SaveFaq — insert or update one question.

  ⚠️ 003_seed_public_faqs is insert-if-absent precisely so an admin's edits
  here survive a deploy. This is the other half of that decision.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveFaq
    @FaqId        int = NULL,
    @Category     varchar(10),
    @Question     nvarchar(600),
    @Answer       nvarchar(4000),
    @DisplayOrder int = 0,
    @IsActive     tinyint = 1,
    @ActorUserId  bigint
AS
BEGIN
    SET NOCOUNT ON;

    IF @Category NOT IN ('TEACHER', 'SCHOOL', 'GENERAL')
    BEGIN
        SELECT Status = 0, Code = 'BAD_CATEGORY',
               [Message] = N'A FAQ belongs to teachers, schools, or everyone.';
        RETURN;
    END

    IF LEN(LTRIM(RTRIM(ISNULL(@Question, N'')))) = 0
        OR LEN(LTRIM(RTRIM(ISNULL(@Answer, N'')))) = 0
    BEGIN
        SELECT Status = 0, Code = 'VALIDATION',
               [Message] = N'A FAQ needs both a question and an answer.';
        RETURN;
    END

    IF @FaqId IS NULL
    BEGIN
        INSERT INTO dbo.t_app_faqs (Category, Question, Answer, DisplayOrder, Is_Active, CreatedBy)
        VALUES (@Category, LTRIM(RTRIM(@Question)), LTRIM(RTRIM(@Answer)),
                ISNULL(@DisplayOrder, 0), ISNULL(@IsActive, 1), @ActorUserId);

        SELECT Status = 1, Code = NULL, [Message] = N'The question has been added.',
               FaqId = SCOPE_IDENTITY();

        RETURN;
    END

    UPDATE dbo.t_app_faqs
       SET Category     = @Category,
           Question     = LTRIM(RTRIM(@Question)),
           Answer       = LTRIM(RTRIM(@Answer)),
           DisplayOrder = ISNULL(@DisplayOrder, 0),
           Is_Active    = ISNULL(@IsActive, 1),
           ModifiedOn   = SYSUTCDATETIME(),
           ModifiedBy   = @ActorUserId
     WHERE FaqId = @FaqId
       AND Is_Deleted = 0;

    IF @@ROWCOUNT = 0
    BEGIN
        SELECT Status = 0, Code = 'NOT_FOUND', [Message] = N'That question was not found.',
               FaqId = NULL;
        RETURN;
    END

    SELECT Status = 1, Code = NULL, [Message] = N'The question has been updated.', FaqId = @FaqId;
END
GO

/*==============================================================================
  USP_DeleteFaq — soft.

  🔴 AND IT REFUSES TO EMPTY A SECTION. /faq groups by category, so deleting
  the last live question in one leaves a heading with nothing under it — which
  reads as a broken page rather than a deliberate edit. 003's guard asserts the
  same floor at build time; this is the half that stops it happening.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_DeleteFaq
    @FaqId       int,
    @ActorUserId bigint
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Category varchar(10) = NULL;

    SELECT @Category = Category FROM dbo.t_app_faqs
     WHERE FaqId = @FaqId AND Is_Deleted = 0;

    IF @Category IS NULL
    BEGIN
        SELECT Status = 0, Code = 'NOT_FOUND', [Message] = N'That question was not found.';
        RETURN;
    END

    IF (SELECT COUNT(*) FROM dbo.t_app_faqs
         WHERE Category = @Category AND Is_Active = 1 AND Is_Deleted = 0) <= 1
    BEGIN
        SELECT Status = 0, Code = 'LAST_IN_SECTION',
               [Message] = N'That is the last live question in its section, and the public page would show an empty heading. Add another first, or hide this one instead.';
        RETURN;
    END

    UPDATE dbo.t_app_faqs
       SET Is_Deleted = 1, ModifiedOn = SYSUTCDATETIME(), ModifiedBy = @ActorUserId
     WHERE FaqId = @FaqId;

    SELECT Status = 1, Code = NULL, [Message] = N'The question has been removed.';
END
GO

/*==============================================================================
  USP_ListFaqsForAdmin — including the hidden ones.

  ⚠️ NOT the same read as USP_GetPublicFaqs. That one returns only what is
  live; this one must show an admin the inactive rows too, because a question
  they cannot see is one they cannot bring back.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ListFaqsForAdmin
AS
BEGIN
    SET NOCOUNT ON;

    SELECT FaqId, Category, Question, Answer, DisplayOrder, Is_Active AS IsActive, ModifiedOn
      FROM dbo.t_app_faqs
     WHERE Is_Deleted = 0
     ORDER BY CASE Category WHEN 'TEACHER' THEN 1 WHEN 'SCHOOL' THEN 2 ELSE 3 END,
              DisplayOrder, FaqId;
END
GO

/*==============================================================================
  USP_SaveContentBlock — addressed by its KEY.

  🔴 THE KEY IS THE CONTRACT (2.81). A template names a block; the block does
  not know which page it is on. So this is an upsert on BlockKey rather than on
  an id, and an admin editing a block never has to think about ids.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveContentBlock
    @BlockKey     varchar(50),
    @BlockTitle   nvarchar(200) = NULL,
    @BlockContent nvarchar(2000),
    @ImagePath    nvarchar(500) = NULL,
    @DisplayOrder int = 0,
    @IsActive     tinyint = 1,
    @ActorUserId  bigint
AS
BEGIN
    SET NOCOUNT ON;

    IF LEN(LTRIM(RTRIM(ISNULL(@BlockKey, '')))) = 0
        OR LEN(LTRIM(RTRIM(ISNULL(@BlockContent, N'')))) = 0
    BEGIN
        SELECT Status = 0, Code = 'VALIDATION',
               [Message] = N'A block needs a key and some content.';
        RETURN;
    END

    UPDATE dbo.t_app_cms_content_blocks
       SET BlockTitle   = NULLIF(LTRIM(RTRIM(ISNULL(@BlockTitle, N''))), N''),
           BlockContent = LTRIM(RTRIM(@BlockContent)),
           ImagePath    = NULLIF(LTRIM(RTRIM(ISNULL(@ImagePath, N''))), N''),
           DisplayOrder = ISNULL(@DisplayOrder, 0),
           Is_Active    = ISNULL(@IsActive, 1),
           ModifiedOn   = SYSUTCDATETIME(),
           ModifiedBy   = @ActorUserId
     WHERE BlockKey = @BlockKey
       AND Is_Deleted = 0;

    IF @@ROWCOUNT > 0
    BEGIN
        SELECT Status = 1, Code = NULL, [Message] = N'The block has been updated.';
        RETURN;
    END

    INSERT INTO dbo.t_app_cms_content_blocks
        (BlockKey, BlockTitle, BlockContent, ImagePath, DisplayOrder, Is_Active, CreatedBy)
    VALUES (@BlockKey,
            NULLIF(LTRIM(RTRIM(ISNULL(@BlockTitle, N''))), N''),
            LTRIM(RTRIM(@BlockContent)),
            NULLIF(LTRIM(RTRIM(ISNULL(@ImagePath, N''))), N''),
            ISNULL(@DisplayOrder, 0), ISNULL(@IsActive, 1), @ActorUserId);

    SELECT Status = 1, Code = NULL, [Message] = N'The block has been added.';
END
GO

CREATE OR ALTER PROCEDURE dbo.USP_ListContentBlocksForAdmin
AS
BEGIN
    SET NOCOUNT ON;

    SELECT BlockId, BlockKey, BlockTitle, BlockContent, ImagePath,
           DisplayOrder, Is_Active AS IsActive, ModifiedOn
      FROM dbo.t_app_cms_content_blocks
     WHERE Is_Deleted = 0
     ORDER BY DisplayOrder, BlockKey;
END
GO

/*==============================================================================
  USP_SearchEnquiries — the contact queue.

  🔒 THERE IS NO CALLER IDENTITY TO SHOW, because 033 gave the table none: an
  enquiry arrives from an anonymous visitor. What an admin sees is what the
  visitor typed.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SearchEnquiries
    @IsResolved tinyint = NULL,
    @PageNumber int = 1,
    @PageSize   int = 20
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Take int = CASE WHEN @PageSize BETWEEN 1 AND 100 THEN @PageSize ELSE 20 END,
            @Skip int = (CASE WHEN @PageNumber < 1 THEN 0 ELSE @PageNumber - 1 END)
                        * (CASE WHEN @PageSize BETWEEN 1 AND 100 THEN @PageSize ELSE 20 END);

    SELECT
        e.EnquiryId,
        e.Name,
        e.Email,
        e.Mobile,
        e.Subject,
        e.[Message],
        e.IsResolved,
        e.ResolvedOn,
        e.ResolutionRemarks,
        e.CreatedOn
      FROM dbo.t_app_contact_enquiries e
     WHERE e.Is_Deleted = 0
       AND (@IsResolved IS NULL OR e.IsResolved = @IsResolved)
     ORDER BY
        /* Unanswered first, then oldest — a queue. */
        e.IsResolved,
        e.CreatedOn
     OFFSET @Skip ROWS FETCH NEXT @Take ROWS ONLY;

    SELECT COUNT(*) AS TotalRecords
      FROM dbo.t_app_contact_enquiries e
     WHERE e.Is_Deleted = 0
       AND (@IsResolved IS NULL OR e.IsResolved = @IsResolved);
END
GO

/*==============================================================================
  USP_ResolveEnquiry — answered, by somebody, at a time, with a note.

  🔴 REMARKS ARE REQUIRED. 033's CK_ResolvedTrail already demands a resolver
  and a timestamp; the remark is what makes the trail answer the question
  somebody will actually ask, which is "what did we tell them?".
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ResolveEnquiry
    @EnquiryId   bigint,
    @Remarks     nvarchar(1000),
    @ActorUserId bigint
AS
BEGIN
    SET NOCOUNT ON;

    IF LEN(LTRIM(RTRIM(ISNULL(@Remarks, N'')))) = 0
    BEGIN
        SELECT Status = 0, Code = 'REMARKS_REQUIRED',
               [Message] = N'Say what you told them — an empty flag answers nobody''s question later.';
        RETURN;
    END

    IF NOT EXISTS (SELECT 1 FROM dbo.t_app_contact_enquiries
                    WHERE EnquiryId = @EnquiryId AND Is_Deleted = 0)
    BEGIN
        SELECT Status = 0, Code = 'NOT_FOUND', [Message] = N'That enquiry was not found.';
        RETURN;
    END

    IF EXISTS (SELECT 1 FROM dbo.t_app_contact_enquiries
                WHERE EnquiryId = @EnquiryId AND IsResolved = 1 AND Is_Deleted = 0)
    BEGIN
        SELECT Status = 0, Code = 'ALREADY_RESOLVED',
               [Message] = N'That enquiry is already marked answered.';
        RETURN;
    END

    UPDATE dbo.t_app_contact_enquiries
       SET IsResolved        = 1,
           ResolvedByUserId  = @ActorUserId,
           ResolvedOn        = SYSUTCDATETIME(),
           ResolutionRemarks = LTRIM(RTRIM(@Remarks))
     WHERE EnquiryId = @EnquiryId;

    SELECT Status = 1, Code = NULL, [Message] = N'Marked as answered.';
END
GO

/*==============================================================================
  BUILD GUARDS
==============================================================================*/

/*
  🔴 THERE IS NO CODE GUARD AGAINST A STORED FEATURED FLAG, AND REMOVING THE
  ONE I WROTE IS THE POINT OF THIS COMMENT.

  The first version of this file searched sys.sql_modules for 'IsFeatured' and
  failed the build on any procedure mentioning it. It fired immediately — on
  024's own comment, which says "there is no IsFeatured column to keep in
  step". The guard matched the prose explaining the rule it was enforcing.

  ⚠️ THE PROJECT HAD ALREADY LEARNED THIS. 6.5A: "a text guard over
  sys.sql_modules cannot tell code from prose about code — a guard naming what
  it bans matches itself", and the fix there was to check
  sys.parameters/sys.sql_expression_dependencies instead. I wrote that lesson
  down and then rebuilt the same guard an hour later.

  🔴 AND THE STRUCTURAL GUARD ALREADY COVERS IT, BETTER. 034 fails the build if
  t_app_featured_jobs or t_app_featured_schools grows IsFeatured, IsActive,
  StatusId or IsLive. With no such column there is nothing for a procedure to
  set: an UPDATE naming it compiles (deferred name resolution) and fails at
  runtime, every time, on every row.

  So the column guard is the guard. A text guard beside it added nothing except
  a false failure on a comment.
*/

/*
  🔴 THE FEATURED WINDOW IS COMPARED AGAINST THE IST DATE, NEVER THE UTC ONE.

  Between 00:00 and 05:30 IST the UTC date is still yesterday, so a UTC
  comparison ends a paid placement five and a half hours early and starts one
  five and a half hours late — every night. 7A's job-expiry boundary had the
  same trap, and the suite caught it only because it happened to run in that
  window.

  ⚠️ So this is asserted structurally: every procedure that reads a featured
  table must depend on fn_IstToday.

  Proven to fire: replacing fn_IstToday() with CAST(SYSUTCDATETIME() AS date)
  in USP_ListFeatured fails this.
*/
DECLARE @utcReaders nvarchar(1000) = N'';

SELECT @utcReaders = STRING_AGG(CAST(OBJECT_NAME(m.object_id) AS nvarchar(128)), N', ')
  FROM sys.sql_modules m
 WHERE (m.definition LIKE '%t_app_featured_jobs%' OR m.definition LIKE '%t_app_featured_schools%')
   AND m.definition NOT LIKE '%fn_IstToday%'
   AND OBJECT_NAME(m.object_id) NOT IN (
         /* These write or remove windows; they compare no dates. */
         'USP_SaveFeaturedJob', 'USP_SaveFeaturedSchool', 'USP_RemoveFeatured');

IF ISNULL(@utcReaders, N'') <> N''
BEGIN
    DECLARE @msg2 nvarchar(1200) =
        N'026_admin_content: 🔴 A PROCEDURE READS A FEATURED TABLE WITHOUT fn_IstToday: ' + @utcReaders
        + N'. "Featured today" is an IST date comparison (2.28: storage UTC, rules IST). A UTC date ends a placement 5.5 hours early every night.';

    RAISERROR('%s', 16, 1, @msg2);
END
GO

PRINT '    Featured, FAQ, content blocks and enquiries ready.';
GO
