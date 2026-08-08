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

MERGE dbo.t_mdm_request_levels AS tgt
USING (VALUES
        -- RequestTypeId, LevelNumber, RoleId,      IsFinalLevel
        (1, CAST(1 AS tinyint), @ROLE_ADMIN, CAST(1 AS tinyint)),  -- SCHOOL_REG
        (2, CAST(1 AS tinyint), @ROLE_ADMIN, CAST(1 AS tinyint)),  -- TEACHER_VERIFY
        (3, CAST(1 AS tinyint), @ROLE_ADMIN, CAST(1 AS tinyint)),  -- BRANCH_ADD
        (4, CAST(1 AS tinyint), @ROLE_ADMIN, CAST(1 AS tinyint))   -- OFFER_APPROVAL
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
