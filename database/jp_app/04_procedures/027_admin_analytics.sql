/*==============================================================================
  jp_app — 04_procedures / 027_admin_analytics.sql

  USP_GetAppAnalytics — the jp_app half of the admin analytics screen.

  ----------------------------------------------------------------------------
  🔴 EVERY NUMBER HERE IS DERIVED. NOT ONE COUNTER IS READ.
  ----------------------------------------------------------------------------
  One phase ago the moderation queue projected t_app_jobs.ApplicationCount — a
  column 016 forbids writing and 017 forbids reading, permanently zero — and
  every advert reported "0 applied" on the one screen where that number decides
  something. It shipped, and a screens suite caught it.

  So this file counts rows. It is slower and it is right, and an analytics
  screen is the last place to introduce a number that can drift from the list
  underneath it.

  ⚠️ NO NEW COUNTER COLUMNS, and none may be added for this screen later. If
  these counts become slow, the answer is an index or a materialised view with
  its own refresh — both of which are visible and testable — not a column
  somebody has to remember to increment.

  ----------------------------------------------------------------------------
  ⚠️ JOB STATUS IS THE EFFECTIVE ONE (2.65)
  ----------------------------------------------------------------------------
  fn_EffectiveJobStatusId, so an expired advert counts as EXPIRED even though
  no row stores 3. An analytics screen that disagreed with the public site
  about how many jobs are live would be worse than no screen.

  ----------------------------------------------------------------------------
  🔴 THREE DATABASES, THREE PROCEDURES, NO JOINS (2.2)
  ----------------------------------------------------------------------------
  Registrations live in jp_sso and verifications in jp_mdm. Each has its own
  procedure and the SERVICE assembles the three answers — the same shape
  provisioning has used since 2F. A cross-database join here would be the one
  place in the product that has one.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE dbo.USP_GetAppAnalytics
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today date = dbo.fn_IstToday();

    /*
      ⚠️ THE WINDOW IS IST-RELATIVE (2.28). "Last 30 days" means 30 calendar
      days in India, so the boundary is computed from fn_IstToday rather than
      from SYSUTCDATETIME — otherwise for five and a half hours a day the
      window would start on the wrong date.
    */
    DECLARE @From datetime2 = DATEADD(MINUTE, -330, CAST(DATEADD(day, -29, @Today) AS datetime2));

    -- ---- 1. jobs, by EFFECTIVE status --------------------------------------
    SELECT
        st.JobStatusId   AS StatusId,
        st.Name          AS StatusName,
        COUNT(j.JobId)   AS Total,
        SUM(CASE WHEN j.CreatedOn >= @From THEN 1 ELSE 0 END) AS Last30Days
      FROM dbo.m_app_job_status st
      LEFT JOIN dbo.t_app_jobs j
             ON dbo.fn_EffectiveJobStatusId(j.JobStatusId, j.LastDateToApply) = st.JobStatusId
            AND j.Is_Deleted = 0
     WHERE st.Is_Deleted = 0
     GROUP BY st.JobStatusId, st.Name
     ORDER BY st.JobStatusId;

    -- ---- 2. applications, by stage -----------------------------------------
    /*
      ⚠️ LEFT JOIN from the master, so a stage with no applications appears as
      a zero rather than vanishing. A funnel with a missing rung reads as a
      funnel with a different shape.
    */
    SELECT
        s.ApplicationStatusId AS StatusId,
        s.Name                AS StatusName,
        COUNT(a.ApplicationId) AS Total,
        SUM(CASE WHEN a.AppliedOn >= @From THEN 1 ELSE 0 END) AS Last30Days
      FROM dbo.m_app_application_status s
      LEFT JOIN dbo.t_app_applications a
             ON a.ApplicationStatusId = s.ApplicationStatusId
            AND a.Is_Deleted = 0
     WHERE s.Is_Deleted = 0
     GROUP BY s.ApplicationStatusId, s.Name
     ORDER BY s.ApplicationStatusId;

    -- ---- 3. invitations, and what teachers did with them -------------------
    SELECT
        s.InviteStatusId AS StatusId,
        s.Name           AS StatusName,
        COUNT(i.InviteId) AS Total,
        SUM(CASE WHEN i.CreatedOn >= @From THEN 1 ELSE 0 END) AS Last30Days
      FROM dbo.m_app_invite_status s
      LEFT JOIN dbo.t_app_teacher_invites i
             ON i.InviteStatusId = s.InviteStatusId
            AND i.Is_Deleted = 0
     WHERE s.Is_Deleted = 0
     GROUP BY s.InviteStatusId, s.Name
     ORDER BY s.InviteStatusId;

    -- ---- 4. the headline totals --------------------------------------------
    /*
      🔒 SCHOOLS AND TEACHERS AS COUNTS, NEVER AS A LIST. This screen reports
      how many; it is not a back door to who. 2.56 is about a teacher's contact
      reaching a school, and an aggregate reaches nobody — but an analytics
      screen is exactly where "just add the names" gets suggested, so the
      prohibition is written where that would happen.
    */
    SELECT
        (SELECT COUNT(*) FROM dbo.t_app_schools  WHERE Is_Deleted = 0)                  AS Schools,
        (SELECT COUNT(*) FROM dbo.t_app_schools  WHERE Is_Deleted = 0 AND IsVerified = 1) AS SchoolsVerified,
        (SELECT COUNT(*) FROM dbo.t_app_teachers WHERE Is_Deleted = 0)                  AS Teachers,
        (SELECT COUNT(*) FROM dbo.t_app_school_branches WHERE Is_Deleted = 0)           AS Campuses,
        (SELECT COUNT(*) FROM dbo.t_app_reports  WHERE Is_Deleted = 0 AND ReportStatusId IN (1, 2)) AS OpenReports,
        (SELECT COUNT(*) FROM dbo.t_app_contact_enquiries WHERE Is_Deleted = 0 AND IsResolved = 0)  AS OpenEnquiries,
        CAST(@Today AS date) AS AsOfIst;
END
GO

/*==============================================================================
  BUILD GUARD — NO COUNTER COLUMN MAY SNEAK BACK IN
==============================================================================*/

/*
  🔴 THE LESSON IS ONE PHASE OLD, SO IT GETS A GUARD RATHER THAN A COMMENT.

  t_app_jobs.ApplicationCount and ViewCount exist and are not maintained;
  reading either here would reproduce exactly the defect 8-0 found in the
  moderation queue, on a screen whose whole job is numbers.

  ⚠️ A TEXT CHECK, and the justification is 025's: what is being looked for is
  a COLUMN NAME in a SELECT list, which dependencies record at table
  granularity and cannot distinguish. The procedure is named, so the check
  cannot drift onto somebody else's code.

  Proven to fire: projecting j.ApplicationCount in section 1 fails this.
*/
IF EXISTS (SELECT 1 FROM sys.sql_modules m
            WHERE m.object_id = OBJECT_ID('dbo.USP_GetAppAnalytics')
              AND (m.definition LIKE '%j.ApplicationCount%'
                OR m.definition LIKE '%j.ViewCount%'
                OR m.definition LIKE '%jobs.ApplicationCount%'))
BEGIN
    RAISERROR('027_admin_analytics: 🔴 USP_GetAppAnalytics reads a DENORMALISED COUNTER (ApplicationCount or ViewCount). Those columns are never written (016) and never read (017) - permanently zero. 8-0 found the moderation queue projecting one and reporting 0 applied for every advert. Count the rows.', 16, 1);
END
GO

PRINT '    Admin analytics procedure ready.';
GO
