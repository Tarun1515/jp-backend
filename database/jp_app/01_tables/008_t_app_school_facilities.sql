/*==============================================================================
  jp_app — 008_t_app_school_facilities.sql

  Which facilities a school, or one of its campuses, has.

  BranchId nullable for the same reason as the photos table: "we have a library"
  can be true of the school as a whole or of one campus, and the two are
  different claims.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_school_facilities' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_school_facilities] ...';

    CREATE TABLE dbo.t_app_school_facilities
    (
        Id              bigint      IDENTITY(1,1) NOT NULL,
        SchoolId        bigint      NOT NULL,

        -- NULL = the school as a whole.
        BranchId        bigint      NULL,

        /*
          ⚠️ CROSS-DATABASE — m_mdm_facility in jp_mdm. NO foreign key, and
          never one (decision 2.2): SQL Server cannot enforce a FK across
          databases, and adding one does not fail at review, it fails to
          compile. Validated in the procedure, and indexed below because an
          unenforced reference still gets read.

          int, matching m_mdm_facility.FacilityId — verified against the live
          column, not the spec table.
        */
        FacilityId      int         NOT NULL,

        -- ---- standard columns -------------------------------------------------
        Is_Active       tinyint     NOT NULL CONSTRAINT DF_t_app_school_facilities_Is_Active  DEFAULT (1),
        Is_Deleted      tinyint     NOT NULL CONSTRAINT DF_t_app_school_facilities_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2   NOT NULL CONSTRAINT DF_t_app_school_facilities_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint      NULL,
        ModifiedOn      datetime2   NULL,
        ModifiedBy      bigint      NULL,

        CONSTRAINT PK_t_app_school_facilities PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_t_app_school_facilities_t_app_schools
            FOREIGN KEY (SchoolId) REFERENCES dbo.t_app_schools (SchoolId),
        CONSTRAINT FK_t_app_school_facilities_t_app_school_branches
            FOREIGN KEY (BranchId) REFERENCES dbo.t_app_school_branches (BranchId),
        CONSTRAINT CK_t_app_school_facilities_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_school_facilities_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_school_facilities] already exists — skipped.';
END
GO
/*------------------------------------------------------------------------------
  🔴 THE SAME FACILITY, ONCE PER SCOPE.

  Three columns rather than the usual two, because the scope is (school, branch)
  and not school alone. On (SchoolId, FacilityId) a school with a library at two
  campuses could only record one of them.

  ⚠️ SQL Server treats NULLs as EQUAL inside a unique index, which is exactly
  what is wanted here: (SchoolId, NULL, FacilityId) can appear once, so the
  school-level claim is also protected from being duplicated.

  Filtered so a facility removed and later re-added is allowed.

  A facility listed twice is a data bug that surfaces as a duplicate chip on a
  profile, and nobody traces a duplicate chip back to a missing index.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_school_facilities_SchoolId_BranchId_FacilityId'
                 AND object_id = OBJECT_ID('dbo.t_app_school_facilities'))
BEGIN
    PRINT '    Creating index [UQ_t_app_school_facilities_SchoolId_BranchId_FacilityId] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_school_facilities_SchoolId_BranchId_FacilityId
        ON dbo.t_app_school_facilities (SchoolId, BranchId, FacilityId)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  ⚠️ The cross-database reference, indexed BECAUSE it has no foreign key.

  "Which schools have a science lab" is a Phase 4 filter, and without this it is
  a scan of every facility row in the system.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_school_facilities_FacilityId' AND object_id = OBJECT_ID('dbo.t_app_school_facilities'))
BEGIN
    PRINT '    Creating index [IX_t_app_school_facilities_FacilityId] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_school_facilities_FacilityId
        ON dbo.t_app_school_facilities (FacilityId)
        INCLUDE (SchoolId, BranchId)
        WHERE Is_Deleted = 0;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_school_facilities_BranchId' AND object_id = OBJECT_ID('dbo.t_app_school_facilities'))
BEGIN
    PRINT '    Creating index [IX_t_app_school_facilities_BranchId] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_school_facilities_BranchId
        ON dbo.t_app_school_facilities (BranchId)
        WHERE BranchId IS NOT NULL AND Is_Deleted = 0;
END
GO
