/*==============================================================================
  jp_sso — 04_procedures / 010_admin_analytics.sql

  USP_GetIdentityAnalytics — the jp_sso half of the admin analytics screen.

  Registrations: how many accounts of each type, in which state, and how many
  arrived in the last thirty days.

  ----------------------------------------------------------------------------
  🔴 COUNTS ONLY. NO EMAIL, NO MOBILE, NO UID, NO NAME.
  ----------------------------------------------------------------------------
  An analytics screen is exactly where "while you are there, show me who"
  arrives, and this is identity data: the one database whose rows are people.
  Everything here is a GROUP BY with a COUNT, so the result set cannot carry an
  identity even by accident — and the build guard at the foot asserts that
  rather than trusting it.

  Who an account is belongs on the Accounts screen, behind USER.MANAGE, one
  account at a time. This is behind REPORT.VIEW, which is a different grant.

  ----------------------------------------------------------------------------
  ⚠️ THE WINDOW IS IST-RELATIVE (2.28)
  ----------------------------------------------------------------------------
  "Last 30 days" means thirty calendar days in India. The boundary is built
  from the IST date and then shifted back to UTC for the comparison, because
  CreatedOn is stored UTC.

  Re-runnable. Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE dbo.USP_GetIdentityAnalytics
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TodayIst date = CAST(DATEADD(MINUTE, 330, SYSUTCDATETIME()) AS date);
    DECLARE @From datetime2 = DATEADD(MINUTE, -330, CAST(DATEADD(day, -29, @TodayIst) AS datetime2));

    /*
      ⚠️ CROSS JOIN from the two masters so every (type, status) pair exists,
      including the zeroes. A grid with holes in it reads as a grid with
      different meaning — and "no suspended teachers" is a fact worth showing.
    */
    SELECT
        t.UserTypeId,
        t.Name AS UserTypeName,
        s.StatusId,
        s.Name AS StatusName,
        COUNT(u.UserId) AS Total,
        SUM(CASE WHEN u.CreatedOn >= @From THEN 1 ELSE 0 END) AS Last30Days
      FROM dbo.m_sso_user_types t
      CROSS JOIN dbo.m_sso_user_status s
      LEFT JOIN dbo.t_sso_users u
             ON u.UserTypeId = t.UserTypeId
            AND u.StatusId   = s.StatusId
            AND u.Is_Deleted = 0
     WHERE t.Is_Deleted = 0 AND s.Is_Deleted = 0
     GROUP BY t.UserTypeId, t.Name, s.StatusId, s.Name
     ORDER BY t.UserTypeId, s.StatusId;

    /*
      The sign-in health numbers an administrator actually opens this screen
      for: who is locked out right now, and how many accounts are carrying
      failed attempts.
    */
    SELECT
        (SELECT COUNT(*) FROM dbo.t_sso_users WHERE Is_Deleted = 0)                          AS Accounts,
        (SELECT COUNT(*) FROM dbo.t_sso_users WHERE Is_Deleted = 0 AND CreatedOn >= @From)   AS AccountsLast30Days,
        (SELECT COUNT(*) FROM dbo.t_sso_users WHERE Is_Deleted = 0 AND IsEmailVerified = 1)  AS EmailVerified,
        (SELECT COUNT(*) FROM dbo.t_sso_user_lockouts
          WHERE UnlockOn IS NULL AND Is_Deleted = 0)                                         AS LockedOut,
        (SELECT COUNT(*) FROM dbo.t_sso_users
          WHERE Is_Deleted = 0 AND FailedAttemptCount > 0)                                   AS WithFailedAttempts,
        CAST(@TodayIst AS date) AS AsOfIst;
END
GO

/*==============================================================================
  BUILD GUARD — AN ANALYTICS READ OF THE IDENTITY DATABASE PROJECTS NO IDENTITY
==============================================================================*/

/*
  🔴 THE ONE GUARD THIS FILE REALLY NEEDS.

  jp_sso is the database whose rows are people. A later edit that adds "and
  the newest five accounts" to this procedure would turn a REPORT.VIEW screen
  into an identity read — and REPORT.VIEW is held by people who are not
  trusted with USER.MANAGE.

  ⚠️ A text check, and the reason it is acceptable is 025's: the thing being
  looked for is a COLUMN NAME in a SELECT list, which dependencies record only
  at table granularity. The procedure is named, so this cannot drift.

  Proven to fire: adding u.Email to the first result set fails this.
*/
IF EXISTS (SELECT 1 FROM sys.sql_modules m
            WHERE m.object_id = OBJECT_ID('dbo.USP_GetIdentityAnalytics')
              AND (m.definition LIKE '%u.Email%'
                OR m.definition LIKE '%u.Mobile%'
                OR m.definition LIKE '%u.UserUid%'
                OR m.definition LIKE '%u.PasswordHash%'))
BEGIN
    RAISERROR('010_admin_analytics: 🔒 USP_GetIdentityAnalytics PROJECTS AN IDENTITY (Email, Mobile, UserUid or worse). This read is behind REPORT.VIEW, which is NOT USER.MANAGE - it answers how many, never who. One account at a time belongs on the Accounts screen.', 16, 1);
END
GO

PRINT '    Identity analytics procedure ready.';
GO
