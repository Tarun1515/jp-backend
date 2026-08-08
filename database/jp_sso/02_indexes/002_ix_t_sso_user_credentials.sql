/*==============================================================================
  jp_sso — 002_indexes / 002_ix_t_sso_user_credentials.sql

  The "current credential" unique index lives in the table script — it is a
  guarantee, not a tuning decision.
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
  Password-reuse check: USP_ChangePassword reads the user's last 3 credentials
  and compares the new password against each.

  CreatedOn DESC so the TOP 3 comes off the front of the index rather than
  needing a sort. The INCLUDE carries everything the comparison needs, so the
  check never touches the base table.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_credentials_UserId_CreatedOn' AND object_id = OBJECT_ID('dbo.t_sso_user_credentials'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_credentials_UserId_CreatedOn] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_credentials_UserId_CreatedOn
        ON dbo.t_sso_user_credentials (UserId, CreatedOn DESC)
        INCLUDE (PasswordHash, PasswordSalt, HashAlgorithmId, Iterations, IsCurrent)
        WHERE Is_Deleted = 0;
END
GO

-- FK support.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_credentials_HashAlgorithmId' AND object_id = OBJECT_ID('dbo.t_sso_user_credentials'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_credentials_HashAlgorithmId] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_credentials_HashAlgorithmId
        ON dbo.t_sso_user_credentials (HashAlgorithmId);
END
GO
