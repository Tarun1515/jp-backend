/*==============================================================================
  jp_mdm — 03_seed / 002_seed_request_levels.sql

  Approval level configuration — ONE level per request type for MVP.

  ---------------------------------------------------------------------------
  🔴 ONE LEVEL TODAY DOES NOT MEAN ONE LEVEL IN THE ENGINE
  ---------------------------------------------------------------------------
  Every row here has LevelNumber = 1 and IsFinalLevel = 1, so in practice one
  approval finishes a request. USP_ProcessApprovalAction still reads the level
  configuration and advances properly, and must keep doing so.

  Phase 6 may add a two-level offer approval. Adding it should be an INSERT
  here — a second row with LevelNumber = 2 and IsFinalLevel = 1, and the first
  row flipped to 0. If the engine had been shortcut to assume one level, that
  same change would be a rewrite of the action procedure instead.

  ---------------------------------------------------------------------------
  RoleId comes from jp_sso
  ---------------------------------------------------------------------------
  ⚠️ These are jp_sso.t_sso_roles.RoleId values and there is NO foreign key
  (decision 2.2). The IDs below are the seeded admin roles.

  OrganizationUid is NULL on every row: these are the platform defaults. A row
  WITH an OrganizationUid overrides them for one organisation, which is how a
  large school group could later approve its own branch additions.

  Re-runnable. MERGE on the natural key, never deletes.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '    Seeding approval levels ...';
GO

/*
  RoleId 2 = ADMIN in jp_sso's role seed. Read into a variable rather than
  inlined four times, so the day the mapping changes there is one line to edit.

  ⚠️ Cross-database: this is a documented constant, not a lookup. jp_mdm cannot
  join to t_sso_roles to resolve it, and doing so would couple the two
  databases exactly as decision 2.2 forbids.
*/
DECLARE @ROLE_ADMIN int = 2;

/*
  🔴 PHASE 6A — OFFER_APPROVAL IS THE SCHOOL'S OWN APPROVAL, NOT THE PLATFORM'S.

  The other three request types are things an ADMINISTRATOR decides: a school
  registering, a teacher being verified, a campus being added. An offer is
  different — it is a school's internal sign-off on its own document, and no
  administrator should be in that loop.

  jp_sso's permission seed already says who: SCHOOL_OWNER holds OFFER.APPROVE
  and OFFER.CREATE; SENIOR_HR holds OFFER.CREATE alone. So the approver is the
  owner, and this row says so.

  ⚠️ IT WAS SEEDED AS @ROLE_ADMIN IN 2C, alongside the three admin types,
  because OFFER_APPROVAL was a placeholder with nothing riding it. Nothing was
  broken by that — no offer existed to approve — and nothing would have
  surfaced it either, which is why it is being corrected on the day the first
  offer is written rather than the day somebody notices.

  🔴 AND A SECOND LEVEL IS A ROW, NOT A RELEASE. A school that wants
  Senior HR -> Owner adds one row here (LevelNumber 2, IsFinalLevel 1, its own
  OrganizationUid) and flips level 1 to IsFinalLevel 0. 6A-0 proved the engine
  actually walks that path — reject, resubmit, role scoping and concurrency, all
  at level 2 — so this is configuration, and the procedure does not change.
*/
DECLARE @ROLE_SCHOOL_OWNER int = 4;

MERGE dbo.t_mdm_request_levels AS tgt
USING (VALUES
        -- RequestTypeId, LevelNumber, RoleId,      IsFinalLevel
        (1, CAST(1 AS tinyint), @ROLE_ADMIN, CAST(1 AS tinyint)),  -- SCHOOL_REG
        (2, CAST(1 AS tinyint), @ROLE_ADMIN, CAST(1 AS tinyint)),  -- TEACHER_VERIFY
        (3, CAST(1 AS tinyint), @ROLE_ADMIN, CAST(1 AS tinyint)),  -- BRANCH_ADD
        (4, CAST(1 AS tinyint), @ROLE_SCHOOL_OWNER, CAST(1 AS tinyint))  -- OFFER_APPROVAL (6A)
      ) AS src (RequestTypeId, LevelNumber, RoleId, IsFinalLevel)
    ON  tgt.RequestTypeId = src.RequestTypeId
    AND tgt.LevelNumber   = src.LevelNumber
    AND tgt.OrganizationUid IS NULL
    AND tgt.Is_Deleted    = 0
WHEN MATCHED AND (tgt.RoleId <> src.RoleId OR tgt.IsFinalLevel <> src.IsFinalLevel)
    THEN UPDATE SET tgt.RoleId       = src.RoleId,
                    tgt.IsFinalLevel = src.IsFinalLevel,
                    tgt.ModifiedOn   = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (RequestTypeId, LevelNumber, RoleId, IsFinalLevel, OrganizationUid)
         VALUES (src.RequestTypeId, src.LevelNumber, src.RoleId, src.IsFinalLevel, NULL);
GO

PRINT '    Approval levels seeded (1 level per request type).';
GO
