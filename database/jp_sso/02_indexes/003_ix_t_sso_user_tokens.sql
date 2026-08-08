/*==============================================================================
  jp_sso — 002_indexes / 003_ix_t_sso_user_tokens.sql

  The unique index on TokenHash — the lookup path for every token validation —
  is in the table script.
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
  "Revoke every refresh token for this user" — logout-everywhere, and the
  response to a detected replay.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_tokens_UserId_TokenTypeId' AND object_id = OBJECT_ID('dbo.t_sso_user_tokens'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_tokens_UserId_TokenTypeId] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_tokens_UserId_TokenTypeId
        ON dbo.t_sso_user_tokens (UserId, TokenTypeId)
        INCLUDE (ExpiresOn, UsedOn, RevokedOn, ReplacedByTokenId)
        WHERE Is_Deleted = 0;
END
GO

/*------------------------------------------------------------------------------
  Housekeeping: purge expired tokens.

  Filtered to live tokens only, which keeps the index small — the vast majority
  of rows in this table will eventually be used or revoked, and the cleanup job
  has no interest in those.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_tokens_ExpiresOn' AND object_id = OBJECT_ID('dbo.t_sso_user_tokens'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_tokens_ExpiresOn] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_tokens_ExpiresOn
        ON dbo.t_sso_user_tokens (ExpiresOn)
        WHERE Is_Deleted = 0 AND UsedOn IS NULL AND RevokedOn IS NULL;
END
GO

-- FK support.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_tokens_TokenTypeId' AND object_id = OBJECT_ID('dbo.t_sso_user_tokens'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_tokens_TokenTypeId] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_tokens_TokenTypeId
        ON dbo.t_sso_user_tokens (TokenTypeId);
END
GO

-- Walks the rotation chain forwards, and supports the self-referencing FK.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_tokens_ReplacedByTokenId' AND object_id = OBJECT_ID('dbo.t_sso_user_tokens'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_tokens_ReplacedByTokenId] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_tokens_ReplacedByTokenId
        ON dbo.t_sso_user_tokens (ReplacedByTokenId)
        WHERE ReplacedByTokenId IS NOT NULL;
END
GO
