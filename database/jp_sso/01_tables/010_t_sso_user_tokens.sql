/*==============================================================================
  jp_sso — 010_t_sso_user_tokens.sql

  Opaque tokens: refresh, password reset, email verification, invite.

  TokenHash holds a SHA-256 hex digest (64 chars), never the token itself. A
  leaked backup of this table hands over nothing usable. Lookup is BY hash —
  the procedure hashes the incoming token and matches on that.

  ReplacedByTokenId forms the refresh rotation chain: each use revokes the old
  token and points it at its successor, so a stolen refresh token that is
  replayed after the real user has refreshed can be detected and the whole
  chain revoked.

  All temporal columns are INSTANTS (datetime2 UTC) — expiry here is a duration
  from issue, not a calendar date (decision 2.28).
==============================================================================*/

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_sso_user_tokens' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_sso_user_tokens] ...';

    CREATE TABLE dbo.t_sso_user_tokens
    (
        TokenId             bigint          IDENTITY(1,1) NOT NULL,
        UserId              bigint          NOT NULL,
        TokenTypeId         int             NOT NULL,

        -- SHA-256 as lowercase hex = 64 characters. varchar(128) leaves room
        -- for a longer digest later without a schema change.
        TokenHash           varchar(128)    NOT NULL,

        ExpiresOn           datetime2       NOT NULL,
        UsedOn              datetime2       NULL,
        RevokedOn           datetime2       NULL,

        -- Rotation chain. Self-referencing.
        ReplacedByTokenId   bigint          NULL,

        -- varchar(45) holds a full IPv6 address.
        IpAddress           varchar(45)     NULL,
        UserAgent           nvarchar(400)   NULL,

        Is_Active           tinyint         NOT NULL
            CONSTRAINT DF_t_sso_user_tokens_Is_Active DEFAULT (1),
        Is_Deleted          tinyint         NOT NULL
            CONSTRAINT DF_t_sso_user_tokens_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2       NOT NULL
            CONSTRAINT DF_t_sso_user_tokens_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint          NULL,
        ModifiedOn          datetime2       NULL,
        ModifiedBy          bigint          NULL,

        CONSTRAINT PK_t_sso_user_tokens PRIMARY KEY CLUSTERED (TokenId),

        CONSTRAINT FK_t_sso_user_tokens_t_sso_users
            FOREIGN KEY (UserId) REFERENCES dbo.t_sso_users (UserId),
        CONSTRAINT FK_t_sso_user_tokens_m_sso_token_types
            FOREIGN KEY (TokenTypeId) REFERENCES dbo.m_sso_token_types (TokenTypeId),
        CONSTRAINT FK_t_sso_user_tokens_t_sso_user_tokens_ReplacedBy
            FOREIGN KEY (ReplacedByTokenId) REFERENCES dbo.t_sso_user_tokens (TokenId),

        CONSTRAINT CK_t_sso_user_tokens_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_sso_user_tokens_Is_Deleted CHECK (Is_Deleted IN (0, 1)),

        -- A token cannot point at itself as its own replacement.
        CONSTRAINT CK_t_sso_user_tokens_NoSelfReplace
            CHECK (ReplacedByTokenId IS NULL OR ReplacedByTokenId <> TokenId)
    );

END
ELSE
BEGIN
    PRINT '    Table [t_sso_user_tokens] already exists — skipped.';
END
GO

-- A hash must identify one token. Unfiltered: a collision would be a security
-- problem regardless of whether one of the rows is soft-deleted.
-- Guarded independently of the table so a partial run can be repaired.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_sso_user_tokens_TokenHash' AND object_id = OBJECT_ID('dbo.t_sso_user_tokens'))
BEGIN
    PRINT '    Creating index [UQ_t_sso_user_tokens_TokenHash] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_sso_user_tokens_TokenHash
        ON dbo.t_sso_user_tokens (TokenHash);
END
GO
