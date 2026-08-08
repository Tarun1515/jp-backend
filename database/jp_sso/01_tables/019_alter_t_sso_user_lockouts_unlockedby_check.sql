/*==============================================================================
  jp_sso — 019_alter_t_sso_user_lockouts_unlockedby_check.sql

  Relaxes CK_t_sso_user_lockouts_UnlockedBy.

  ---------------------------------------------------------------------------
  WHY (found by the Phase 1B test suite)
  ---------------------------------------------------------------------------
  The original constraint required UnlockedByUserId and UnlockedOn to be BOTH
  set or BOTH null:

      CHECK ((UnlockedByUserId IS NULL     AND UnlockedOn IS NULL)
          OR (UnlockedByUserId IS NOT NULL AND UnlockedOn IS NOT NULL))

  That was written with only the manual case in mind — an admin lifts a lock,
  so record who and when. But there are TWO ways a lock ends:

      manual     an administrator lifts it     -> who = that admin
      automatic  it simply lapses at UnlockOn  -> who = nobody

  USP_RecordLoginAttempt closes lapsed lockouts on the next successful sign-in
  and has no person to attribute that to, so it set UnlockedOn alone — and the
  constraint rejected it. The whole login then rolled back.

  Inventing an unlocker to satisfy the constraint would put a lie in the audit
  trail. The constraint is what was wrong, so it is narrowed to the rule that
  actually holds:

      an unlocker implies a time; a time does not imply an unlocker

  Resulting states:
      both NULL                        still locked
      UnlockedOn set, ByUserId NULL    expired automatically
      both set                         lifted by that administrator
      ByUserId set, UnlockedOn NULL    nonsense — still rejected

  Follows Block D of _TEMPLATE_table.sql: deployed tables are never edited in
  place; corrections ship as a new guarded script.
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_t_sso_user_lockouts_UnlockedBy')
BEGIN
    PRINT '    Dropping old [CK_t_sso_user_lockouts_UnlockedBy] ...';

    ALTER TABLE dbo.t_sso_user_lockouts
        DROP CONSTRAINT CK_t_sso_user_lockouts_UnlockedBy;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints WHERE name = 'CK_t_sso_user_lockouts_UnlockedBy_V1')
BEGIN
    PRINT '    Adding [CK_t_sso_user_lockouts_UnlockedBy_V1] ...';

    -- An unlocker implies a time. A time does not imply an unlocker: a lock
    -- that simply expired has no person attached to it.
    ALTER TABLE dbo.t_sso_user_lockouts
        ADD CONSTRAINT CK_t_sso_user_lockouts_UnlockedBy_V1
            CHECK (UnlockedByUserId IS NULL OR UnlockedOn IS NOT NULL);
END
GO
