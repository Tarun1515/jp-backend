/*==============================================================================
  jp_app — 90_ops / 001_verify_account_completeness.sql

  🔴 THE THREE THINGS THAT MUST NEVER BE TRUE.

      A. an Active teacher account with no profile
      B. an Active school whose school row has no head-office branch
      C. an Active account of either type with no subscription

  All three must return ZERO rows. Any row here is somebody who can sign in and
  will find something missing — the same failure shape as an orphaned approval
  (2.48), reached by a different road.

  ---------------------------------------------------------------------------
  WHY THIS FILE EXISTS AFTER THE BACKFILL IS DONE
  ---------------------------------------------------------------------------
  The Phase 3B backfill produces nothing visible, which makes it the step most
  likely to be half-finished. This query is the only evidence it was not.

  It is also the Phase 8 reconciliation check in embryo. USP_FindOrphanedApprovals
  answers "did an approval finish"; this answers "is every account whole". Phase
  8 should schedule both, and the fact that this one is a hand-run script today
  is the gap, not the query.

  ⚠️ Read-only. It reads jp_sso and jp_app together, which application code may
  not do (2.2) — an operator query run by a person is a different thing from a
  procedure the product calls. See the note in 03_seed/001_backfill_phase3b.sql.

  Run:
      sqlcmd -S localhost\TARUN -E -I -i database\jp_app\90_ops\001_verify_account_completeness.sql

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET NOCOUNT ON;
GO

/*------------------------------------------------------------------------------
  A. Active teacher accounts with no profile row.

  Active, not every account: somebody who registered and was suspended before
  ever being provisioned is a different question, and folding it in here would
  make this query permanently non-zero for a reason nobody needs to act on.
------------------------------------------------------------------------------*/
DECLARE @teachersWithoutProfile int;

SELECT @teachersWithoutProfile = COUNT(*)
FROM jp_sso.dbo.t_sso_users u
WHERE u.UserTypeId = 3
  AND u.StatusId   = 2          -- Active
  AND u.Is_Deleted = 0
  AND NOT EXISTS (SELECT 1 FROM dbo.t_app_teachers t
                  WHERE t.UserUid = u.UserUid AND t.Is_Deleted = 0);

SELECT 'A. Active teachers with NO profile' AS check_name,
       @teachersWithoutProfile              AS rows_found,
       CASE WHEN @teachersWithoutProfile = 0 THEN 'PASS' ELSE 'FAIL' END AS result;

IF @teachersWithoutProfile > 0
    SELECT u.UserId, u.Email, u.CreatedOn
    FROM jp_sso.dbo.t_sso_users u
    WHERE u.UserTypeId = 3 AND u.StatusId = 2 AND u.Is_Deleted = 0
      AND NOT EXISTS (SELECT 1 FROM dbo.t_app_teachers t
                      WHERE t.UserUid = u.UserUid AND t.Is_Deleted = 0)
    ORDER BY u.UserId;
GO

/*------------------------------------------------------------------------------
  B. Schools with no head-office branch.

  Driven from t_app_schools rather than from the accounts: the claim is about a
  school that EXISTS, and an Active school user whose registration was never
  approved has no school row to be missing a branch from.
------------------------------------------------------------------------------*/
DECLARE @schoolsWithoutHeadOffice int;

SELECT @schoolsWithoutHeadOffice = COUNT(*)
FROM dbo.t_app_schools s
WHERE s.Is_Deleted = 0
  AND NOT EXISTS (SELECT 1 FROM dbo.t_app_school_branches b
                  WHERE b.SchoolId = s.SchoolId AND b.IsHeadOffice = 1 AND b.Is_Deleted = 0);

SELECT 'B. Schools with NO head office' AS check_name,
       @schoolsWithoutHeadOffice        AS rows_found,
       CASE WHEN @schoolsWithoutHeadOffice = 0 THEN 'PASS' ELSE 'FAIL' END AS result;

IF @schoolsWithoutHeadOffice > 0
    SELECT s.SchoolId, s.SchoolName, s.OrganizationUid, s.CreatedOn
    FROM dbo.t_app_schools s
    WHERE s.Is_Deleted = 0
      AND NOT EXISTS (SELECT 1 FROM dbo.t_app_school_branches b
                      WHERE b.SchoolId = s.SchoolId AND b.IsHeadOffice = 1 AND b.Is_Deleted = 0)
    ORDER BY s.SchoolId;
GO

/*------------------------------------------------------------------------------
  C. Active accounts of either type with no subscription.

  ⚠️ The owner differs by type, and that is the whole subtlety: a teacher owns
  their own subscription, a school's belongs to its ORGANISATION (2.50). Two
  people at one school share one plan, and checking per user would report the
  second of them as missing one for ever.
------------------------------------------------------------------------------*/
DECLARE @accountsWithoutPlan int;

;WITH owners AS (
    -- Teachers: the account is the owner.
    SELECT u.UserId, u.Email, u.UserTypeId, u.UserUid AS OwnerUid
    FROM jp_sso.dbo.t_sso_users u
    WHERE u.UserTypeId = 3 AND u.StatusId = 2 AND u.Is_Deleted = 0

    UNION ALL

    -- Schools: the organisation is the owner.
    SELECT u.UserId, u.Email, u.UserTypeId, u.OrganizationUid
    FROM jp_sso.dbo.t_sso_users u
    WHERE u.UserTypeId = 2 AND u.StatusId = 2 AND u.Is_Deleted = 0
      AND u.OrganizationUid IS NOT NULL
)
SELECT @accountsWithoutPlan = COUNT(*)
FROM owners o
WHERE NOT EXISTS (SELECT 1 FROM dbo.t_app_subscriptions x
                  WHERE x.OwnerUid = o.OwnerUid AND x.StatusId = 1 AND x.Is_Deleted = 0);

SELECT 'C. Active accounts with NO subscription' AS check_name,
       @accountsWithoutPlan                      AS rows_found,
       CASE WHEN @accountsWithoutPlan = 0 THEN 'PASS' ELSE 'FAIL' END AS result;

-- BEGIN/END rather than a bare `;WITH` after the IF: a CTE has to start a
-- statement, and `IF cond ;WITH …` terminates the IF and leaves the CTE
-- dangling. Msg 102, and only on the branch that runs when something is wrong —
-- which is the branch nobody exercises until it matters.
IF @accountsWithoutPlan > 0
BEGIN
    WITH owners AS (
        SELECT u.UserId, u.Email, u.UserTypeId, u.UserUid AS OwnerUid
        FROM jp_sso.dbo.t_sso_users u
        WHERE u.UserTypeId = 3 AND u.StatusId = 2 AND u.Is_Deleted = 0
        UNION ALL
        SELECT u.UserId, u.Email, u.UserTypeId, u.OrganizationUid
        FROM jp_sso.dbo.t_sso_users u
        WHERE u.UserTypeId = 2 AND u.StatusId = 2 AND u.Is_Deleted = 0
          AND u.OrganizationUid IS NOT NULL
    )
    SELECT o.UserId, o.Email, o.UserTypeId, o.OwnerUid
    FROM owners o
    WHERE NOT EXISTS (SELECT 1 FROM dbo.t_app_subscriptions x
                      WHERE x.OwnerUid = o.OwnerUid AND x.StatusId = 1 AND x.Is_Deleted = 0)
    ORDER BY o.UserId;
END
GO
