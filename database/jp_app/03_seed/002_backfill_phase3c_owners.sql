/*==============================================================================
  jp_app — 03_seed / 002_backfill_phase3c_owners.sql

  PHASE 3C — the school owner rows nothing ever wrote.

  ---------------------------------------------------------------------------
  🔴 WHY THIS EXISTS
  ---------------------------------------------------------------------------
  t_app_school_users has been empty since Phase 3A created it. Provisioning
  built the school, its head office and its subscription and never recorded who
  runs it.

  With that table empty, dbo.fn_VisibleBranches returns nothing for everybody —
  so every branch list, and from Phase 4 every job and applicant list, would
  have come back empty for every user. It would have read as a broken query
  rather than a missing row, and it would have been chased in the wrong file.

  ⚠️ Reads jp_sso and jp_mdm, writes jp_app. Same standing as the 3B backfill:
  a one-time operator migration, not application code. See the note in
  001_backfill_phase3b.sql.

  ---------------------------------------------------------------------------
  WHO THE OWNER IS
  ---------------------------------------------------------------------------
  The account that submitted the registration this school was provisioned from:

      t_app_schools.SourceRequestUid
        -> jp_mdm.t_mdm_approval_requests.RequestUid
        -> .RequestorUserId
        -> jp_sso.t_sso_users.UserUid

  ⚠️ A school with no SourceRequestUid — seeded directly, before the approval
  engine — cannot be resolved this way and is reported rather than guessed at.
  Picking "some school user in the same organisation" would be inventing an
  owner, and an owner is exactly the thing that must not be invented.

  Re-runnable: USP_ProvisionSchoolOwner returns ALREADY_PROVISIONED rather than
  failing, so a second pass reports 0 created.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

SET NOCOUNT ON;
GO

DECLARE @created int = 0, @skipped int = 0, @unresolved int = 0;

DECLARE @Owners TABLE (
    rn        int IDENTITY(1,1),
    SchoolId  bigint,
    UserUid   uniqueidentifier
);

INSERT INTO @Owners (SchoolId, UserUid)
SELECT s.SchoolId, u.UserUid
FROM dbo.t_app_schools s
    INNER JOIN jp_mdm.dbo.t_mdm_approval_requests r
        ON r.RequestUid = s.SourceRequestUid AND r.Is_Deleted = 0
    INNER JOIN jp_sso.dbo.t_sso_users u
        ON u.UserId = r.RequestorUserId AND u.Is_Deleted = 0
WHERE s.Is_Deleted = 0;

DECLARE @i int = 1, @n int = (SELECT COUNT(*) FROM @Owners);
DECLARE @SchoolId bigint, @UserUid uniqueidentifier;

DECLARE @Result TABLE (Status int, Code varchar(50), Message nvarchar(400), Id bigint);

PRINT '';
PRINT '=========================================================';
PRINT '  PHASE 3C — SCHOOL OWNER BACKFILL';
PRINT '=========================================================';

WHILE @i <= @n
BEGIN
    SELECT @SchoolId = SchoolId, @UserUid = UserUid FROM @Owners WHERE rn = @i;

    DELETE FROM @Result;

    INSERT INTO @Result (Status, Code, Message, Id)
    EXEC dbo.USP_ProvisionSchoolOwner @SchoolId = @SchoolId, @UserUid = @UserUid;

    IF EXISTS (SELECT 1 FROM @Result WHERE Code = 'ALREADY_PROVISIONED')
        SET @skipped = @skipped + 1;
    ELSE IF EXISTS (SELECT 1 FROM @Result WHERE Status = 1)
        SET @created = @created + 1;

    SET @i = @i + 1;
END

-- Schools whose owner cannot be traced back to an approval.
SELECT @unresolved = COUNT(*)
FROM dbo.t_app_schools s
WHERE s.Is_Deleted = 0
  AND NOT EXISTS (SELECT 1 FROM @Owners o WHERE o.SchoolId = s.SchoolId);

PRINT '     schools resolved : ' + CAST(@n AS varchar(6));
PRINT '     owners created   : ' + CAST(@created AS varchar(6));
PRINT '     already present  : ' + CAST(@skipped AS varchar(6));
PRINT '     UNRESOLVED       : ' + CAST(@unresolved AS varchar(6));

IF @unresolved > 0
BEGIN
    PRINT '';
    PRINT '  ⚠️ These schools have no approval behind them, so their owner cannot';
    PRINT '     be established. Nobody can see their branches until somebody is';
    PRINT '     added with USP_ProvisionSchoolOwner:';

    SELECT s.SchoolId, s.SchoolName, s.OrganizationUid, s.SourceRequestUid
    FROM dbo.t_app_schools s
    WHERE s.Is_Deleted = 0
      AND NOT EXISTS (SELECT 1 FROM @Owners o WHERE o.SchoolId = s.SchoolId);
END

PRINT '=========================================================';
GO
