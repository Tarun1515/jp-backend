/*==============================================================================
  jp_app — 010_t_app_school_user_branches.sql

  Which campuses a school user is scoped to.

  ---------------------------------------------------------------------------
  ⚠️ NO ROWS MEANS ALL BRANCHES, AND THAT HAS TO BE WRITTEN DOWN
  ---------------------------------------------------------------------------
  An owner is not enumerated against every campus — they have no rows here and
  see everything. Rows exist to NARROW somebody, typically an HR user attached
  to one campus.

  This is the kind of convention that is obvious while it is being written and
  invisible six months later, so it is stated here and enforced in the
  procedure. The alternative — inserting a row per branch for every owner —
  means every new campus needs a backfill across every owner, and the day one is
  missed an owner quietly loses a campus.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_school_user_branches' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_school_user_branches] ...';

    CREATE TABLE dbo.t_app_school_user_branches
    (
        Id              bigint      IDENTITY(1,1) NOT NULL,
        SchoolUserId    bigint      NOT NULL,
        BranchId        bigint      NOT NULL,

        -- ---- standard columns -------------------------------------------------
        Is_Active       tinyint     NOT NULL CONSTRAINT DF_t_app_school_user_branches_Is_Active  DEFAULT (1),
        Is_Deleted      tinyint     NOT NULL CONSTRAINT DF_t_app_school_user_branches_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2   NOT NULL CONSTRAINT DF_t_app_school_user_branches_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint      NULL,
        ModifiedOn      datetime2   NULL,
        ModifiedBy      bigint      NULL,

        CONSTRAINT PK_t_app_school_user_branches PRIMARY KEY CLUSTERED (Id),
        CONSTRAINT FK_t_app_school_user_branches_t_app_school_users
            FOREIGN KEY (SchoolUserId) REFERENCES dbo.t_app_school_users (SchoolUserId),
        CONSTRAINT FK_t_app_school_user_branches_t_app_school_branches
            FOREIGN KEY (BranchId) REFERENCES dbo.t_app_school_branches (BranchId),
        CONSTRAINT CK_t_app_school_user_branches_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_school_user_branches_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_school_user_branches] already exists — skipped.';
END
GO
/*------------------------------------------------------------------------------
  🔴 ONE ROW PER PERSON PER CAMPUS.

  A duplicate here is worse than untidy: this table is joined to when listing
  what somebody can see, and a second row multiplies their branch list — the
  same campus appearing twice in a dropdown, which reads as a bug in the
  branches feature rather than in this table.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_school_user_branches_SchoolUserId_BranchId'
                 AND object_id = OBJECT_ID('dbo.t_app_school_user_branches'))
BEGIN
    PRINT '    Creating index [UQ_t_app_school_user_branches_SchoolUserId_BranchId] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_school_user_branches_SchoolUserId_BranchId
        ON dbo.t_app_school_user_branches (SchoolUserId, BranchId)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  The other direction: everybody scoped to one campus.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_school_user_branches_BranchId' AND object_id = OBJECT_ID('dbo.t_app_school_user_branches'))
BEGIN
    PRINT '    Creating index [IX_t_app_school_user_branches_BranchId] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_school_user_branches_BranchId
        ON dbo.t_app_school_user_branches (BranchId)
        INCLUDE (SchoolUserId)
        WHERE Is_Deleted = 0;
END
GO
