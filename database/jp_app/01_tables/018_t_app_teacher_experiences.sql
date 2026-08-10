/*==============================================================================
  jp_app — 018_t_app_teacher_experiences.sql

  Where a teacher has worked before.

  ---------------------------------------------------------------------------
  🔴 FromDate AND ToDate ARE `date`, NOT datetime2
  ---------------------------------------------------------------------------
  Nobody knows the hour they started at a school, and nobody means one. These
  are calendar days (decision 2.28), and stored as datetime2 they would shift
  across a month boundary by timezone — somebody who started on 1 April would
  read as having started on 31 March for five and a half hours a day.

  ToDate is NULL while IsCurrent = 1. The two are kept consistent by a CHECK
  rather than by hoping the API remembers, because "current job with an end
  date" is exactly the sort of contradiction that reaches a profile screen and
  gets explained as a display bug.

  ---------------------------------------------------------------------------
  SchoolName IS FREE TEXT, AND STAYS THAT WAY
  ---------------------------------------------------------------------------
  Not a FK to t_app_schools. A teacher's previous school is almost never on this
  platform, and matching it to one would be a guess this system presented as a
  fact — with the school's own name attached to a claim it never made.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_teacher_experiences' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_teacher_experiences] ...';

    CREATE TABLE dbo.t_app_teacher_experiences
    (
        Id              bigint          IDENTITY(1,1) NOT NULL,
        TeacherId       bigint          NOT NULL,

        -- As the teacher typed it. See the note above on why this is not a FK.
        SchoolName      nvarchar(200)   NOT NULL,

        /*
          ⚠️ CROSS-DATABASE — m_mdm_designation and m_mdm_subject in jp_mdm. No
          foreign keys (decision 2.2); both int, verified against the live
          columns.
        */
        DesignationId   int             NULL,
        SubjectId       int             NULL,

        -- 🔴 Calendar days, not instants (2.28).
        FromDate        date            NOT NULL,
        ToDate          date            NULL,

        IsCurrent       tinyint         NOT NULL CONSTRAINT DF_t_app_teacher_experiences_IsCurrent DEFAULT (0),

        -- ---- standard columns -------------------------------------------------
        Is_Active       tinyint         NOT NULL CONSTRAINT DF_t_app_teacher_experiences_Is_Active  DEFAULT (1),
        Is_Deleted      tinyint         NOT NULL CONSTRAINT DF_t_app_teacher_experiences_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2       NOT NULL CONSTRAINT DF_t_app_teacher_experiences_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint          NULL,
        ModifiedOn      datetime2       NULL,
        ModifiedBy      bigint          NULL,

        CONSTRAINT PK_t_app_teacher_experiences PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_t_app_teacher_experiences_t_app_teachers
            FOREIGN KEY (TeacherId) REFERENCES dbo.t_app_teachers (TeacherId),
        CONSTRAINT CK_t_app_teacher_experiences_IsCurrent  CHECK (IsCurrent  IN (0, 1)),
        CONSTRAINT CK_t_app_teacher_experiences_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_teacher_experiences_Is_Deleted CHECK (Is_Deleted IN (0, 1)),

        /*
          🔴 A current job has no end date, and a past one has one.

          Both halves, because each catches a different mistake: the first stops
          "still working here, left in 2019", the second stops a finished job
          with no end date silently counting as ongoing in any tenure sum.
        */
        CONSTRAINT CK_t_app_teacher_experiences_CurrentHasNoToDate
            CHECK ((IsCurrent = 1 AND ToDate IS NULL) OR (IsCurrent = 0 AND ToDate IS NOT NULL)),

        -- A job that ended before it started is a typo, and one that would make
        -- any experience total computed from these rows quietly wrong.
        CONSTRAINT CK_t_app_teacher_experiences_DateOrder
            CHECK (ToDate IS NULL OR ToDate >= FromDate)
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_teacher_experiences] already exists — skipped.';
END
GO
/*------------------------------------------------------------------------------
  🔴 THERE IS DELIBERATELY NO UNIQUE INDEX HERE.

  The tempting key is (TeacherId, SchoolName, FromDate). It is wrong: somebody
  can genuinely hold two roles at one school starting the same month — a
  part-time subject teacher who also runs the sports programme — and a unique
  index would tell them their own history is invalid.

  There is no natural business key for a period of employment. The protection
  against a double-submit belongs where it can see intent, in the procedure.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_teacher_experiences_TeacherId' AND object_id = OBJECT_ID('dbo.t_app_teacher_experiences'))
BEGIN
    PRINT '    Creating index [IX_t_app_teacher_experiences_TeacherId] ...';

    -- Newest first: a career reads backwards from the current job.
    CREATE NONCLUSTERED INDEX IX_t_app_teacher_experiences_TeacherId
        ON dbo.t_app_teacher_experiences (TeacherId, FromDate DESC)
        INCLUDE (SchoolName, DesignationId, SubjectId, ToDate, IsCurrent)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  ⚠️ The cross-database references, indexed BECAUSE they have no foreign keys.

  "Teachers who have taught physics before" is a Phase 4 filter that reads this
  table rather than the subjects bridge — what somebody has DONE, not what they
  say they can do.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_teacher_experiences_SubjectId' AND object_id = OBJECT_ID('dbo.t_app_teacher_experiences'))
BEGIN
    PRINT '    Creating index [IX_t_app_teacher_experiences_SubjectId] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_teacher_experiences_SubjectId
        ON dbo.t_app_teacher_experiences (SubjectId)
        INCLUDE (TeacherId, DesignationId)
        WHERE SubjectId IS NOT NULL AND Is_Deleted = 0;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_teacher_experiences_DesignationId' AND object_id = OBJECT_ID('dbo.t_app_teacher_experiences'))
BEGIN
    PRINT '    Creating index [IX_t_app_teacher_experiences_DesignationId] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_teacher_experiences_DesignationId
        ON dbo.t_app_teacher_experiences (DesignationId)
        INCLUDE (TeacherId)
        WHERE DesignationId IS NOT NULL AND Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  The current job, which a profile card leads with.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_teacher_experiences_Current' AND object_id = OBJECT_ID('dbo.t_app_teacher_experiences'))
BEGIN
    PRINT '    Creating index [IX_t_app_teacher_experiences_Current] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_teacher_experiences_Current
        ON dbo.t_app_teacher_experiences (TeacherId)
        INCLUDE (SchoolName, DesignationId, FromDate)
        WHERE IsCurrent = 1 AND Is_Deleted = 0;
END
GO
