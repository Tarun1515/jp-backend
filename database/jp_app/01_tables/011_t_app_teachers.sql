/*==============================================================================
  jp_app — 011_t_app_teachers.sql

  The teacher profile. The table G12 has been waiting for.

  ---------------------------------------------------------------------------
  🔴 CREATING THIS TABLE IS ONE OF THREE THINGS PHASE 3 OWES
  ---------------------------------------------------------------------------
  A teacher's account has been Active from signup since Phase 1 (decision 2.9),
  with no profile row anywhere. So this table arriving is not the end of it:

      1. create it                                  <- this script
      2. BACKFILL a profile for every teacher who registered before it existed
      3. assign TEACHER_FREE to all of them          (2.50)

  Steps 2 and 3 are Phase 3B, and doing only step 1 leaves every early teacher
  broken in a new way — a null reference in Phase 5 rather than an obviously
  missing row. See G12.

  ---------------------------------------------------------------------------
  DOB IS A `date`, AND VerifiedOn IS NOT
  ---------------------------------------------------------------------------
  A date of birth is a CALENDAR DAY, not an instant (decision 2.28). Stored as
  datetime2 it shifts by timezone, and somebody born on the 1st becomes somebody
  born on the 31st for five and a half hours a day.

  VerifiedOn records WHEN SOMETHING HAPPENED, so it stays datetime2 UTC. The
  test is not "does it have a time on it" — it is "is this a day, or a moment".

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_teachers' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_teachers] ...';

    CREATE TABLE dbo.t_app_teachers
    (
        TeacherId               bigint              IDENTITY(1,1) NOT NULL,
        TeacherUid              uniqueidentifier    NOT NULL
            CONSTRAINT DF_t_app_teachers_TeacherUid DEFAULT (NEWID()),

        /*
          ⚠️ CROSS-DATABASE — t_sso_users.UserUid in jp_sso. No foreign key
          (decision 2.2), validated in the procedure, indexed below.

          uniqueidentifier, matching the live column rather than the bigint
          UserId. One profile per account is enforced by the unique index below.
        */
        UserUid                 uniqueidentifier    NOT NULL,

        FullName                nvarchar(150)       NOT NULL,
        PhotoPath               nvarchar(500)       NULL,

        -- 🔴 A calendar day, not an instant (2.28).
        DOB                     date                NULL,

        /*
          ⚠️ CROSS-DATABASE masters in jp_mdm — gender, qualification,
          designation, city, state. No foreign keys; all int, verified against
          the live columns. Each is indexed below, because a reference with no
          constraint is still a reference that gets filtered on.
        */
        GenderId                int                 NULL,
        QualificationId         int                 NULL,

        -- What they call their own highest qualification, when the master has
        -- no row that fits. "M.A. (English) + B.Ed" is not a dropdown value.
        HighestQualificationText nvarchar(200)      NULL,

        DesignationId           int                 NULL,
        TotalExperienceMonths   int                 NULL,

        CurrentSchool           nvarchar(200)       NULL,
        LastSchool              nvarchar(200)       NULL,

        /*
          Expected salary, monthly, in rupees. decimal(12,2) rather than money:
          money's four-decimal scale and rounding behaviour are a liability
          nobody wants in an arithmetic they will eventually do.
        */
        ExpectedSalaryMin       decimal(12, 2)      NULL,
        ExpectedSalaryMax       decimal(12, 2)      NULL,

        CurrentCityId           int                 NULL,
        CurrentStateId          int                 NULL,

        AboutMe                 nvarchar(max)       NULL,
        ResumePath              nvarchar(500)       NULL,

        /*
          🔴 Verification is a BADGE, not a gate (decision 2.9).

          A teacher's account is usable from signup. This says whether a person
          has checked their documents, and it is what a school sees on their
          profile — it never decides whether they may sign in.
        */
        IsVerified              tinyint             NOT NULL
            CONSTRAINT DF_t_app_teachers_IsVerified DEFAULT (0),

        -- An event, so UTC datetime2 (2.28).
        VerifiedOn              datetime2           NULL,

        IsSuspended             tinyint             NOT NULL
            CONSTRAINT DF_t_app_teachers_IsSuspended DEFAULT (0),

        /*
          🔴 A PLAIN COLUMN, WRITTEN BY THE SERVER — not a computed column.

          "Complete" is a product judgement that will change: today it might be
          photo + subjects + one experience, next quarter it includes a resume.
          A persisted computed column would put that argument in the schema,
          where changing it is a migration and where the rule is invisible to
          anybody reading the code that displays it.

          Phase 3D computes and writes this.
        */
        ProfileCompletionPercent tinyint            NOT NULL
            CONSTRAINT DF_t_app_teachers_ProfileCompletionPercent DEFAULT (0),

        -- ---- standard columns -------------------------------------------------
        Is_Active               tinyint             NOT NULL CONSTRAINT DF_t_app_teachers_Is_Active  DEFAULT (1),
        Is_Deleted              tinyint             NOT NULL CONSTRAINT DF_t_app_teachers_Is_Deleted DEFAULT (0),
        CreatedOn               datetime2           NOT NULL CONSTRAINT DF_t_app_teachers_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy               bigint              NULL,
        ModifiedOn              datetime2           NULL,
        ModifiedBy              bigint              NULL,
        RowVersion              int                 NOT NULL CONSTRAINT DF_t_app_teachers_RowVersion DEFAULT (1),

        CONSTRAINT PK_t_app_teachers PRIMARY KEY CLUSTERED (TeacherId),
        CONSTRAINT CK_t_app_teachers_IsVerified  CHECK (IsVerified  IN (0, 1)),
        CONSTRAINT CK_t_app_teachers_IsSuspended CHECK (IsSuspended IN (0, 1)),
        CONSTRAINT CK_t_app_teachers_Is_Active   CHECK (Is_Active   IN (0, 1)),
        CONSTRAINT CK_t_app_teachers_Is_Deleted  CHECK (Is_Deleted  IN (0, 1)),
        CONSTRAINT CK_t_app_teachers_ProfileCompletionPercent
            CHECK (ProfileCompletionPercent BETWEEN 0 AND 100),

        /*
          A range that runs backwards is not a preference, it is a typo — and
          one that would make every salary filter in Phase 4 return nothing for
          this teacher with no error anywhere.
        */
        CONSTRAINT CK_t_app_teachers_ExpectedSalaryRange
            CHECK (ExpectedSalaryMin IS NULL OR ExpectedSalaryMax IS NULL
                   OR ExpectedSalaryMax >= ExpectedSalaryMin)
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_teachers] already exists — skipped.';
END
GO
/*------------------------------------------------------------------------------
  The public identifier. UNFILTERED on purpose: a Uid must never be reused, even
  after a soft delete, or an old profile URL resolves to a different teacher.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_teachers_TeacherUid' AND object_id = OBJECT_ID('dbo.t_app_teachers'))
BEGIN
    PRINT '    Creating index [UQ_t_app_teachers_TeacherUid] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_teachers_TeacherUid
        ON dbo.t_app_teachers (TeacherUid);
END
GO
/*------------------------------------------------------------------------------
  🔴 ONE PROFILE PER ACCOUNT.

  This is the index that makes the Phase 3B backfill safe to run twice. Without
  it, a re-run creates a second profile for everybody, and from then on "the
  teacher's profile" is whichever row a query read first — subjects on one,
  experience on the other, and no error anywhere.

  Filtered, so a deleted profile frees its account to start again.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_teachers_UserUid' AND object_id = OBJECT_ID('dbo.t_app_teachers'))
BEGIN
    PRINT '    Creating index [UQ_t_app_teachers_UserUid] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_teachers_UserUid
        ON dbo.t_app_teachers (UserUid)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  The teacher search's coarsest filter: where they are.

  Phase 4 searches by location first and narrows from there, so this carries the
  columns a result card needs rather than making every hit go back to the table.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_teachers_Location' AND object_id = OBJECT_ID('dbo.t_app_teachers'))
BEGIN
    PRINT '    Creating index [IX_t_app_teachers_Location] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_teachers_Location
        ON dbo.t_app_teachers (CurrentStateId, CurrentCityId)
        INCLUDE (TeacherUid, FullName, DesignationId, TotalExperienceMonths, IsVerified)
        WHERE Is_Deleted = 0 AND IsSuspended = 0;
END
GO
/*------------------------------------------------------------------------------
  ⚠️ The cross-database master references, indexed BECAUSE they have no foreign
  keys. Each is a filter on the teacher search.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_teachers_QualificationId' AND object_id = OBJECT_ID('dbo.t_app_teachers'))
BEGIN
    PRINT '    Creating index [IX_t_app_teachers_QualificationId] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_teachers_QualificationId
        ON dbo.t_app_teachers (QualificationId)
        WHERE Is_Deleted = 0;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_teachers_DesignationId' AND object_id = OBJECT_ID('dbo.t_app_teachers'))
BEGIN
    PRINT '    Creating index [IX_t_app_teachers_DesignationId] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_teachers_DesignationId
        ON dbo.t_app_teachers (DesignationId)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  Experience, which every teacher search filters on as a range.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_teachers_TotalExperienceMonths' AND object_id = OBJECT_ID('dbo.t_app_teachers'))
BEGIN
    PRINT '    Creating index [IX_t_app_teachers_TotalExperienceMonths] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_teachers_TotalExperienceMonths
        ON dbo.t_app_teachers (TotalExperienceMonths)
        INCLUDE (TeacherUid, FullName, CurrentCityId, CurrentStateId)
        WHERE Is_Deleted = 0 AND IsSuspended = 0;
END
GO
