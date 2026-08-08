/*==============================================================================
  jp_sso — 002_indexes / 005_ix_t_sso_user_login_attempts.sql

  This table grows fastest of anything in jp_sso — one row per sign-in attempt
  by anyone, forever. Its indexes matter more than most.
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
  Lockout evaluation: recent failures for one account.

  Read on every single failed login, so this is the hottest index here.
  AttemptedOn DESC means the "last N attempts" window is the leading edge.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_login_attempts_UserId_AttemptedOn' AND object_id = OBJECT_ID('dbo.t_sso_user_login_attempts'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_login_attempts_UserId_AttemptedOn] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_login_attempts_UserId_AttemptedOn
        ON dbo.t_sso_user_login_attempts (UserId, AttemptedOn DESC)
        INCLUDE (IsSuccess, FailureReason, IpAddress)
        WHERE UserId IS NOT NULL;
END
GO

/*------------------------------------------------------------------------------
  Attempts against an identifier that matched no account (UserId IS NULL).

  These are the rows that reveal an address list being walked, and they cannot
  be found through the index above precisely because they have no UserId.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_login_attempts_LoginIdentifier' AND object_id = OBJECT_ID('dbo.t_sso_user_login_attempts'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_login_attempts_LoginIdentifier] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_login_attempts_LoginIdentifier
        ON dbo.t_sso_user_login_attempts (LoginIdentifier, AttemptedOn DESC)
        INCLUDE (IsSuccess, IpAddress);
END
GO

/*------------------------------------------------------------------------------
  Per-IP analysis: one address attacking many accounts. The complement of the
  index above, which finds many addresses attacking one account.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_login_attempts_IpAddress_AttemptedOn' AND object_id = OBJECT_ID('dbo.t_sso_user_login_attempts'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_login_attempts_IpAddress_AttemptedOn] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_login_attempts_IpAddress_AttemptedOn
        ON dbo.t_sso_user_login_attempts (IpAddress, AttemptedOn DESC)
        INCLUDE (UserId, LoginIdentifier, IsSuccess)
        WHERE IpAddress IS NOT NULL;
END
GO

/*------------------------------------------------------------------------------
  Time-ordered access for reporting and for archiving old rows.

  Note the column is a UTC instant. An "attempts today" report must convert IST
  day boundaries to UTC first (dbo.fn_IstDateToUtc) and filter with a plain
  range — never CAST(AttemptedOn AS date), which would both give the wrong day
  and make this index useless. See decision 2.28.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_login_attempts_AttemptedOn' AND object_id = OBJECT_ID('dbo.t_sso_user_login_attempts'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_login_attempts_AttemptedOn] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_login_attempts_AttemptedOn
        ON dbo.t_sso_user_login_attempts (AttemptedOn DESC)
        INCLUDE (UserId, IsSuccess);
END
GO
