/*==============================================================================
  jp_sso — 013_t_sso_user_lockouts.sql

  Account lockouts. One row per lock event — history is kept rather than a flag
  on t_sso_users, so a repeatedly locked account is visible as a pattern.

  LockedOn / UnlockOn / RevokedOn are INSTANTS (datetime2 UTC). A lockout is a
  30-minute duration, not a calendar day (decision 2.28).

  An automatic lock (LockReasonId 1, IsAutoUnlock = 1) simply expires at
  UnlockOn. An admin suspension (LockReasonId 2) has UnlockOn NULL and stays
  until someone lifts it.
==============================================================================*/

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_sso_user_lockouts' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_sso_user_lockouts] ...';

    CREATE TABLE dbo.t_sso_user_lockouts
    (
        LockoutId           bigint          IDENTITY(1,1) NOT NULL,
        UserId              bigint          NOT NULL,
        LockReasonId        int             NOT NULL,

        LockedOn            datetime2       NOT NULL
            CONSTRAINT DF_t_sso_user_lockouts_LockedOn DEFAULT (SYSUTCDATETIME()),

        -- NULL means indefinite — an admin suspension with no automatic end.
        UnlockOn            datetime2       NULL,

        -- Set when an admin lifts the lock early.
        UnlockedByUserId    bigint          NULL,
        UnlockedOn          datetime2       NULL,

        Remarks             nvarchar(500)   NULL,

        Is_Active           tinyint         NOT NULL
            CONSTRAINT DF_t_sso_user_lockouts_Is_Active DEFAULT (1),
        Is_Deleted          tinyint         NOT NULL
            CONSTRAINT DF_t_sso_user_lockouts_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2       NOT NULL
            CONSTRAINT DF_t_sso_user_lockouts_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint          NULL,
        ModifiedOn          datetime2       NULL,
        ModifiedBy          bigint          NULL,

        CONSTRAINT PK_t_sso_user_lockouts PRIMARY KEY CLUSTERED (LockoutId),

        CONSTRAINT FK_t_sso_user_lockouts_t_sso_users
            FOREIGN KEY (UserId) REFERENCES dbo.t_sso_users (UserId),
        CONSTRAINT FK_t_sso_user_lockouts_m_sso_lock_reasons
            FOREIGN KEY (LockReasonId) REFERENCES dbo.m_sso_lock_reasons (LockReasonId),
        CONSTRAINT FK_t_sso_user_lockouts_t_sso_users_UnlockedBy
            FOREIGN KEY (UnlockedByUserId) REFERENCES dbo.t_sso_users (UserId),

        CONSTRAINT CK_t_sso_user_lockouts_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_sso_user_lockouts_Is_Deleted CHECK (Is_Deleted IN (0, 1)),

        -- A lock cannot end before it began.
        CONSTRAINT CK_t_sso_user_lockouts_UnlockOn
            CHECK (UnlockOn IS NULL OR UnlockOn > LockedOn),

        -- Manual unlocks record both who and when, or neither.
        CONSTRAINT CK_t_sso_user_lockouts_UnlockedBy
            CHECK ((UnlockedByUserId IS NULL AND UnlockedOn IS NULL)
                OR (UnlockedByUserId IS NOT NULL AND UnlockedOn IS NOT NULL))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_sso_user_lockouts] already exists — skipped.';
END
GO
