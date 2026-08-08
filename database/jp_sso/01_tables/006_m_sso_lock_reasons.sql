/*==============================================================================
  jp_sso — 006_m_sso_lock_reasons.sql

  Master: why an account was locked.

  IsAutoUnlock separates the two kinds. A FailedAttempts lock clears itself at
  UnlockOn; an AdminSuspend does not and needs a human to lift it. The
  distinction is data rather than a hardcoded id check in the login procedure.

  Mirrored by JP.Core.Enums.LockReason.
==============================================================================*/

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_sso_lock_reasons' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_sso_lock_reasons] ...';

    CREATE TABLE dbo.m_sso_lock_reasons
    (
        LockReasonId    int             NOT NULL,
        Code            varchar(30)     NOT NULL,
        Name            nvarchar(150)   NOT NULL,

        -- 1 = lock expires on its own at UnlockOn; 0 = an admin must lift it.
        IsAutoUnlock    bit             NOT NULL CONSTRAINT DF_m_sso_lock_reasons_IsAutoUnlock DEFAULT (0),

        DisplayOrder    int             NOT NULL CONSTRAINT DF_m_sso_lock_reasons_DisplayOrder DEFAULT (0),

        Is_Active       tinyint         NOT NULL CONSTRAINT DF_m_sso_lock_reasons_Is_Active  DEFAULT (1),
        Is_Deleted      tinyint         NOT NULL CONSTRAINT DF_m_sso_lock_reasons_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2       NOT NULL CONSTRAINT DF_m_sso_lock_reasons_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint          NULL,
        ModifiedOn      datetime2       NULL,
        ModifiedBy      bigint          NULL,

        CONSTRAINT PK_m_sso_lock_reasons PRIMARY KEY CLUSTERED (LockReasonId),
        CONSTRAINT CK_m_sso_lock_reasons_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_m_sso_lock_reasons_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );

END
ELSE
BEGIN
    PRINT '    Table [m_sso_lock_reasons] already exists - skipped.';
END
GO

-- Guarded separately from the table above. If the table is created but this
-- index fails, re-running the script repairs it. A single guard wrapping both
-- would skip the whole block and leave the table permanently un-indexed.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_m_sso_lock_reasons_Code' AND object_id = OBJECT_ID('dbo.m_sso_lock_reasons'))
BEGIN
    PRINT '    Creating index [UQ_m_sso_lock_reasons_Code] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_m_sso_lock_reasons_Code
        ON dbo.m_sso_lock_reasons (Code)
        WHERE Is_Deleted = 0;
END
GO