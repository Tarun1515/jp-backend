/*==============================================================================
  jp_sso — 009_t_sso_user_credentials.sql

  Password history. One row per password a user has ever had; exactly one of
  them is current.

  ---------------------------------------------------------------------------
  Why history rather than a column on t_sso_users
  ---------------------------------------------------------------------------
  Two reasons. Password reuse is blocked against the last 3 (PROJECT_MEMORY
  2.6), which needs the old hashes kept. And the algorithm id and iteration
  count are stored PER ROW, not globally, so the work factor can be raised
  later without invalidating a single existing password — verification uses
  whatever cost that row was written with.

  ---------------------------------------------------------------------------
  Column widths are contract
  ---------------------------------------------------------------------------
  PasswordHash varbinary(64) and PasswordSalt varbinary(32) match
  AppConstants.Password.HashBytes / SaltBytes exactly. PBKDF2-HMAC-SHA256
  derives 64 bytes from a 32-byte salt. Changing either width means changing
  both sides.

  Never store a password as a string. varbinary avoids any collation,
  encoding or trailing-space behaviour touching the bytes.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_sso_user_credentials' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_sso_user_credentials] ...';

    CREATE TABLE dbo.t_sso_user_credentials
    (
        CredentialId        bigint          IDENTITY(1,1) NOT NULL,
        UserId              bigint          NOT NULL,

        -- Exactly 64 bytes. Fixed width, so varbinary never pads or truncates.
        PasswordHash        varbinary(64)   NOT NULL,

        -- Exactly 32 bytes, cryptographically random, unique per password.
        -- Stored separately from the hash rather than concatenated, so neither
        -- can be misread as part of the other.
        PasswordSalt        varbinary(32)   NOT NULL,

        HashAlgorithmId     int             NOT NULL,

        -- The cost THIS hash was computed with. Verification reads this value,
        -- never the current application default.
        Iterations          int             NOT NULL,

        -- Exactly one row per user may have this set — enforced by the filtered
        -- unique index below, not by procedure discipline.
        IsCurrent           bit             NOT NULL
            CONSTRAINT DF_t_sso_user_credentials_IsCurrent DEFAULT (1),

        -- Optional forced-rotation deadline. An INSTANT, so datetime2 UTC —
        -- it is a duration from creation, not a calendar date (decision 2.28).
        ExpiresOn           datetime2       NULL,

        -- ---- standard columns ------------------------------------------------
        Is_Active           tinyint         NOT NULL
            CONSTRAINT DF_t_sso_user_credentials_Is_Active DEFAULT (1),
        Is_Deleted          tinyint         NOT NULL
            CONSTRAINT DF_t_sso_user_credentials_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2       NOT NULL
            CONSTRAINT DF_t_sso_user_credentials_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint          NULL,
        ModifiedOn          datetime2       NULL,
        ModifiedBy          bigint          NULL,

        CONSTRAINT PK_t_sso_user_credentials PRIMARY KEY CLUSTERED (CredentialId),

        CONSTRAINT FK_t_sso_user_credentials_t_sso_users
            FOREIGN KEY (UserId) REFERENCES dbo.t_sso_users (UserId),
        CONSTRAINT FK_t_sso_user_credentials_m_sso_hash_algorithms
            FOREIGN KEY (HashAlgorithmId) REFERENCES dbo.m_sso_hash_algorithms (HashAlgorithmId),

        CONSTRAINT CK_t_sso_user_credentials_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_sso_user_credentials_Is_Deleted CHECK (Is_Deleted IN (0, 1)),

        -- A zero or negative iteration count would mean the KDF never ran.
        CONSTRAINT CK_t_sso_user_credentials_Iterations CHECK (Iterations > 0),

        -- Guards against a truncated or misconstructed write. DATALENGTH on
        -- varbinary is the byte count, which is exactly what matters here.
        CONSTRAINT CK_t_sso_user_credentials_HashLength CHECK (DATALENGTH(PasswordHash) = 64),
        CONSTRAINT CK_t_sso_user_credentials_SaltLength CHECK (DATALENGTH(PasswordSalt) = 32)
    );

END
ELSE
BEGIN
    PRINT '    Table [t_sso_user_credentials] already exists — skipped.';
END
GO

/*==============================================================================
  "Exactly one current credential per user" — a DATABASE guarantee.

  This is the important index in the table. USP_ChangePassword sets the old
  row's IsCurrent to 0 and inserts the new one; if that ever runs out of order,
  races with itself, or is written wrongly, this index refuses the second
  current row outright.

  Without it, a user with two IsCurrent = 1 rows would still log in — the login
  proc would just pick whichever row came back first, which is not
  deterministic. That is the kind of fault that never reproduces.

  NOT filtered on Is_Deleted: a soft-deleted credential must also have
  IsCurrent = 0, so keeping the filter narrow makes the guarantee stronger.

  Guarded independently of the table, so a partial run can be repaired by
  re-running this script.
==============================================================================*/

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_sso_user_credentials_UserId_Current'
                 AND object_id = OBJECT_ID('dbo.t_sso_user_credentials'))
BEGIN
    PRINT '    Creating index [UQ_t_sso_user_credentials_UserId_Current] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_sso_user_credentials_UserId_Current
        ON dbo.t_sso_user_credentials (UserId)
        WHERE IsCurrent = 1;
END
GO
