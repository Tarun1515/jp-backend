/*==============================================================================
  jp_mdm — 04_procedures / 006_reconciliation.sql

  USP_GetCompletedApprovalsForReconciliation

  The jp_mdm half of the orphan hunt. jp_app holds USP_FindOrphanedApprovals,
  which answers "which of these approvals produced no school" — but it cannot
  ask the question itself, because the approvals live here and joining the two
  databases is what decision 2.2 forbids.

  So the API reads this list, hands it to jp_app, and gets back the subset that
  never provisioned.

  ---------------------------------------------------------------------------
  🔴 TEACHER VERIFICATION IS EXCLUDED, AND THAT IS THE WHOLE POINT
  ---------------------------------------------------------------------------
  Only request types that are SUPPOSED to create something in jp_app belong in
  a reconciliation list. A teacher verification provisions nothing by design
  (decision 2.9 — a teacher account is Active from signup, verification is a
  badge), so every approved teacher request would come back "orphaned", for
  ever, and correctly.

  A list that is permanently wrong is a list nobody reads. Within a month the
  real orphan — a school that paid and cannot sign in — would be sitting on
  page three under two hundred false ones.

  So the filter is on RequestTypeId, not on "did we find a school": types 1 and
  3 create a school, type 2 does not, and type 4 (offer approval, Phase 6) will
  need its own reconciliation against its own target table when it lands.

  ---------------------------------------------------------------------------
  THE LOOKBACK WINDOW
  ---------------------------------------------------------------------------
  @SinceDays bounds the scan. An orphan is found within hours in practice — the
  school complains — so the default of 90 days is already generous, and the
  parameter exists so an operator investigating something old can widen it
  rather than edit the procedure.

  ⚠️ There is no paging here on purpose. The healthy answer is zero rows. If
  this ever returns enough rows to need a pager, the paging is not the problem.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE dbo.USP_GetCompletedApprovalsForReconciliation
    @SinceDays int = 90
AS
BEGIN
    SET NOCOUNT ON;

    SET @SinceDays = CASE WHEN ISNULL(@SinceDays, 90) < 1 THEN 90
                          WHEN @SinceDays > 3650 THEN 3650
                          ELSE @SinceDays END;

    DECLARE @Since datetime2 = DATEADD(DAY, -@SinceDays, SYSUTCDATETIME());

    SELECT
        r.RequestId,
        r.RequestUid,
        r.RequestNo,
        r.RequestTypeId,
        rt.Name             AS RequestTypeName,
        r.EntityUid,
        r.OrganizationUid,
        r.RequestorUserId,
        r.CompletedOn,
        sd.SchoolName       AS EntityName
    FROM dbo.t_mdm_approval_requests r
        INNER JOIN dbo.m_mdm_request_types rt ON rt.RequestTypeId = r.RequestTypeId
        LEFT  JOIN dbo.t_mdm_school_registration_details sd
               ON sd.RequestId = r.RequestId AND sd.Is_Deleted = 0
    WHERE r.Is_Deleted    = 0
      AND r.StatusId      = 3            -- Approved. A rejection provisions nothing.
      AND r.RequestTypeId IN (1, 3)      -- 🔴 see the note above: NOT type 2
      AND r.CompletedOn IS NOT NULL
      AND r.CompletedOn >= @Since
    ORDER BY r.CompletedOn ASC;          -- oldest first: it has been broken longest
END
GO

PRINT '    USP_GetCompletedApprovalsForReconciliation ready.';
GO
