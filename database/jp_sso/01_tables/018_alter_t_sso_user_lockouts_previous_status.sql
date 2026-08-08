/*==============================================================================
  jp_sso — 018_alter_t_sso_user_lockouts_previous_status.sql

  Adds t_sso_user_lockouts.PreviousStatusId.

  ---------------------------------------------------------------------------
  WHY (found while writing Phase 1B)
  ---------------------------------------------------------------------------
  Locking an account sets t_sso_users.StatusId = 5 (Locked). That OVERWRITES
  whatever the status was, and there is nowhere else recording it.

  Consider a school sitting at StatusId = 1 (PendingApproval) that fails five
  sign-ins. It is locked, StatusId becomes 5, and thirty minutes later the
  unlock path has to decide what to restore. With nothing recorded, the only
  available answer is "Active" — and the school walks straight through the
  approval gate it was supposed to be waiting behind.

  The same applies to a Suspended (4) or Rejected (3) account: a lockout would
  quietly launder it into an active one.

  So the lockout row remembers what to put back.

  Follows Block D of database/_TEMPLATE_table.sql: deployed tables are never
  edited in place, they get a new guarded ALTER script.
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.t_sso_user_lockouts') AND name = 'PreviousStatusId')
BEGIN
    PRINT '    Adding column [t_sso_user_lockouts].[PreviousStatusId] ...';

    -- Nullable: an admin suspension does not necessarily go through the
    -- lock/restore cycle, and rows written before this column existed have
    -- nothing to record.
    ALTER TABLE dbo.t_sso_user_lockouts
        ADD PreviousStatusId int NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
               WHERE name = 'FK_t_sso_user_lockouts_m_sso_user_status_Previous')
BEGIN
    PRINT '    Adding FK [FK_t_sso_user_lockouts_m_sso_user_status_Previous] ...';

    ALTER TABLE dbo.t_sso_user_lockouts
        ADD CONSTRAINT FK_t_sso_user_lockouts_m_sso_user_status_Previous
            FOREIGN KEY (PreviousStatusId) REFERENCES dbo.m_sso_user_status (StatusId);
END
GO

-- A lock must never record "Locked" as the state to return to, or unlocking
-- would be a no-op and the account would stay locked forever.
IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = 'CK_t_sso_user_lockouts_PreviousStatusId')
BEGIN
    PRINT '    Adding CHECK [CK_t_sso_user_lockouts_PreviousStatusId] ...';

    ALTER TABLE dbo.t_sso_user_lockouts
        ADD CONSTRAINT CK_t_sso_user_lockouts_PreviousStatusId
            CHECK (PreviousStatusId IS NULL OR PreviousStatusId <> 5);
END
GO
