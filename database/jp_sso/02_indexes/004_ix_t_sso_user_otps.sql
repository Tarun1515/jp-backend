/*==============================================================================
  jp_sso — 002_indexes / 004_ix_t_sso_user_otps.sql
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
  USP_VerifyOtp: the latest unverified OTP for a user on a given channel.
  CreatedOn DESC puts the newest first, so there is no sort.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_otps_UserId_OtpChannelId' AND object_id = OBJECT_ID('dbo.t_sso_user_otps'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_otps_UserId_OtpChannelId] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_otps_UserId_OtpChannelId
        ON dbo.t_sso_user_otps (UserId, OtpChannelId, CreatedOn DESC)
        INCLUDE (OtpHash, ExpiresOn, AttemptCount, IsVerified)
        WHERE Is_Deleted = 0;
END
GO

-- Housekeeping: purge expired, unverified codes.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_otps_ExpiresOn' AND object_id = OBJECT_ID('dbo.t_sso_user_otps'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_otps_ExpiresOn] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_otps_ExpiresOn
        ON dbo.t_sso_user_otps (ExpiresOn)
        WHERE Is_Deleted = 0 AND IsVerified = 0;
END
GO

-- FK support.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_otps_OtpChannelId' AND object_id = OBJECT_ID('dbo.t_sso_user_otps'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_otps_OtpChannelId] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_otps_OtpChannelId
        ON dbo.t_sso_user_otps (OtpChannelId);
END
GO
