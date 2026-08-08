/*==============================================================================
  jp_mdm — 003_m_mdm_district.sql

  Geography master. Cut from _TEMPLATE_table.sql Block A.

  IDs are seeded explicitly and referenced by enums in JP.Core, so they are
  contract — never renumber a row once seeded.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

-- Filtered indexes REQUIRE these, both to CREATE them and for any later
-- INSERT/UPDATE on the table. sqlcmd defaults QUOTED_IDENTIFIER OFF while SSMS
-- defaults it ON, which is how a script works in SSMS and fails from the
-- command line with Msg 1934 (decision 2.29).
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_mdm_district' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_mdm_district] ...';

    CREATE TABLE dbo.m_mdm_district
    (
        DistrictId          int               NOT NULL,   -- masters: no IDENTITY, IDs are contract
        Code                varchar(30)       NOT NULL,
        Name                nvarchar(150)     NOT NULL,
        DisplayOrder        int               NOT NULL CONSTRAINT DF_m_mdm_district_DisplayOrder DEFAULT (0),

        -- ---- table-specific columns ------------------------------------------
        StateId             int               NOT NULL,

        -- ---- standard columns (decision 2.4 — no exceptions) -----------------
        Is_Active           tinyint           NOT NULL CONSTRAINT DF_m_mdm_district_Is_Active  DEFAULT (1),
        Is_Deleted          tinyint           NOT NULL CONSTRAINT DF_m_mdm_district_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2         NOT NULL CONSTRAINT DF_m_mdm_district_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint            NULL,
        ModifiedOn          datetime2         NULL,
        ModifiedBy          bigint            NULL,

        CONSTRAINT PK_m_mdm_district PRIMARY KEY CLUSTERED (DistrictId),
        CONSTRAINT FK_m_mdm_district_m_mdm_state
            FOREIGN KEY (StateId) REFERENCES dbo.m_mdm_state (StateId),
        CONSTRAINT CK_m_mdm_district_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_m_mdm_district_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [m_mdm_district] already exists — skipped.';
END
GO

/*------------------------------------------------------------------------------
  Business key.

  -- Code is the stable lookup key used by seed scripts and procedures.

  🔴 Guarded SEPARATELY from the table (decision 2.29). In Phase 1A a table was
  created, its index failed, and on re-run the table-exists guard skipped the
  whole block — leaving the table permanently unindexed.

  Filtered WHERE Is_Deleted = 0 so a soft-deleted row frees its Code for reuse
  (decision 2.24).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_m_mdm_district_Code' AND object_id = OBJECT_ID('dbo.m_mdm_district'))
BEGIN
    PRINT '    Creating index [UQ_m_mdm_district_Code] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_m_mdm_district_Code
        ON dbo.m_mdm_district (Code)
        WHERE Is_Deleted = 0;
END
GO
