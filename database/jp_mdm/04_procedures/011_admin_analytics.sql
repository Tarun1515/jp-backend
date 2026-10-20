/*==============================================================================
  jp_mdm — 04_procedures / 011_admin_analytics.sql

  USP_GetApprovalAnalytics — the jp_mdm half of the admin analytics screen.

  Verifications and every other approval: how many of each type sit in which
  state, how long the oldest open one has waited, and the thirty-day arrivals.

  ----------------------------------------------------------------------------
  🔴 THE NUMBER THIS SCREEN EXISTS FOR IS THE OLDEST OPEN REQUEST
  ----------------------------------------------------------------------------
  A queue is judged by its worst case, not its average: twelve pending
  verifications is fine if none is older than a day and a problem if one has
  waited three weeks. "How many are pending" is the number people ask for and
  "how long has the oldest waited" is the number that tells them something,
  so both are here.

  ⚠️ COUNTS ONLY — no requestor, no entity uid, no approver. Each row of this
  database is somebody's application; who belongs on the verification queue
  behind VERIFICATION.SCHOOL / VERIFICATION.TEACHER, not on a REPORT.VIEW
  screen. The guard at the foot asserts it.

  ⚠️ Days are whole days in IST (2.28), measured from the IST date rather than
  from a UTC instant, so a request submitted last night is "1 day" in Mumbai
  and not "0 days" for five and a half hours.

  Re-runnable. Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE dbo.USP_GetApprovalAnalytics
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TodayIst date = dbo.fn_IstToday();
    DECLARE @From datetime2 = DATEADD(MINUTE, -330, CAST(DATEADD(day, -29, @TodayIst) AS datetime2));

    /*
      ⚠️ CROSS JOIN so every (type, status) pair exists including the zeroes —
      "no rejected plan changes" is a fact, and a grid with holes reads wrong.
    */
    SELECT
        t.RequestTypeId,
        t.Name AS RequestTypeName,
        s.ApprovalStatusId AS StatusId,
        s.Name AS StatusName,
        COUNT(r.RequestId) AS Total,
        SUM(CASE WHEN r.SubmittedOn >= @From THEN 1 ELSE 0 END) AS Last30Days
      FROM dbo.m_mdm_request_types t
      CROSS JOIN dbo.m_mdm_approval_status s
      LEFT JOIN dbo.t_mdm_approval_requests r
             ON r.RequestTypeId = t.RequestTypeId
            AND r.StatusId      = s.ApprovalStatusId
            AND r.Is_Deleted    = 0
     WHERE t.Is_Deleted = 0 AND s.Is_Deleted = 0
     GROUP BY t.RequestTypeId, t.Name, s.ApprovalStatusId, s.Name
     ORDER BY t.RequestTypeId, s.ApprovalStatusId;

    /*
      🔴 THE WAIT, PER TYPE — and only for what is still open.

      StatusId 1 is PENDING and 4 is RESUBMIT_REQUIRED (8 is DRAFT, which is
      the requestor's own unsubmitted thing and waits on nobody here); a
      completed request's
      age says nothing about the queue. DATEDIFF on the IST dates, so the
      answer is whole calendar days as an administrator in India counts them.
    */
    SELECT
        t.RequestTypeId,
        t.Name AS RequestTypeName,
        COUNT(r.RequestId) AS StillOpen,
        ISNULL(MAX(DATEDIFF(day,
                            CAST(DATEADD(MINUTE, 330, r.SubmittedOn) AS date),
                            @TodayIst)), 0) AS OldestWaitingDays
      FROM dbo.m_mdm_request_types t
      LEFT JOIN dbo.t_mdm_approval_requests r
             ON r.RequestTypeId = t.RequestTypeId
            AND r.Is_Deleted    = 0
            AND r.StatusId IN (1, 4)
     WHERE t.Is_Deleted = 0
     GROUP BY t.RequestTypeId, t.Name
     ORDER BY t.RequestTypeId;

    -- ---- the headline, including what billing has waiting -----------------
    SELECT
        (SELECT COUNT(*) FROM dbo.t_mdm_approval_requests
          WHERE Is_Deleted = 0 AND StatusId IN (1, 4))                                 AS OpenRequests,
        (SELECT COUNT(*) FROM dbo.t_mdm_approval_requests
          WHERE Is_Deleted = 0 AND SubmittedOn >= @From)                               AS SubmittedLast30Days,
        (SELECT COUNT(*) FROM dbo.t_mdm_request_payments
          WHERE Is_Deleted = 0 AND PaymentStatusId = 1)                                AS PaymentsAwaiting,
        (SELECT COUNT(*) FROM dbo.t_mdm_error_log)                                     AS ErrorLogRows,
        CAST(@TodayIst AS date) AS AsOfIst;
END
GO

/*==============================================================================
  BUILD GUARD — NO IDENTITY, NO ENTITY, ON A REPORT.VIEW READ
==============================================================================*/

/*
  🔴 Same argument as jp_sso's: every row in this database is somebody's
  application, and the temptation on an analytics screen is "show me which
  ones". Which ones is the verification queue's job, behind a different
  permission.

  Proven to fire: adding r.RequestorUserId to the first result set fails this.
*/
IF EXISTS (SELECT 1 FROM sys.sql_modules m
            WHERE m.object_id = OBJECT_ID('dbo.USP_GetApprovalAnalytics')
              AND (m.definition LIKE '%r.RequestorUserId%'
                OR m.definition LIKE '%r.EntityUid%'
                OR m.definition LIKE '%r.ApproverUserId%'
                OR m.definition LIKE '%r.OrganizationUid%'
                OR m.definition LIKE '%r.RequestNo%'))
BEGIN
    RAISERROR('011_admin_analytics: 🔒 USP_GetApprovalAnalytics PROJECTS A REQUEST IDENTITY (requestor, approver, entity, organisation or request number). This read is behind REPORT.VIEW - it answers how many and how long, never which one or whose. The verification queue answers that, behind VERIFICATION.SCHOOL / VERIFICATION.TEACHER.', 16, 1);
END
GO

PRINT '    Approval analytics procedure ready.';
GO
