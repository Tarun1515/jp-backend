/*==============================================================================
  jp_app — 022_t_app_jobs.sql

  Jobs, and the two bridges that carry a job's subjects and class levels.
  Phase 4. Fields per DB_TABLE_STRUCTURE.md (client spec point 6).

  ---------------------------------------------------------------------------
  🔴 BranchId IS NOT NULL, AND THAT IS THE SECURITY SURFACE OF THIS PHASE
  ---------------------------------------------------------------------------
  Every job belongs to exactly one campus. Single-campus schools have a head
  office and it is a branch like any other (2.10), so no nullable-branch path
  is needed anywhere.

  ⚠️ BranchId arrives in the request body as DATA — "which campus is this job
  for" — and that is legitimate. SchoolId never does. The distinction is 2.39's
  sharpest edge: because a body BranchId is legitimate, validating it against
  the caller's resolved scope is easy to forget, and an unvalidated one means
  posting a job onto another school's campus.

  The procedures join through dbo.fn_VisibleBranches for every read and every
  write. A branch the caller does not hold produces NOT_FOUND, never FORBIDDEN
  (2.6) — "that branch is not yours" is an id oracle.

  ---------------------------------------------------------------------------
  ⚠️ EXPIRED IS NEVER STORED IN JobStatusId
  ---------------------------------------------------------------------------
  Draft (1), Active (2) and Closed (4) are written. A job past its
  LastDateToApply stays ACTIVE in this table and reads as Expired through
  dbo.fn_EffectiveJobStatusId. There is no sweep job — see 021's header.

  ---------------------------------------------------------------------------
  t_app_job_moderation_log IS NOT HERE
  ---------------------------------------------------------------------------
  It is Phase 7 (moderation), and creating it now would leave a table nothing
  writes to and every reader has to special-case for emptiness. 2A learned that
  with the reconciliation tables; an unused table is a question every future
  reader has to answer.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  t_app_jobs
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_jobs' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_jobs] ...';

    CREATE TABLE dbo.t_app_jobs
    (
        JobId                 bigint            IDENTITY(1,1) NOT NULL,

        /*
          🔴 The public identifier, and the entitlement ledger's reference.
          Phase 2.5's idempotency key for a publish is (JOB, JobUid) — see
          USP_PublishJob. It must be stable for the life of the row.
        */
        JobUid                uniqueidentifier  NOT NULL CONSTRAINT DF_t_app_jobs_JobUid DEFAULT (NEWID()),

        SchoolId              bigint            NOT NULL,
        BranchId              bigint            NOT NULL,   -- 🔴 never nullable

        JobTitle              nvarchar(200)     NOT NULL,

        /*
          ⚠️ CROSS-DATABASE — all of these are m_mdm_* in jp_mdm. No foreign
          keys and never any (2.2). The API validates them against jp_mdm before
          calling, the same shape every other cross-database id takes here.

          SubjectId is the PRIMARY subject; t_app_job_subjects carries the full
          set for a multi-subject posting. Both exist because search filters on
          one and the posting displays many.
        */
        SubjectId             int               NOT NULL,
        DesignationId         int               NOT NULL,
        QualificationId       int               NULL,
        EmploymentTypeId      int               NOT NULL CONSTRAINT DF_t_app_jobs_EmploymentTypeId DEFAULT (1),

        NoOfVacancies         int               NOT NULL CONSTRAINT DF_t_app_jobs_NoOfVacancies DEFAULT (1),

        MinExperienceMonths   int               NULL,
        MaxExperienceMonths   int               NULL,

        SalaryMin             decimal(12, 2)    NULL,
        SalaryMax             decimal(12, 2)    NULL,
        IsSalaryNegotiable    tinyint           NOT NULL CONSTRAINT DF_t_app_jobs_IsSalaryNegotiable DEFAULT (0),

        -- ⚠️ CROSS-DATABASE — m_mdm_city / m_mdm_state.
        CityId                int               NULL,
        StateId               int               NULL,

        WorkingDays           nvarchar(100)     NULL,
        TimingFrom            time(0)           NULL,
        TimingTo              time(0)           NULL,

        /*
          🔴 A DATE, NOT AN INSTANT, and compared against fn_IstToday().

          "Applications close on the 30th" is a calendar fact in IST. Storing an
          instant would make the cut-off land at 05:30 IST on the 30th for
          anyone who wrote it as UTC midnight (2.28).
        */
        LastDateToApply       date              NULL,
        ExpectedJoiningDate   date              NULL,

        JobDescription        nvarchar(max)     NULL,

        -- 1 Draft · 2 Active · 4 Closed. ⚠️ 3 (Expired) is NEVER written here.
        JobStatusId           int               NOT NULL CONSTRAINT DF_t_app_jobs_JobStatusId DEFAULT (1),

        PublishedOn           datetime2         NULL,
        ClosedOn              datetime2         NULL,

        ViewCount             int               NOT NULL CONSTRAINT DF_t_app_jobs_ViewCount DEFAULT (0),
        ApplicationCount      int               NOT NULL CONSTRAINT DF_t_app_jobs_ApplicationCount DEFAULT (0),

        Is_Active             tinyint           NOT NULL CONSTRAINT DF_t_app_jobs_Is_Active  DEFAULT (1),
        Is_Deleted            tinyint           NOT NULL CONSTRAINT DF_t_app_jobs_Is_Deleted DEFAULT (0),
        CreatedOn             datetime2         NOT NULL CONSTRAINT DF_t_app_jobs_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy             bigint            NULL,
        ModifiedOn            datetime2         NULL,
        ModifiedBy            bigint            NULL,
        RowVersion            int               NOT NULL CONSTRAINT DF_t_app_jobs_RowVersion DEFAULT (1),

        CONSTRAINT PK_t_app_jobs PRIMARY KEY CLUSTERED (JobId),

        CONSTRAINT FK_t_app_jobs_School
            FOREIGN KEY (SchoolId) REFERENCES dbo.t_app_schools (SchoolId),
        CONSTRAINT FK_t_app_jobs_Branch
            FOREIGN KEY (BranchId) REFERENCES dbo.t_app_school_branches (BranchId),
        CONSTRAINT FK_t_app_jobs_Status
            FOREIGN KEY (JobStatusId) REFERENCES dbo.m_app_job_status (JobStatusId),
        CONSTRAINT FK_t_app_jobs_EmploymentType
            FOREIGN KEY (EmploymentTypeId) REFERENCES dbo.m_app_employment_types (EmploymentTypeId),

        /*
          🔴 Expired is derived and must never be stored. Without this CHECK the
          rule is a comment, and one UPDATE somewhere makes the derived status
          and the stored status disagree — with no way to tell which is right.
        */
        CONSTRAINT CK_t_app_jobs_StoredStatus CHECK (JobStatusId IN (1, 2, 4)),

        -- A backwards range is a data-entry slip that silently matches nobody.
        CONSTRAINT CK_t_app_jobs_Salary
            CHECK (SalaryMin IS NULL OR SalaryMax IS NULL OR SalaryMin <= SalaryMax),
        CONSTRAINT CK_t_app_jobs_Experience
            CHECK (MinExperienceMonths IS NULL OR MaxExperienceMonths IS NULL
                OR MinExperienceMonths <= MaxExperienceMonths),
        CONSTRAINT CK_t_app_jobs_Vacancies CHECK (NoOfVacancies >= 1),
        CONSTRAINT CK_t_app_jobs_NonNegativeSalary
            CHECK ((SalaryMin IS NULL OR SalaryMin >= 0) AND (SalaryMax IS NULL OR SalaryMax >= 0)),
        CONSTRAINT CK_t_app_jobs_Counts CHECK (ViewCount >= 0 AND ApplicationCount >= 0),

        CONSTRAINT CK_t_app_jobs_IsSalaryNegotiable CHECK (IsSalaryNegotiable IN (0, 1)),
        CONSTRAINT CK_t_app_jobs_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_jobs_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_jobs] already exists — skipped.';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_jobs_JobUid' AND object_id = OBJECT_ID('dbo.t_app_jobs'))
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_jobs_JobUid
        ON dbo.t_app_jobs (JobUid) WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  The school's own list — the shape every school-side read takes.

  Leading on (SchoolId, BranchId) because every one of those reads joins through
  fn_VisibleBranches, which produces a branch set: the scope filter and the
  index agree.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_jobs_SchoolBranchStatus' AND object_id = OBJECT_ID('dbo.t_app_jobs'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_t_app_jobs_SchoolBranchStatus
        ON dbo.t_app_jobs (SchoolId, BranchId, JobStatusId)
        INCLUDE (JobUid, JobTitle, SubjectId, LastDateToApply, PublishedOn, NoOfVacancies)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  The public search's shape, ahead of Phase 6 needing it.

  ⚠️ Filtered on JobStatusId = 2 only. Expired jobs are Active rows, so the
  public read still has to apply the date predicate — the index narrows the set,
  fn_EffectiveJobStatusId decides. Filtering the index on the date instead is
  impossible: a filtered index cannot reference a moving "today".
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_jobs_LiveByDate' AND object_id = OBJECT_ID('dbo.t_app_jobs'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_t_app_jobs_LiveByDate
        ON dbo.t_app_jobs (JobStatusId, LastDateToApply)
        INCLUDE (JobUid, SchoolId, BranchId, JobTitle, SubjectId, CityId, StateId, PublishedOn)
        WHERE Is_Deleted = 0 AND JobStatusId = 2;
END
GO


/*==============================================================================
  t_app_job_subjects — the full subject set for a multi-subject posting.

  ⚠️ t_app_jobs.SubjectId is the PRIMARY subject and is not duplicated here by
  convention — the save procedure writes the whole set including the primary, so
  a reader of this table alone sees every subject the job is for. Two places
  that must agree is worse than one place that repeats itself.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_job_subjects' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_job_subjects] ...';

    CREATE TABLE dbo.t_app_job_subjects
    (
        Id          bigint     IDENTITY(1,1) NOT NULL,
        JobId       bigint     NOT NULL,
        SubjectId   int        NOT NULL,          -- ⚠️ cross-DB, no FK (2.2)

        Is_Active   tinyint    NOT NULL CONSTRAINT DF_t_app_job_subjects_Is_Active  DEFAULT (1),
        Is_Deleted  tinyint    NOT NULL CONSTRAINT DF_t_app_job_subjects_Is_Deleted DEFAULT (0),
        CreatedOn   datetime2  NOT NULL CONSTRAINT DF_t_app_job_subjects_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy   bigint     NULL,
        ModifiedOn  datetime2  NULL,
        ModifiedBy  bigint     NULL,

        CONSTRAINT PK_t_app_job_subjects PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_t_app_job_subjects_Job FOREIGN KEY (JobId) REFERENCES dbo.t_app_jobs (JobId),
        CONSTRAINT CK_t_app_job_subjects_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_job_subjects_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_job_subjects] already exists — skipped.';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_job_subjects_JobSubject' AND object_id = OBJECT_ID('dbo.t_app_job_subjects'))
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_job_subjects_JobSubject
        ON dbo.t_app_job_subjects (JobId, SubjectId) WHERE Is_Deleted = 0;
END
GO


/*==============================================================================
  t_app_job_class_levels
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_job_class_levels' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_job_class_levels] ...';

    CREATE TABLE dbo.t_app_job_class_levels
    (
        Id            bigint     IDENTITY(1,1) NOT NULL,
        JobId         bigint     NOT NULL,
        ClassLevelId  int        NOT NULL,      -- ⚠️ cross-DB, no FK (2.2)

        Is_Active     tinyint    NOT NULL CONSTRAINT DF_t_app_job_class_levels_Is_Active  DEFAULT (1),
        Is_Deleted    tinyint    NOT NULL CONSTRAINT DF_t_app_job_class_levels_Is_Deleted DEFAULT (0),
        CreatedOn     datetime2  NOT NULL CONSTRAINT DF_t_app_job_class_levels_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy     bigint     NULL,
        ModifiedOn    datetime2  NULL,
        ModifiedBy    bigint     NULL,

        CONSTRAINT PK_t_app_job_class_levels PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_t_app_job_class_levels_Job FOREIGN KEY (JobId) REFERENCES dbo.t_app_jobs (JobId),
        CONSTRAINT CK_t_app_job_class_levels_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_job_class_levels_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_job_class_levels] already exists — skipped.';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_job_class_levels_JobLevel' AND object_id = OBJECT_ID('dbo.t_app_job_class_levels'))
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_job_class_levels_JobLevel
        ON dbo.t_app_job_class_levels (JobId, ClassLevelId) WHERE Is_Deleted = 0;
END
GO

PRINT '    Job tables ready.';
GO
