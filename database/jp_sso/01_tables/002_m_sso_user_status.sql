/*==============================================================================
  jp_sso — 002_m_sso_user_status.sql

  Master: account status.
  Only StatusId = 2 (Active) passes the API's [RequireActiveAccount] filter.
  A pending school still holds a valid token — see PROJECT_MEMORY 2.9.

  Mirrored by JP.Core.Enums.UserStatus. Never renumber.
==============================================================================*/

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_sso_user_status' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_sso_user_status] ...';

    CREATE TABLE dbo.m_sso_user_status
    (
        StatusId        int             NOT NULL,
        Code            varchar(30)     NOT NULL,
        Name            nvarchar(150)   NOT NULL,
        DisplayOrder    int             NOT NULL CONSTRAINT DF_m_sso_user_status_DisplayOrder DEFAULT (0),

        Is_Active       tinyint         NOT NULL CONSTRAINT DF_m_sso_user_status_Is_Active  DEFAULT (1),
        Is_Deleted      tinyint         NOT NULL CONSTRAINT DF_m_sso_user_status_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2       NOT NULL CONSTRAINT DF_m_sso_user_status_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint          NULL,
        ModifiedOn      datetime2       NULL,
        ModifiedBy      bigint          NULL,

        CONSTRAINT PK_m_sso_user_status PRIMARY KEY CLUSTERED (StatusId),
        CONSTRAINT CK_m_sso_user_status_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_m_sso_user_status_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );

END
ELSE
BEGIN
    PRINT '    Table [m_sso_user_status] already exists - skipped.';
END
GO

-- Guarded separately from the table above. If the table is created but this
-- index fails, re-running the script repairs it. A single guard wrapping both
-- would skip the whole block and leave the table permanently un-indexed.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_m_sso_user_status_Code' AND object_id = OBJECT_ID('dbo.m_sso_user_status'))
BEGIN
    PRINT '    Creating index [UQ_m_sso_user_status_Code] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_m_sso_user_status_Code
        ON dbo.m_sso_user_status (Code)
        WHERE Is_Deleted = 0;
END
GO