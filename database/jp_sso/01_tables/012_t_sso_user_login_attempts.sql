/*==============================================================================
  jp_sso — 012_t_sso_user_login_attempts.sql

  Audit of every sign-in attempt, successful or not.

  UserId is NULLABLE on purpose: an attempt against an address that does not
  exist still has to be recorded, and there is no user to attach it to. That is
  precisely the row you need when investigating credential stuffing.

  LoginIdentifier stores what was actually typed. It is the only way to see
  that someone is walking an address list.

  Standard columns apply here in full — logs are not exempt (PROJECT_MEMORY 7).
==============================================================================*/

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_sso_user_login_attempts' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_sso_user_login_attempts] ...';

    CREATE TABLE dbo.t_sso_user_login_attempts
    (
        AttemptId       bigint          IDENTITY(1,1) NOT NULL,

        -- NULL when the identifier matched no account.
        UserId          bigint          NULL,

        -- The email or mobile as supplied.
        LoginIdentifier nvarchar(150)   NOT NULL,

        IpAddress       varchar(45)     NULL,
        UserAgent       nvarchar(400)   NULL,

        IsSuccess       bit             NOT NULL,

        -- Short code, e.g. INVALID_PASSWORD, NO_SUCH_USER, ACCOUNT_LOCKED.
        -- Recorded here for forensics; the API always answers the caller with
        -- the same generic message, so this never reaches the client.
        FailureReason   varchar(50)     NULL,

        AttemptedOn     datetime2       NOT NULL
            CONSTRAINT DF_t_sso_user_login_attempts_AttemptedOn DEFAULT (SYSUTCDATETIME()),

        Is_Active       tinyint         NOT NULL
            CONSTRAINT DF_t_sso_user_login_attempts_Is_Active DEFAULT (1),
        Is_Deleted      tinyint         NOT NULL
            CONSTRAINT DF_t_sso_user_login_attempts_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2       NOT NULL
            CONSTRAINT DF_t_sso_user_login_attempts_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint          NULL,
        ModifiedOn      datetime2       NULL,
        ModifiedBy      bigint          NULL,

        CONSTRAINT PK_t_sso_user_login_attempts PRIMARY KEY CLUSTERED (AttemptId),

        CONSTRAINT FK_t_sso_user_login_attempts_t_sso_users
            FOREIGN KEY (UserId) REFERENCES dbo.t_sso_users (UserId),

        CONSTRAINT CK_t_sso_user_login_attempts_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_sso_user_login_attempts_Is_Deleted CHECK (Is_Deleted IN (0, 1)),

        -- A successful attempt has no failure reason.
        CONSTRAINT CK_t_sso_user_login_attempts_FailureReason
            CHECK (IsSuccess = 0 OR FailureReason IS NULL)
    );
END
ELSE
BEGIN
    PRINT '    Table [t_sso_user_login_attempts] already exists — skipped.';
END
GO
