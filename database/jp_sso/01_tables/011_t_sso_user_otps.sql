/*==============================================================================
  jp_sso — 011_t_sso_user_otps.sql

  One-time passwords for email and mobile verification.

  Stored hashed, like every other token. A 6-digit OTP has only a million
  possible values, so the hash is not much of a barrier on its own — the real
  protections are the short expiry, the AttemptCount cap of 5, and the rate
  limit on the send endpoint. The hash is there so a database leak does not
  hand over live codes.

  ExpiresOn is an INSTANT (10 minutes from issue), so datetime2 UTC — not a
  calendar date (decision 2.28).
==============================================================================*/

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_sso_user_otps' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_sso_user_otps] ...';

    CREATE TABLE dbo.t_sso_user_otps
    (
        OtpId           bigint          IDENTITY(1,1) NOT NULL,
        UserId          bigint          NOT NULL,
        OtpChannelId    int             NOT NULL,

        OtpHash         varchar(128)    NOT NULL,

        -- The address or number it was sent to, captured at send time. Kept
        -- because the user may change their email before verifying.
        SentTo          nvarchar(150)   NOT NULL,

        ExpiresOn       datetime2       NOT NULL,

        -- Capped at 5 by USP_VerifyOtp. Stops a 6-digit code being brute
        -- forced within its validity window.
        AttemptCount    int             NOT NULL
            CONSTRAINT DF_t_sso_user_otps_AttemptCount DEFAULT (0),

        IsVerified      bit             NOT NULL
            CONSTRAINT DF_t_sso_user_otps_IsVerified DEFAULT (0),
        VerifiedOn      datetime2       NULL,

        Is_Active       tinyint         NOT NULL
            CONSTRAINT DF_t_sso_user_otps_Is_Active DEFAULT (1),
        Is_Deleted      tinyint         NOT NULL
            CONSTRAINT DF_t_sso_user_otps_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2       NOT NULL
            CONSTRAINT DF_t_sso_user_otps_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint          NULL,
        ModifiedOn      datetime2       NULL,
        ModifiedBy      bigint          NULL,

        CONSTRAINT PK_t_sso_user_otps PRIMARY KEY CLUSTERED (OtpId),

        CONSTRAINT FK_t_sso_user_otps_t_sso_users
            FOREIGN KEY (UserId) REFERENCES dbo.t_sso_users (UserId),
        CONSTRAINT FK_t_sso_user_otps_m_sso_otp_channels
            FOREIGN KEY (OtpChannelId) REFERENCES dbo.m_sso_otp_channels (OtpChannelId),

        CONSTRAINT CK_t_sso_user_otps_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_sso_user_otps_Is_Deleted CHECK (Is_Deleted IN (0, 1)),
        CONSTRAINT CK_t_sso_user_otps_AttemptCount CHECK (AttemptCount >= 0),

        -- A verified OTP must record when. Keeps the two fields from drifting.
        CONSTRAINT CK_t_sso_user_otps_VerifiedOn
            CHECK ((IsVerified = 0 AND VerifiedOn IS NULL) OR (IsVerified = 1 AND VerifiedOn IS NOT NULL))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_sso_user_otps] already exists — skipped.';
END
GO
