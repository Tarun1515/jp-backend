/*==============================================================================
  jp_app — 024_t_app_applications.sql

  Applications, their status history, and saved jobs. Phase 5.

  ---------------------------------------------------------------------------
  🔴 AN APPLICATION IS CONSENT. IT IS WHAT OPENS A TEACHER'S CONTACT DETAILS.
  ---------------------------------------------------------------------------
  Decision 2.56 (LOCKED) says a school sees a teacher's phone number and email
  on exactly two paths: the teacher applied to them, or the teacher accepted
  their invitation. Until this table existed, NEITHER path could happen —
  fn_TeacherContactUnlocked returned a hard 0 and said "Phase 5 replaces this".

  A row here IS path 1. That makes this table the most privacy-significant one
  in the product, and it is why:

    - a row is never hard-deleted (2.4) — consent that was given is a fact, and
      erasing it would silently re-lock contact with no trace of why;
    - there is no withdraw in this phase (G28) — a half-built withdraw that
      soft-deleted the row would revoke contact through a path nobody designed;
    - SchoolId and BranchId are DENORMALISED onto the row (see below), so the
      unlock check never depends on the job still existing or still being
      readable.

  ⚠️ NEVER add a third path. Not "the school has a paid plan", not "the school
  has invites left". A subscription buys capability — search, invites — never
  contact. If a requirement seems to need payment here, the requirement is
  being described wrongly.

  ---------------------------------------------------------------------------
  🔴 ApplicationCount ON t_app_jobs IS NOT MAINTAINED FROM HERE
  ---------------------------------------------------------------------------
  The column exists on t_app_jobs and Phase 5 deliberately leaves it at zero.
  The count is DERIVED — COUNT of live application rows — everywhere it is
  shown, the same way quota use and job expiry are derived.

  Do not "fix" it by adding an UPDATE here or a trigger. A maintained counter
  is a second source of truth that drifts, and the drift is silent: the number
  on a screen stops matching the list underneath it and nothing errors. 2.5
  made this argument for balances, 4 for expiry; it is the same argument.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  t_app_applications
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_applications' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_applications] ...';

    CREATE TABLE dbo.t_app_applications
    (
        ApplicationId        bigint            IDENTITY(1,1) NOT NULL,
        ApplicationUid       uniqueidentifier  NOT NULL CONSTRAINT DF_t_app_applications_ApplicationUid DEFAULT (NEWID()),

        JobId                bigint            NOT NULL,
        TeacherId            bigint            NOT NULL,

        /*
          🔴 DENORMALISED FROM THE JOB, ON PURPOSE.

          Both are derivable by joining t_app_jobs, and both are copied here
          anyway because they are what SCOPES this row:

            - the contact-unlock check asks "did this teacher apply to THIS
              school", and it must answer correctly even if the job is later
              closed, or the branch is soft-deleted, or a future phase moves a
              job between campuses;
            - branch-bound HR filtering joins fn_VisibleBranches on BranchId,
              and routing that through the job would put the school's own
              scoping rule behind an extra join that somebody will forget.

          ⚠️ They are written ONCE at apply and never updated. If a job moves
          campus afterwards, the application stays with the campus it was made
          to — which is the honest record of what the teacher applied to.
        */
        SchoolId             bigint            NOT NULL,
        BranchId             bigint            NOT NULL,

        ApplicationStatusId  int               NOT NULL CONSTRAINT DF_t_app_applications_StatusId DEFAULT (1),

        AppliedOn            datetime2         NOT NULL CONSTRAINT DF_t_app_applications_AppliedOn DEFAULT (SYSUTCDATETIME()),

        /*
          Stamped the first time a school opens the application, alongside the
          Applied -> Viewed transition. NULL means nobody has looked yet, and
          the teacher's list says exactly that.
        */
        ViewedOn             datetime2         NULL,

        /*
          🔴 THE RESUME AS IT WAS AT THE MOMENT OF APPLYING.

          NOT a join to t_app_teachers.ResumePath. A teacher who replaces their
          resume next month must not retroactively change the document a school
          already read and made a decision on — and a school that shortlisted
          somebody must be able to see what it actually shortlisted.

          ⚠️ Nullable ONLY because a row could in principle predate the rule.
          The apply procedure refuses an application with no resume, so in
          practice this is never null on a row it wrote.
        */
        ResumePathSnapshot   nvarchar(500)     NULL,

        CoverNote            nvarchar(2000)    NULL,

        /*
          The school's own note on why. ⚠️ NEVER shown to the teacher in this
          phase — the teacher-facing status is "Not selected" and nothing more.
          Free text written for one audience has a way of reaching the other.
        */
        RejectionReason      nvarchar(1000)    NULL,

        Is_Active            tinyint           NOT NULL CONSTRAINT DF_t_app_applications_Is_Active  DEFAULT (1),
        Is_Deleted           tinyint           NOT NULL CONSTRAINT DF_t_app_applications_Is_Deleted DEFAULT (0),
        CreatedOn            datetime2         NOT NULL CONSTRAINT DF_t_app_applications_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy            bigint            NULL,
        ModifiedOn           datetime2         NULL,
        ModifiedBy           bigint            NULL,
        RowVersion           int               NOT NULL CONSTRAINT DF_t_app_applications_RowVersion DEFAULT (1),

        CONSTRAINT PK_t_app_applications PRIMARY KEY CLUSTERED (ApplicationId),

        CONSTRAINT FK_t_app_applications_Job     FOREIGN KEY (JobId)     REFERENCES dbo.t_app_jobs (JobId),
        CONSTRAINT FK_t_app_applications_Teacher FOREIGN KEY (TeacherId) REFERENCES dbo.t_app_teachers (TeacherId),
        CONSTRAINT FK_t_app_applications_School  FOREIGN KEY (SchoolId)  REFERENCES dbo.t_app_schools (SchoolId),
        CONSTRAINT FK_t_app_applications_Branch  FOREIGN KEY (BranchId)  REFERENCES dbo.t_app_school_branches (BranchId),
        CONSTRAINT FK_t_app_applications_Status
            FOREIGN KEY (ApplicationStatusId) REFERENCES dbo.m_app_application_status (ApplicationStatusId),

        /*
          ⚠️ 7..10 are NOT excluded by a CHECK, unlike jobs' Expired.

          Expired is derived and must never be stored, so a constraint is the
          right guard. These four are perfectly legitimate stored values — just
          not yet reachable, because the action that would produce them does not
          exist. A CHECK here would have to be dropped in Phase 6, and a
          constraint that is expected to be removed teaches nothing.

          The transition map refuses them, and the verification proves it.
        */

        CONSTRAINT CK_t_app_applications_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_applications_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_applications] already exists — skipped.';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_applications_ApplicationUid' AND object_id = OBJECT_ID('dbo.t_app_applications'))
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_applications_ApplicationUid
        ON dbo.t_app_applications (ApplicationUid) WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  🔴 ONE APPLICATION PER TEACHER PER JOB — AND THIS INDEX IS THE ENFORCEMENT.

  Not a SELECT-then-INSERT in the procedure, which two parallel applies would
  both pass. The storage layer refuses the second one, and the procedure reads
  2601 as "already applied" — but only after re-reading the row (2.48).

  ⚠️ THE CATCH MUST CHECK *WHICH* INDEX COLLIDED. 3C's lesson, literally: a
  CATCH that treats any 2601 as "already done" will one day swallow a completely
  different duplicate and report success for something that did not happen.
  USP_ApplyToJob compares the error message against this index name.

  Filtered on Is_Deleted = 0 so a future withdraw-and-reapply is possible
  without a schema change (G28) — the filter is the door being left unlocked,
  not the feature.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_applications_JobTeacher' AND object_id = OBJECT_ID('dbo.t_app_applications'))
BEGIN
    PRINT '    Creating index [UQ_t_app_applications_JobTeacher] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_applications_JobTeacher
        ON dbo.t_app_applications (JobId, TeacherId)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  The school's applicant list — school-wide and per-branch, newest first.

  Leading on (SchoolId, BranchId) because every school-side read joins
  fn_VisibleBranches, so the scope filter and the index agree.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_applications_SchoolBranch' AND object_id = OBJECT_ID('dbo.t_app_applications'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_t_app_applications_SchoolBranch
        ON dbo.t_app_applications (SchoolId, BranchId, ApplicationStatusId, AppliedOn)
        INCLUDE (ApplicationUid, JobId, TeacherId, ViewedOn)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  The teacher's own list, and the contact-unlock check.

  🔴 fn_TeacherContactUnlocked asks "does a live row exist for this teacher at
  this school" on every browse of every teacher. It has to be a seek.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_applications_TeacherSchool' AND object_id = OBJECT_ID('dbo.t_app_applications'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_t_app_applications_TeacherSchool
        ON dbo.t_app_applications (TeacherId, SchoolId)
        INCLUDE (JobId, ApplicationStatusId, AppliedOn)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  Per-job applicant list, and the derived ApplicationCount.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_applications_Job' AND object_id = OBJECT_ID('dbo.t_app_applications'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_t_app_applications_Job
        ON dbo.t_app_applications (JobId, ApplicationStatusId)
        INCLUDE (TeacherId, AppliedOn, ViewedOn)
        WHERE Is_Deleted = 0;
END
GO


/*==============================================================================
  t_app_application_status_history

  🔴 APPEND-ONLY. Every status change writes a row; nothing updates or deletes
  one. The application carries the CURRENT status; this carries how it got
  there and who moved it.

  ⚠️ ChangedByUserId is the jp_sso user, NOT a school-user id. "Who did this"
  must survive somebody being removed from the school's team — 3G made that
  removable, and an audit trail that loses its actor when the actor leaves is
  an audit trail that fails exactly when it is needed.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_application_status_history' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_application_status_history] ...';

    CREATE TABLE dbo.t_app_application_status_history
    (
        HistoryId        bigint         IDENTITY(1,1) NOT NULL,
        ApplicationId    bigint         NOT NULL,

        /*
          NULL on the very first row — the one written when the application is
          created. "From nothing to Applied" is the honest shape; writing
          FromStatusId = 1 there would claim a transition that never happened.
        */
        FromStatusId     int            NULL,
        ToStatusId       int            NOT NULL,

        ChangedByUserId  bigint         NULL,
        Remarks          nvarchar(1000) NULL,
        ChangedOn        datetime2      NOT NULL CONSTRAINT DF_t_app_ash_ChangedOn DEFAULT (SYSUTCDATETIME()),

        Is_Active        tinyint        NOT NULL CONSTRAINT DF_t_app_ash_Is_Active  DEFAULT (1),
        Is_Deleted       tinyint        NOT NULL CONSTRAINT DF_t_app_ash_Is_Deleted DEFAULT (0),
        CreatedOn        datetime2      NOT NULL CONSTRAINT DF_t_app_ash_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy        bigint         NULL,
        ModifiedOn       datetime2      NULL,
        ModifiedBy       bigint         NULL,

        CONSTRAINT PK_t_app_application_status_history PRIMARY KEY CLUSTERED (HistoryId),
        CONSTRAINT FK_t_app_ash_Application
            FOREIGN KEY (ApplicationId) REFERENCES dbo.t_app_applications (ApplicationId),
        CONSTRAINT FK_t_app_ash_From FOREIGN KEY (FromStatusId) REFERENCES dbo.m_app_application_status (ApplicationStatusId),
        CONSTRAINT FK_t_app_ash_To   FOREIGN KEY (ToStatusId)   REFERENCES dbo.m_app_application_status (ApplicationStatusId),

        -- A transition to where it already was is not a transition.
        CONSTRAINT CK_t_app_ash_Moved CHECK (FromStatusId IS NULL OR FromStatusId <> ToStatusId),

        CONSTRAINT CK_t_app_ash_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_ash_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_application_status_history] already exists — skipped.';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_ash_Application' AND object_id = OBJECT_ID('dbo.t_app_application_status_history'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_t_app_ash_Application
        ON dbo.t_app_application_status_history (ApplicationId, ChangedOn)
        INCLUDE (FromStatusId, ToStatusId, ChangedByUserId)
        WHERE Is_Deleted = 0;
END
GO


/*==============================================================================
  t_app_saved_jobs — a teacher's shortlist of jobs to come back to.

  ⚠️ Small, and deliberately NOT an application. Saving is private to the
  teacher, tells the school nothing, and — 🔴 critically — does NOT unlock
  contact. Only applying does (2.56). A "saved" row must never appear in any
  question fn_TeacherContactUnlocked asks.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_saved_jobs' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_saved_jobs] ...';

    CREATE TABLE dbo.t_app_saved_jobs
    (
        Id          bigint     IDENTITY(1,1) NOT NULL,
        TeacherId   bigint     NOT NULL,
        JobId       bigint     NOT NULL,
        SavedOn     datetime2  NOT NULL CONSTRAINT DF_t_app_saved_jobs_SavedOn DEFAULT (SYSUTCDATETIME()),

        Is_Active   tinyint    NOT NULL CONSTRAINT DF_t_app_saved_jobs_Is_Active  DEFAULT (1),
        Is_Deleted  tinyint    NOT NULL CONSTRAINT DF_t_app_saved_jobs_Is_Deleted DEFAULT (0),
        CreatedOn   datetime2  NOT NULL CONSTRAINT DF_t_app_saved_jobs_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy   bigint     NULL,
        ModifiedOn  datetime2  NULL,
        ModifiedBy  bigint     NULL,

        CONSTRAINT PK_t_app_saved_jobs PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_t_app_saved_jobs_Teacher FOREIGN KEY (TeacherId) REFERENCES dbo.t_app_teachers (TeacherId),
        CONSTRAINT FK_t_app_saved_jobs_Job     FOREIGN KEY (JobId)     REFERENCES dbo.t_app_jobs (JobId),
        CONSTRAINT CK_t_app_saved_jobs_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_saved_jobs_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_saved_jobs] already exists — skipped.';
END
GO
/*
  Filtered on Is_Deleted = 0 so unsaving and saving again is a soft-delete and
  a revive, not a new row every time somebody changes their mind (2.4).
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_saved_jobs_TeacherJob' AND object_id = OBJECT_ID('dbo.t_app_saved_jobs'))
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_saved_jobs_TeacherJob
        ON dbo.t_app_saved_jobs (TeacherId, JobId) WHERE Is_Deleted = 0;
END
GO

PRINT '    Application tables ready.';
GO
