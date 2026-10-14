/*==============================================================================
  jp_app — 034_moderation_reports_featured.sql

  PHASE 7B — the admin's operations desk.

    m_app_report_reasons        why somebody reported something
    m_app_report_status         Open -> UnderReview -> ActionTaken/Dismissed
    t_app_job_moderation_log    APPEND-ONLY. Every pull and restore.
    t_app_reports               what visitors and users report
    t_app_featured_jobs         date-ranged, derived, never swept
    t_app_featured_schools      the same, for schools

  Plus one row on m_app_job_status: PULLED.

  ---------------------------------------------------------------------------
  🔴 PULLED IS A JOB STATUS, NOT A FLAG ON THE JOB — AND THE ALTERNATIVE WAS
  REAL
  ---------------------------------------------------------------------------
  A moderation-pulled job must vanish from the public site. The two shapes:

  REJECTED — `IsPulled` / `PulledOn` / `PulledReason` columns on t_app_jobs.
  Attractive because "pulled" is a moderation state and arguably orthogonal to
  the lifecycle: a pulled job can also expire. And rejected because the
  condition would have to be added to EVERY read that decides whether a job is
  visible — the public search, the public detail, the teacher browse, the
  teacher detail, the apply path — and the one that gets missed is a pulled job
  still showing. There are at least five.

  CHOSEN — JobStatusId 5. Every one of those reads already requires
  `JobStatusId = 2`, so a pulled job disappears from all of them at once, with
  no new condition anywhere to forget. 2.65's `fn_EffectiveJobStatusId` stays
  the single definition of what status a job is really in.

  ⚠️ THE COST, AND HOW IT IS PAID: a status column holds one value, so pulling
  a job overwrites what it was. The PULL log row records the status it had, and
  restore reads it back from there. That is what an append-only log is for, and
  it is why restore does not simply set 2.

  ⚠️ 021's header says m_app_job_status has four rows and only three are ever
  WRITTEN (Expired is derived from the date). PULLED is written, like Draft,
  Active and Closed. Nothing about Expired changes.

  ---------------------------------------------------------------------------
  🔴 APPEND-ONLY, AND WHAT THAT HONESTLY MEANS HERE
  ---------------------------------------------------------------------------
  t_app_job_moderation_log has NO Is_Deleted, NO ModifiedOn and NO ModifiedBy.
  That is the structural part: there is no column through which an edit or a
  deletion can be expressed, so the ordinary soft-delete shape every other
  table in this schema uses is simply absent here.

  ⚠️ NO TRIGGER, deliberately. This schema has no triggers in any production
  file — only one, in a jp_sso test — and introducing the first one for this
  would mean every future reader of this table has to know that writes behave
  differently here than everywhere else. 024's companion procedures file
  carries a build guard instead: no procedure may UPDATE or DELETE this table.

  ⚠️ AND THE LIMIT, STATED: somebody with direct database access can still
  UPDATE a row. Nothing short of DENY on a separate login prevents that, and
  this project uses one login. What is prevented is the application growing a
  way to do it, which is the realistic risk.

  ---------------------------------------------------------------------------
  🔒 THE REPORTER IS A UID, AND IT NEVER LEAVES THE ADMIN SIDE
  ---------------------------------------------------------------------------
  t_app_reports.ReportedByUserUid is stored because an admin reviewing a report
  needs to know whether one person filed forty of them. It must never reach the
  party being reported, and that is enforced where it can be: in the
  procedures, none of which project it into a school-facing or teacher-facing
  result set, and a build guard asserts that.

  ⚠️ ReportedEntityId is a polymorphic id — a SchoolId, TeacherId or JobId
  depending on ReportedEntityType — so it carries no foreign key. A CHECK keeps
  the type inside the three values that exist, and the procedures resolve the
  id against the right table. A nullable FK per type was the alternative; three
  mostly-NULL columns to express one relationship is worse than one id with a
  type beside it.

  ---------------------------------------------------------------------------
  🔴 FEATURED IS DERIVED FROM DATES. THERE IS NO IsFeatured ANYWHERE.
  ---------------------------------------------------------------------------
  A row says "this job is featured from FromDate to ToDate". Whether it is
  featured TODAY is a comparison, computed at read time — exactly the shape
  2.5 chose for quota periods and 021 chose for expiry, and for the same
  reason: a scheduled sweep is a job that will one day not run, and its failure
  is silent.

  ⚠️ So these tables have no status column, and that absence is the design. A
  featured row that has ended is simply a row whose ToDate has passed; nothing
  has to happen to it.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET NOCOUNT ON;
GO

/*==============================================================================
  m_app_report_reasons — why somebody reported something.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_app_report_reasons' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_app_report_reasons] ...';

    CREATE TABLE dbo.m_app_report_reasons
    (
        ReportReasonId int            NOT NULL,
        Code           varchar(30)    NOT NULL,
        Name           nvarchar(80)   NOT NULL,

        /*
          ⚠️ Which entity types this reason can be used for, as a CSV of the
          three type codes. A reason like FAKE_PROFILE makes no sense against a
          school, and an admin queue full of impossible combinations is an
          admin queue nobody trusts.

          ⚠️ A bridge table was the alternative. Three reasons × three types is
          a nine-row table to express something a reader can see at a glance
          here, and the procedures filter on it with a LIKE — this is reference
          data that changes when somebody edits this file.
        */
        AppliesTo      varchar(40)    NOT NULL,

        DisplayOrder   int            NOT NULL
                       CONSTRAINT DF_m_app_report_reasons_DisplayOrder DEFAULT (0),
        Is_Active      tinyint        NOT NULL
                       CONSTRAINT DF_m_app_report_reasons_Is_Active DEFAULT (1),
        Is_Deleted     tinyint        NOT NULL
                       CONSTRAINT DF_m_app_report_reasons_Is_Deleted DEFAULT (0),
        CreatedOn      datetime2      NOT NULL
                       CONSTRAINT DF_m_app_report_reasons_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CreatedBy      bigint         NULL,
        ModifiedOn     datetime2      NULL,
        ModifiedBy     bigint         NULL,

        CONSTRAINT PK_m_app_report_reasons PRIMARY KEY CLUSTERED (ReportReasonId),
        CONSTRAINT UQ_m_app_report_reasons_Code UNIQUE (Code),
        CONSTRAINT CK_m_app_report_reasons_Is_Active CHECK (Is_Active IN (0, 1)),
        CONSTRAINT CK_m_app_report_reasons_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );

    INSERT INTO dbo.m_app_report_reasons (ReportReasonId, Code, Name, AppliesTo, DisplayOrder)
    VALUES
        (1, 'FAKE_JOB',              N'The job is not real',            'JOB',               1),
        (2, 'FAKE_PROFILE',          N'The profile is not real',        'TEACHER,SCHOOL',    2),
        (3, 'MISLEADING_INFO',       N'Misleading information',         'JOB,TEACHER,SCHOOL', 3),
        (4, 'SPAM',                  N'Spam',                           'JOB,TEACHER,SCHOOL', 4),
        (5, 'INAPPROPRIATE_CONTENT', N'Inappropriate content',          'JOB,TEACHER,SCHOOL', 5),
        (6, 'FRAUD_PAYMENT',         N'Asked me for money',             'JOB,SCHOOL',        6),
        (7, 'OTHER',                 N'Something else',                  'JOB,TEACHER,SCHOOL', 7);

    PRINT '      7 reason(s) seeded.';
END
ELSE
    PRINT '    Table [m_app_report_reasons] already exists - skipped.';
GO

/*==============================================================================
  m_app_report_status — the state machine's states.

  🔴 Open -> UnderReview -> ActionTaken | Dismissed, and the procedures enforce
  the transitions. The master holds the states; it cannot hold the rules.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_app_report_status' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_app_report_status] ...';

    CREATE TABLE dbo.m_app_report_status
    (
        ReportStatusId int            NOT NULL,
        Code           varchar(20)    NOT NULL,
        Name           nvarchar(40)   NOT NULL,

        /*
          🔴 A TERMINAL STATE CANNOT BE LEFT. Stored here rather than written
          into a CASE in every procedure that moves a report, so there is one
          place that says which states are final.
        */
        IsTerminal     tinyint        NOT NULL
                       CONSTRAINT DF_m_app_report_status_IsTerminal DEFAULT (0),

        DisplayOrder   int            NOT NULL
                       CONSTRAINT DF_m_app_report_status_DisplayOrder DEFAULT (0),
        Is_Active      tinyint        NOT NULL
                       CONSTRAINT DF_m_app_report_status_Is_Active DEFAULT (1),
        Is_Deleted     tinyint        NOT NULL
                       CONSTRAINT DF_m_app_report_status_Is_Deleted DEFAULT (0),
        CreatedOn      datetime2      NOT NULL
                       CONSTRAINT DF_m_app_report_status_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CreatedBy      bigint         NULL,
        ModifiedOn     datetime2      NULL,
        ModifiedBy     bigint         NULL,

        CONSTRAINT PK_m_app_report_status PRIMARY KEY CLUSTERED (ReportStatusId),
        CONSTRAINT UQ_m_app_report_status_Code UNIQUE (Code),
        CONSTRAINT CK_m_app_report_status_IsTerminal CHECK (IsTerminal IN (0, 1)),
        CONSTRAINT CK_m_app_report_status_Is_Active CHECK (Is_Active IN (0, 1)),
        CONSTRAINT CK_m_app_report_status_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );

    INSERT INTO dbo.m_app_report_status (ReportStatusId, Code, Name, IsTerminal, DisplayOrder)
    VALUES
        (1, 'OPEN',         N'Open',         0, 1),
        (2, 'UNDER_REVIEW', N'Under review', 0, 2),
        (3, 'ACTION_TAKEN', N'Action taken', 1, 3),
        (4, 'DISMISSED',    N'Dismissed',    1, 4);

    PRINT '      4 status(es) seeded.';
END
ELSE
    PRINT '    Table [m_app_report_status] already exists - skipped.';
GO

/*==============================================================================
  m_app_job_status gains PULLED.

  ⚠️ Inserted rather than created — the table is 021's. Guarded so a re-run is
  a no-op, and the id is explicit because 014's procedures compare against
  these numbers.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM dbo.m_app_job_status WHERE JobStatusId = 5)
BEGIN
    PRINT '    Adding [m_app_job_status] row 5 PULLED ...';

    INSERT INTO dbo.m_app_job_status (JobStatusId, Code, Name, DisplayOrder)
    VALUES (5, 'PULLED', N'Pulled by moderation', 5);
END
ELSE
    PRINT '    [m_app_job_status] row 5 PULLED already present - skipped.';
GO

/*==============================================================================
  t_app_job_moderation_log — APPEND-ONLY. Every pull and every restore.

  🔴 NO Is_Deleted, NO ModifiedOn, NO ModifiedBy. See this file's header: the
  absence is the structural half of "append-only", because there is no column
  through which an edit can be expressed.
==============================================================================*/
IF OBJECT_ID('dbo.t_app_job_moderation_log', 'U') IS NULL
BEGIN
    PRINT '    Creating table [t_app_job_moderation_log] ...';

    CREATE TABLE dbo.t_app_job_moderation_log
    (
        LogId            bigint         IDENTITY(1, 1) NOT NULL,

        JobId            bigint         NOT NULL,

        /*
          🔴 PULL or RESTORE. A CHECK rather than a master table: there are two
          values, they are decided by what the code can do, and a master would
          invite a third that no procedure writes.
        */
        ActionType       varchar(10)    NOT NULL,

        /*
          🔴 THE STATUS THE JOB HAD BEFORE THIS ACTION.

          This is what makes restore exact. A status column holds one value, so
          pulling overwrites what the job was; without this, restore could only
          guess at 2 — and a job that was Closed when an admin pulled it would
          come back Active, republished by a moderation decision.
        */
        PreviousStatusId int            NOT NULL,

        /*
          ⚠️ REQUIRED, AND NOT NULLABLE. A moderation action without a reason is
          the one an admin cannot explain later, and the school is shown this
          text. The procedure refuses an empty one too — this is the floor.
        */
        Remarks          nvarchar(1000) NOT NULL,

        ActionByUserId   bigint         NOT NULL,
        ActionOn         datetime2      NOT NULL
                         CONSTRAINT DF_t_app_job_moderation_log_ActionOn DEFAULT (SYSUTCDATETIME()),

        CONSTRAINT PK_t_app_job_moderation_log PRIMARY KEY CLUSTERED (LogId),

        CONSTRAINT FK_t_app_job_moderation_log_Job
            FOREIGN KEY (JobId) REFERENCES dbo.t_app_jobs (JobId),

        CONSTRAINT CK_t_app_job_moderation_log_ActionType
            CHECK (ActionType IN ('PULL', 'RESTORE')),

        /*
          ⚠️ A pull must record a status that exists, and 5 is not one of them:
          pulling an already-pulled job is refused by the procedure, so PULLED
          can never be the PREVIOUS status.
        */
        CONSTRAINT CK_t_app_job_moderation_log_PreviousStatusId
            CHECK (PreviousStatusId IN (1, 2, 3, 4, 5)),

        CONSTRAINT CK_t_app_job_moderation_log_Remarks
            CHECK (LEN(LTRIM(RTRIM(Remarks))) > 0)
    );

    /* The school's own history for one job, newest first. */
    CREATE NONCLUSTERED INDEX IX_t_app_job_moderation_log_Job
        ON dbo.t_app_job_moderation_log (JobId, LogId DESC);

    PRINT '      Table + 1 index created.';
END
ELSE
    PRINT '    Table [t_app_job_moderation_log] already exists - skipped.';
GO

/*
  🔒 GUARD — the append-only shape is asserted, not just described.

  If somebody adds Is_Deleted, ModifiedOn or ModifiedBy to this table, the
  ordinary soft-delete and edit shapes become expressible and the table stops
  being a log. Proven to fire by adding Is_Deleted before shipping.
*/
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('dbo.t_app_job_moderation_log')
             AND name IN ('Is_Deleted', 'ModifiedOn', 'ModifiedBy', 'Is_Active'))
    RAISERROR('034: t_app_job_moderation_log has gained an edit or delete column. It is APPEND-ONLY: with no such column there is no shape through which a moderation action can be rewritten or hidden. Remove it, and see this file''s header.', 16, 1);
GO

/*==============================================================================
  t_app_reports — what visitors and users report.
==============================================================================*/
IF OBJECT_ID('dbo.t_app_reports', 'U') IS NULL
BEGIN
    PRINT '    Creating table [t_app_reports] ...';

    CREATE TABLE dbo.t_app_reports
    (
        ReportId          bigint         IDENTITY(1, 1) NOT NULL,
        ReportUid         uniqueidentifier NOT NULL
                          CONSTRAINT DF_t_app_reports_ReportUid DEFAULT (NEWID()),

        ReportReasonId    int            NOT NULL,

        /* JOB, TEACHER or SCHOOL. See the header on why there is no FK. */
        ReportedEntityType varchar(10)   NOT NULL,
        ReportedEntityId  bigint         NOT NULL,

        /*
          🔒 THE REPORTER. Stored so an admin can see that one account filed
          forty reports; NEVER projected into anything the reported party can
          read. The procedures enforce that and a build guard asserts it.
        */
        ReportedByUserUid uniqueidentifier NOT NULL,

        Description       nvarchar(2000) NULL,

        ReportStatusId    int            NOT NULL
                          CONSTRAINT DF_t_app_reports_ReportStatusId DEFAULT (1),

        ReviewedByUserId  bigint         NULL,
        ReviewedOn        datetime2      NULL,
        AdminRemarks      nvarchar(1000) NULL,

        Is_Deleted        tinyint        NOT NULL
                          CONSTRAINT DF_t_app_reports_Is_Deleted DEFAULT (0),
        CreatedOn         datetime2      NOT NULL
                          CONSTRAINT DF_t_app_reports_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CreatedBy         bigint         NULL,
        ModifiedOn        datetime2      NULL,
        ModifiedBy        bigint         NULL,

        CONSTRAINT PK_t_app_reports PRIMARY KEY CLUSTERED (ReportId),
        CONSTRAINT UQ_t_app_reports_ReportUid UNIQUE (ReportUid),

        CONSTRAINT FK_t_app_reports_Reason
            FOREIGN KEY (ReportReasonId) REFERENCES dbo.m_app_report_reasons (ReportReasonId),
        CONSTRAINT FK_t_app_reports_Status
            FOREIGN KEY (ReportStatusId) REFERENCES dbo.m_app_report_status (ReportStatusId),

        CONSTRAINT CK_t_app_reports_EntityType
            CHECK (ReportedEntityType IN ('JOB', 'TEACHER', 'SCHOOL')),

        CONSTRAINT CK_t_app_reports_Is_Deleted CHECK (Is_Deleted IN (0, 1)),

        /*
          🔴 REVIEWED MEANS SOMEBODY REVIEWED IT, AT A TIME.

          The same structural rule 033 put on resolved enquiries, for the same
          reason: a report sitting in a terminal state with no reviewer and no
          timestamp is a queue nobody can audit, and the shape that produces it
          is an UPDATE that sets the status and forgets the rest.
        */
        CONSTRAINT CK_t_app_reports_ReviewTrail
            CHECK (
                (ReportStatusId IN (1, 2) AND ReviewedByUserId IS NULL AND ReviewedOn IS NULL)
                OR
                (ReportStatusId IN (3, 4) AND ReviewedByUserId IS NOT NULL AND ReviewedOn IS NOT NULL)
            )
    );

    /*
      🔴 ONE OPEN REPORT PER REPORTER PER ENTITY — the idempotence the brief
      asks for (2.48), enforced by the database rather than by a procedure
      remembering to check.

      ⚠️ FILTERED ON THE NON-TERMINAL STATUSES. Somebody whose first report was
      dismissed may report the same thing again later — circumstances change,
      and refusing that forever would be a filed complaint nobody can refile.
      What is prevented is forty copies of one live complaint.
    */
    CREATE UNIQUE NONCLUSTERED INDEX UX_t_app_reports_OneOpenPerReporter
        ON dbo.t_app_reports (ReportedByUserUid, ReportedEntityType, ReportedEntityId)
        WHERE Is_Deleted = 0 AND ReportStatusId IN (1, 2);

    /* The admin queue: oldest open first. */
    CREATE NONCLUSTERED INDEX IX_t_app_reports_Queue
        ON dbo.t_app_reports (ReportStatusId, CreatedOn)
        WHERE Is_Deleted = 0;

    /* "What else has been reported about this entity?" */
    CREATE NONCLUSTERED INDEX IX_t_app_reports_Entity
        ON dbo.t_app_reports (ReportedEntityType, ReportedEntityId)
        WHERE Is_Deleted = 0;

    PRINT '      Table + 3 indexes created.';
END
ELSE
    PRINT '    Table [t_app_reports] already exists - skipped.';
GO

/*==============================================================================
  t_app_featured_jobs / t_app_featured_schools — date-ranged, derived.

  🔴 NO IsFeatured, NO status column. "Featured today" is FromDate <= today AND
  ToDate >= today, computed at read time. See this file's header.
==============================================================================*/
IF OBJECT_ID('dbo.t_app_featured_jobs', 'U') IS NULL
BEGIN
    PRINT '    Creating table [t_app_featured_jobs] ...';

    CREATE TABLE dbo.t_app_featured_jobs
    (
        FeaturedJobId bigint    IDENTITY(1, 1) NOT NULL,
        JobId         bigint    NOT NULL,

        /*
          ⚠️ DATE, not datetime2. A feature runs for whole days in the
          advertiser's sense — "the 14th to the 20th" — and 2.28 keeps storage
          in UTC while the rules are IST. A datetime2 would invite a time of
          day nobody intends and make the boundary depend on the hour.
        */
        FromDate      date      NOT NULL,
        ToDate        date      NOT NULL,

        DisplayOrder  int       NOT NULL
                      CONSTRAINT DF_t_app_featured_jobs_DisplayOrder DEFAULT (0),

        Is_Deleted    tinyint   NOT NULL
                      CONSTRAINT DF_t_app_featured_jobs_Is_Deleted DEFAULT (0),
        CreatedOn     datetime2 NOT NULL
                      CONSTRAINT DF_t_app_featured_jobs_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CreatedBy     bigint    NULL,
        ModifiedOn    datetime2 NULL,
        ModifiedBy    bigint    NULL,

        CONSTRAINT PK_t_app_featured_jobs PRIMARY KEY CLUSTERED (FeaturedJobId),

        CONSTRAINT FK_t_app_featured_jobs_Job
            FOREIGN KEY (JobId) REFERENCES dbo.t_app_jobs (JobId),

        CONSTRAINT CK_t_app_featured_jobs_Is_Deleted CHECK (Is_Deleted IN (0, 1)),

        /* A window that ends before it starts is never active — and is a typo. */
        CONSTRAINT CK_t_app_featured_jobs_Window CHECK (ToDate >= FromDate)
    );

    /*
      ⚠️ NOT UNIQUE ON JobId. A job can be featured in January and again in
      March, and those are two rows. What the procedure refuses is a window
      that OVERLAPS an existing one for the same job — two live rows for one job
      would make DisplayOrder ambiguous.
    */
    CREATE NONCLUSTERED INDEX IX_t_app_featured_jobs_Window
        ON dbo.t_app_featured_jobs (FromDate, ToDate, DisplayOrder)
        WHERE Is_Deleted = 0;

    CREATE NONCLUSTERED INDEX IX_t_app_featured_jobs_Job
        ON dbo.t_app_featured_jobs (JobId)
        WHERE Is_Deleted = 0;

    PRINT '      Table + 2 indexes created.';
END
ELSE
    PRINT '    Table [t_app_featured_jobs] already exists - skipped.';
GO

IF OBJECT_ID('dbo.t_app_featured_schools', 'U') IS NULL
BEGIN
    PRINT '    Creating table [t_app_featured_schools] ...';

    CREATE TABLE dbo.t_app_featured_schools
    (
        FeaturedSchoolId bigint    IDENTITY(1, 1) NOT NULL,
        SchoolId         bigint    NOT NULL,

        FromDate         date      NOT NULL,
        ToDate           date      NOT NULL,

        DisplayOrder     int       NOT NULL
                         CONSTRAINT DF_t_app_featured_schools_DisplayOrder DEFAULT (0),

        Is_Deleted       tinyint   NOT NULL
                         CONSTRAINT DF_t_app_featured_schools_Is_Deleted DEFAULT (0),
        CreatedOn        datetime2 NOT NULL
                         CONSTRAINT DF_t_app_featured_schools_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CreatedBy        bigint    NULL,
        ModifiedOn       datetime2 NULL,
        ModifiedBy       bigint    NULL,

        CONSTRAINT PK_t_app_featured_schools PRIMARY KEY CLUSTERED (FeaturedSchoolId),

        CONSTRAINT FK_t_app_featured_schools_School
            FOREIGN KEY (SchoolId) REFERENCES dbo.t_app_schools (SchoolId),

        CONSTRAINT CK_t_app_featured_schools_Is_Deleted CHECK (Is_Deleted IN (0, 1)),
        CONSTRAINT CK_t_app_featured_schools_Window CHECK (ToDate >= FromDate)
    );

    CREATE NONCLUSTERED INDEX IX_t_app_featured_schools_Window
        ON dbo.t_app_featured_schools (FromDate, ToDate, DisplayOrder)
        WHERE Is_Deleted = 0;

    CREATE NONCLUSTERED INDEX IX_t_app_featured_schools_School
        ON dbo.t_app_featured_schools (SchoolId)
        WHERE Is_Deleted = 0;

    PRINT '      Table + 2 indexes created.';
END
ELSE
    PRINT '    Table [t_app_featured_schools] already exists - skipped.';
GO

/*
  🔒 GUARD — featured-ness stays DERIVED.

  An IsFeatured, IsActive or Status column on either table would make it
  storable, and then something has to keep it in step with the dates — which is
  the sweep this design exists to avoid. Proven to fire by adding IsFeatured
  before shipping.
*/
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id IN (OBJECT_ID('dbo.t_app_featured_jobs'), OBJECT_ID('dbo.t_app_featured_schools'))
             AND name IN ('IsFeatured', 'IsActive', 'Is_Active', 'StatusId', 'IsLive'))
    RAISERROR('034: a featured table has gained a stored status column. Featured-ness is DERIVED from FromDate/ToDate at read time (this file''s header, 2.5, 021) — a stored flag needs a sweep to keep it true, and a sweep is a job that will one day not run, silently.', 16, 1);
GO

PRINT '    Moderation, reports and featured ready.';
GO
