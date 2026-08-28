/*==============================================================================
  jp_app — 021_job_masters.sql

  The two masters the jobs table points at. Phase 4.

  ---------------------------------------------------------------------------
  ⚠️ m_app_job_status HAS FOUR ROWS, AND ONLY THREE ARE EVER WRITTEN
  ---------------------------------------------------------------------------
  Draft, Active and Closed are stored. **Expired is never written to a row.**

  A job whose LastDateToApply has passed is still an ACTIVE row in the table;
  the reads derive Expired from the date. There is no nightly job that walks
  the table flipping statuses, and that is a decision, not an omission — the
  same one Phase 2.5 made about quota periods:

      a scheduled sweep is a job that will one day not run, and its failure is
      SILENT. Expired jobs would quietly keep accepting applications, and
      nobody would find out from an error.

  Derivation cannot be missed, because there is nothing to run.

  🔴 The one place that mapping lives is dbo.fn_EffectiveJobStatusId. No
  procedure writes the rule out by hand.

  So status 3 exists here because responses return it and screens filter on it —
  it is a real state of a job, just not a stored one.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  m_app_job_status
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_app_job_status' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_app_job_status] ...';

    CREATE TABLE dbo.m_app_job_status
    (
        JobStatusId   int            NOT NULL,
        Code          varchar(30)    NOT NULL,
        Name          nvarchar(100)  NOT NULL,
        DisplayOrder  int            NOT NULL CONSTRAINT DF_m_app_job_status_DisplayOrder DEFAULT (0),

        Is_Active     tinyint        NOT NULL CONSTRAINT DF_m_app_job_status_Is_Active  DEFAULT (1),
        Is_Deleted    tinyint        NOT NULL CONSTRAINT DF_m_app_job_status_Is_Deleted DEFAULT (0),
        CreatedOn     datetime2      NOT NULL CONSTRAINT DF_m_app_job_status_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy     bigint         NULL,
        ModifiedOn    datetime2      NULL,
        ModifiedBy    bigint         NULL,

        CONSTRAINT PK_m_app_job_status PRIMARY KEY CLUSTERED (JobStatusId),
        CONSTRAINT CK_m_app_job_status_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_m_app_job_status_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );

    INSERT INTO dbo.m_app_job_status (JobStatusId, Code, Name, DisplayOrder)
    VALUES (1, 'DRAFT',   N'Draft',   1),
           (2, 'ACTIVE',  N'Active',  2),
           -- ⚠️ Derived, never stored. See the file header.
           (3, 'EXPIRED', N'Expired', 3),
           (4, 'CLOSED',  N'Closed',  4);
END
ELSE
BEGIN
    PRINT '    Table [m_app_job_status] already exists — skipped.';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_m_app_job_status_Code' AND object_id = OBJECT_ID('dbo.m_app_job_status'))
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UQ_m_app_job_status_Code
        ON dbo.m_app_job_status (Code) WHERE Is_Deleted = 0;
END
GO


/*==============================================================================
  m_app_employment_types

  ⚠️ OUR SEED, NOT THE CLIENT'S (2.47). Five buckets that cover Indian school
  hiring as we understand it. The client reconciles by Code; Name is theirs to
  change. A row they do not want becomes Is_Active = 0, never a DELETE.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_app_employment_types' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_app_employment_types] ...';

    CREATE TABLE dbo.m_app_employment_types
    (
        EmploymentTypeId  int            NOT NULL,
        Code              varchar(30)    NOT NULL,
        Name              nvarchar(100)  NOT NULL,
        DisplayOrder      int            NOT NULL CONSTRAINT DF_m_app_employment_types_DisplayOrder DEFAULT (0),

        Is_Active         tinyint        NOT NULL CONSTRAINT DF_m_app_employment_types_Is_Active  DEFAULT (1),
        Is_Deleted        tinyint        NOT NULL CONSTRAINT DF_m_app_employment_types_Is_Deleted DEFAULT (0),
        CreatedOn         datetime2      NOT NULL CONSTRAINT DF_m_app_employment_types_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy         bigint         NULL,
        ModifiedOn        datetime2      NULL,
        ModifiedBy        bigint         NULL,

        CONSTRAINT PK_m_app_employment_types PRIMARY KEY CLUSTERED (EmploymentTypeId),
        CONSTRAINT CK_m_app_employment_types_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_m_app_employment_types_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );

    INSERT INTO dbo.m_app_employment_types (EmploymentTypeId, Code, Name, DisplayOrder)
    VALUES (1, 'FULL_TIME',  N'Full-time', 1),
           (2, 'PART_TIME',  N'Part-time', 2),
           (3, 'CONTRACT',   N'Contract',  3),
           (4, 'VISITING',   N'Visiting',  4),
           (5, 'TEMPORARY',  N'Temporary', 5);
END
ELSE
BEGIN
    PRINT '    Table [m_app_employment_types] already exists — skipped.';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_m_app_employment_types_Code' AND object_id = OBJECT_ID('dbo.m_app_employment_types'))
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UQ_m_app_employment_types_Code
        ON dbo.m_app_employment_types (Code) WHERE Is_Deleted = 0;
END
GO

PRINT '    Job masters ready.';
GO
