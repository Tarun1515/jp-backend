/*==============================================================================
  jp_mdm — 024_t_mdm_request_levels.sql

  Approval level configuration — who approves what, at which step.

  MVP seeds ONE level per request type, but the engine stays multi-level. Phase 6
  may add a two-level offer approval, and retrofitting levels into a
  single-level implementation is worse than carrying the column now.

  OrganizationUid NULL = the platform-wide default for this request type. A row
  with an OrganizationUid overrides it for that one organisation.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

-- Filtered indexes REQUIRE these, both to CREATE them and for any later
-- INSERT/UPDATE on the table (decision 2.29).
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_mdm_request_levels' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_mdm_request_levels] ...';

    CREATE TABLE dbo.t_mdm_request_levels
    (
        -- int, not bigint: this is configuration — a handful of rows per
        -- request type — not transactional volume. Nothing references it.
        LevelId             int               IDENTITY(1,1) NOT NULL,

        RequestTypeId       int               NOT NULL,
        LevelNumber         tinyint           NOT NULL,
        IsFinalLevel        tinyint           NOT NULL CONSTRAINT DF_t_mdm_request_levels_IsFinalLevel DEFAULT (0),

        /*
          ⚠️ CROSS-DATABASE REFERENCE — jp_sso. There is NO foreign key here and
          there must never be one (decision 2.2). SQL Server cannot enforce a FK
          across databases, and adding one is not a "fix" — it will not compile.
          The value is validated in the stored procedure and in the API.
        */
        -- t_sso_roles.RoleId is **int** — verified against the live column, not
        -- assumed from the spec. Phase 1's menu work (2.37) was bitten by
        -- exactly this: UserTypeId and PermissionId turned out to be int rather
        -- than the tinyint/bigint the spec implied.
        RoleId              int               NOT NULL,

        -- NULL = platform default. Set = override for one organisation.
        OrganizationUid     uniqueidentifier  NULL,

        Is_Active           tinyint           NOT NULL CONSTRAINT DF_t_mdm_request_levels_Is_Active  DEFAULT (1),
        Is_Deleted          tinyint           NOT NULL CONSTRAINT DF_t_mdm_request_levels_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2         NOT NULL CONSTRAINT DF_t_mdm_request_levels_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint            NULL,
        ModifiedOn          datetime2         NULL,
        ModifiedBy          bigint            NULL,

        CONSTRAINT PK_t_mdm_request_levels PRIMARY KEY CLUSTERED (LevelId),
        CONSTRAINT FK_t_mdm_request_levels_m_mdm_request_types
            FOREIGN KEY (RequestTypeId) REFERENCES dbo.m_mdm_request_types (RequestTypeId),
        CONSTRAINT CK_t_mdm_request_levels_IsFinalLevel CHECK (IsFinalLevel IN (0, 1)),
        CONSTRAINT CK_t_mdm_request_levels_LevelNumber  CHECK (LevelNumber >= 1),
        CONSTRAINT CK_t_mdm_request_levels_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_mdm_request_levels_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_mdm_request_levels] already exists — skipped.';
END
GO
/*------------------------------------------------------------------------------
  One row per (request type, level, organisation).

  Without this a second row for the same level is possible, and the engine would
  pick one arbitrarily — an approval routed to whichever role happened to sort
  first.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_mdm_request_levels_Type_Level_Org' AND object_id = OBJECT_ID('dbo.t_mdm_request_levels'))
BEGIN
    PRINT '    Creating index [UQ_t_mdm_request_levels_Type_Level_Org] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_mdm_request_levels_Type_Level_Org
        ON dbo.t_mdm_request_levels (RequestTypeId, LevelNumber, OrganizationUid)
        WHERE Is_Deleted = 0;
END
GO
