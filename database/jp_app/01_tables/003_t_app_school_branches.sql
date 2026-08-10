/*==============================================================================
  jp_app — 003_t_app_school_branches.sql

  A school's campuses. Every school has at least one — the head office — from
  the moment the school exists.

  ⚠️ PULLED FORWARD from Phase 3 by Phase 2F, and the reason is timing rather
  than convenience: PROVISIONING HAPPENS IN 2F. Anything a school must have
  from the moment it exists has to be created in the same transaction that
  creates the school. Adding this later would mean backfilling a head office
  for every school approved in between — the same gap already carried for
  teacher profiles (G12), and there is no value in creating it twice.

  ---------------------------------------------------------------------------
  🔴 WHY EVERY SCHOOL GETS A BRANCH IMMEDIATELY
  ---------------------------------------------------------------------------
  A job is posted at a branch. An application is to a job. If a school could
  exist with no branch, every one of those paths from Phase 4 onward needs a
  nullable-branch code path — and one of them will be missed, in the way that
  surfaces as a null reference two phases later rather than as a missing row.

  So BranchId is never NULL anywhere downstream, and that is guaranteed here
  rather than remembered by each caller.

  Minimum columns for now. Phase 3 adds branch management (naming, editing,
  per-branch contacts, deactivation) by ALTER rather than by editing this
  CREATE.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

-- Filtered indexes REQUIRE these, both to CREATE them and for any later
-- INSERT/UPDATE on the table (decision 2.29).
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_school_branches' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_school_branches] ...';

    CREATE TABLE dbo.t_app_school_branches
    (
        BranchId            bigint            IDENTITY(1,1) NOT NULL,
        BranchUid           uniqueidentifier  NOT NULL CONSTRAINT DF_t_app_school_branches_BranchUid DEFAULT (NEWID()),

        SchoolId            bigint            NOT NULL,

        BranchName          nvarchar(200)     NOT NULL,

        /*
          🔴 Exactly one per school, enforced by a filtered unique index below.

          The head office is not a label — it is the branch a school's own
          address belongs to, and the one anything unassigned falls back to.
          Two of them is not a cosmetic problem: it makes "where is this
          school" ambiguous.
        */
        IsHeadOffice        tinyint           NOT NULL CONSTRAINT DF_t_app_school_branches_IsHeadOffice DEFAULT (0),

        AddressLine1        nvarchar(250)     NULL,
        AddressLine2        nvarchar(250)     NULL,
        -- ⚠️ Nullable, and must stay nullable: the city dataset is empty (2.47).
        CityId              int               NULL,
        DistrictId          int               NULL,
        StateId             int               NULL,
        Pincode             varchar(10)       NULL,

        ContactEmail        nvarchar(150)     NULL,
        ContactMobile       varchar(15)       NULL,

        Is_Active           tinyint           NOT NULL CONSTRAINT DF_t_app_school_branches_Is_Active  DEFAULT (1),
        Is_Deleted          tinyint           NOT NULL CONSTRAINT DF_t_app_school_branches_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2         NOT NULL CONSTRAINT DF_t_app_school_branches_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint            NULL,
        ModifiedOn          datetime2         NULL,
        ModifiedBy          bigint            NULL,
        RowVersion          int               NOT NULL CONSTRAINT DF_t_app_school_branches_RowVersion DEFAULT (1),

        CONSTRAINT PK_t_app_school_branches PRIMARY KEY CLUSTERED (BranchId),
        CONSTRAINT FK_t_app_school_branches_t_app_schools
            FOREIGN KEY (SchoolId) REFERENCES dbo.t_app_schools (SchoolId),
        CONSTRAINT CK_t_app_school_branches_IsHeadOffice CHECK (IsHeadOffice IN (0, 1)),
        CONSTRAINT CK_t_app_school_branches_Is_Active    CHECK (Is_Active    IN (0, 1)),
        CONSTRAINT CK_t_app_school_branches_Is_Deleted   CHECK (Is_Deleted   IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_school_branches] already exists — skipped.';
END
GO
/*------------------------------------------------------------------------------
  The public identifier. Unfiltered — a Uid must never be reused, even after a
  soft delete, or an old URL resolves to a different branch.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_school_branches_BranchUid' AND object_id = OBJECT_ID('dbo.t_app_school_branches'))
BEGIN
    PRINT '    Creating index [UQ_t_app_school_branches_BranchUid] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_school_branches_BranchUid
        ON dbo.t_app_school_branches (BranchUid);
END
GO
/*------------------------------------------------------------------------------
  🔴 ONE HEAD OFFICE PER SCHOOL — the guard that makes provisioning safe to
  repeat.

  Provisioning already keys on SourceRequestUid, so a retry finds the existing
  school and stops before inserting anything. This index is the second line:
  if the branch insert ever ran twice for one school — a concurrent retry, a
  future caller that forgot the guard — the database refuses rather than
  quietly producing two head offices for one address.

  Filtered on IsHeadOffice = 1 so ordinary branches are unconstrained, and on
  Is_Deleted = 0 so a school that deletes a campus can name a new head office.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_school_branches_OneHeadOffice' AND object_id = OBJECT_ID('dbo.t_app_school_branches'))
BEGIN
    PRINT '    Creating index [UQ_t_app_school_branches_OneHeadOffice] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_school_branches_OneHeadOffice
        ON dbo.t_app_school_branches (SchoolId)
        WHERE IsHeadOffice = 1 AND Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  Every branch of one school — the list a dashboard opens with.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_school_branches_SchoolId' AND object_id = OBJECT_ID('dbo.t_app_school_branches'))
BEGIN
    PRINT '    Creating index [IX_t_app_school_branches_SchoolId] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_school_branches_SchoolId
        ON dbo.t_app_school_branches (SchoolId, Is_Deleted)
        INCLUDE (BranchName, IsHeadOffice, CityId, StateId);
END
GO
