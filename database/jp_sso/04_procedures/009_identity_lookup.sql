/*==============================================================================
  jp_sso — 04_procedures / 009_identity_lookup.sql

  USP_GetUserIdentity — the Uid and RowVersion for a numeric UserId.

  ---------------------------------------------------------------------------
  WHY THIS EXISTS
  ---------------------------------------------------------------------------
  Phase 2D's approval orchestration holds a UserId (it comes off the approval
  request) but USP_UpdateUserStatus is keyed by UserUid and requires the current
  RowVersion — correctly, because it is normally driven by an admin acting on a
  screen they loaded a moment ago.

  The alternative was a second status-changing procedure that skips the
  concurrency check. That would mean two implementations of role granting and
  token revocation, and the day they drift is the day an approval stops
  revoking sessions. One lookup is the cheaper half of that trade.

  Read procedure: no transaction, so no CATCH (Block B of the template).

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE dbo.USP_GetUserIdentity
    @UserId bigint
AS
BEGIN
    SET NOCOUNT ON;

    SELECT u.UserId, u.UserUid, u.UserTypeId, u.StatusId, u.OrganizationUid,
           u.Email, u.RowVersion
    FROM dbo.t_sso_users u
    WHERE u.UserId = @UserId
      AND u.Is_Deleted = 0;
END
GO

PRINT '    USP_GetUserIdentity ready.';
GO
