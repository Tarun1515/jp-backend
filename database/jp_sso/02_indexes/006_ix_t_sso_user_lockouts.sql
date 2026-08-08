/*==============================================================================
  jp_sso — 002_indexes / 006_ix_t_sso_user_lockouts.sql
==============================================================================*/

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*------------------------------------------------------------------------------
  "Is this account locked right now?" — read on every login attempt.

  Filtered to locks that have not been manually lifted. A lock whose UnlockOn
  has simply passed is still matched here; the procedure compares UnlockOn
  against SYSUTCDATETIME() rather than trying to encode "expired" in the index,
  because a filtered index predicate cannot reference a moving value.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_lockouts_UserId_UnlockOn' AND object_id = OBJECT_ID('dbo.t_sso_user_lockouts'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_lockouts_UserId_UnlockOn] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_lockouts_UserId_UnlockOn
        ON dbo.t_sso_user_lockouts (UserId, UnlockOn)
        INCLUDE (LockReasonId, LockedOn, Remarks)
        WHERE Is_Deleted = 0 AND UnlockedOn IS NULL;
END
GO

-- FK support.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_lockouts_LockReasonId' AND object_id = OBJECT_ID('dbo.t_sso_user_lockouts'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_lockouts_LockReasonId] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_lockouts_LockReasonId
        ON dbo.t_sso_user_lockouts (LockReasonId);
END
GO

-- FK support, and "which locks did this admin lift" for audit.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_lockouts_UnlockedByUserId' AND object_id = OBJECT_ID('dbo.t_sso_user_lockouts'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_lockouts_UnlockedByUserId] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_lockouts_UnlockedByUserId
        ON dbo.t_sso_user_lockouts (UnlockedByUserId)
        WHERE UnlockedByUserId IS NOT NULL;
END
GO
