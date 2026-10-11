/*==============================================================================
  jp_mdm — 03_seed / 011_seed_plan_change_request.sql

  The PLAN_CHANGE request type, its number prefix, and its single level.

  ---------------------------------------------------------------------------
  🔴 WHAT THIS FILE DOES NOT SEED: ANY PAID PLAN
  ---------------------------------------------------------------------------
  008_seed_plans.sql forbids it, in writing, and the argument is better than
  the convenience of having something to test against:

      "Pricing is not finalised. The public site's FAQ says so. Anything
       seeded here with a price on it becomes a number the client read in
       software we delivered, and it will be quoted back at us."

  Checked rather than assumed, at the time this file was written: the public
  FAQ still says pricing is not finalised, the Terms still say that section
  cannot be completed until it is, and no price appears anywhere on the public
  site.

  So 6.5 ships the MECHANISM with the catalog containing only the free plan per
  user type — the same shape as 2.64 shipping an engine where nothing is gated.
  Going live is an INSERT of real plans and their m_mdm_plan_features mappings:
  data, not a deployment (2.7).

  ⚠️ The paid plan the verification needs is a SUITE FIXTURE, created and
  removed by the suite with the shipped state asserted on entry and exit. It is
  not seeded here, because a fixture that lives in the seed is not a fixture.

  ---------------------------------------------------------------------------
  WHY A REQUEST TYPE AT ALL
  ---------------------------------------------------------------------------
  t_mdm_request_payments.RequestId has had an FK to t_mdm_approval_requests
  since 2A, so a payment cannot exist without a request. That is the right
  shape rather than an obstacle: the request row is what carries the RequestNo
  a school quotes to support (2.46), the requestor, and the audit trail.

  🔴 One level, final, SUPER_ADMIN (RoleId 1). Verifying that money arrived is
  not a two-person workflow in this phase — and if a client ever wants
  maker/checker on it, 6A-0 proved the engine walks levels above 1, so it is a
  ROW rather than code.

  ⚠️ The decisive act is nonetheless PAYMENT VERIFICATION, not generic
  approval: it carries its own permission (PAYMENT.VERIFY) because it is an
  operational money action, and the level row exists so the request has a
  configured owner like every other type.

  Re-runnable: MERGE on the stable code (2.47).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '  Seeding the PLAN_CHANGE request type ...';
GO

/*
  RequestTypeId is NOT an identity on this master — the four existing rows
  carry explicit ids, and the id is contract (2.47): t_mdm_request_levels and
  every submit call name it. So 5 is written, not generated.

  RequestNoPrefix 'PLN' -> PLN-2026-00001.
*/
MERGE dbo.m_mdm_request_types AS tgt
USING (VALUES
        (5, 'PLAN_CHANGE', N'Plan change', 5, 'PLN')
      ) AS src (RequestTypeId, Code, Name, DisplayOrder, RequestNoPrefix)
    ON tgt.RequestTypeId = src.RequestTypeId
WHEN MATCHED AND (tgt.Code <> src.Code
               OR tgt.Name <> src.Name
               OR ISNULL(tgt.RequestNoPrefix, '') <> src.RequestNoPrefix)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder,
                    tgt.RequestNoPrefix = src.RequestNoPrefix,
                    tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (RequestTypeId, Code, Name, DisplayOrder, RequestNoPrefix)
         VALUES (src.RequestTypeId, src.Code, src.Name, src.DisplayOrder, src.RequestNoPrefix);
GO

PRINT '  Seeding its approval level ...';
GO

/*
  ⚠️ Keyed on (RequestTypeId, LevelNumber), not on LevelId — LevelId is an
  identity and would renumber on a rebuilt database, which is the whole reason
  2.47 says the code is the contract.

  OrganizationUid NULL = the platform's own level, not a school's override.
  That is the same shape the other four types use.
*/
MERGE dbo.t_mdm_request_levels AS tgt
USING (VALUES
        (5, 1, 1, 1)
      ) AS src (RequestTypeId, LevelNumber, IsFinalLevel, RoleId)
    ON tgt.RequestTypeId = src.RequestTypeId
   AND tgt.LevelNumber   = src.LevelNumber
   AND tgt.OrganizationUid IS NULL
   AND tgt.Is_Deleted    = 0
WHEN MATCHED AND (tgt.IsFinalLevel <> src.IsFinalLevel OR tgt.RoleId <> src.RoleId)
    THEN UPDATE SET tgt.IsFinalLevel = src.IsFinalLevel, tgt.RoleId = src.RoleId,
                    tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (RequestTypeId, LevelNumber, IsFinalLevel, RoleId, OrganizationUid)
         VALUES (src.RequestTypeId, src.LevelNumber, src.IsFinalLevel, src.RoleId, NULL);
GO

/*==============================================================================
  BUILD GUARDS
==============================================================================*/

/* The type, with a prefix — a type without one produces 'NULL-2026-00001'. */
IF NOT EXISTS (SELECT 1 FROM dbo.m_mdm_request_types
               WHERE RequestTypeId = 5 AND Code = 'PLAN_CHANGE'
                 AND RequestNoPrefix = 'PLN' AND Is_Active = 1)
    RAISERROR('011_seed_plan_change_request: PLAN_CHANGE type or its RequestNoPrefix is missing.', 16, 1);
GO

/* A type with no level cannot be submitted — the engine has nobody to route to. */
IF NOT EXISTS (SELECT 1 FROM dbo.t_mdm_request_levels
               WHERE RequestTypeId = 5 AND LevelNumber = 1
                 AND IsFinalLevel = 1 AND Is_Active = 1 AND Is_Deleted = 0)
    RAISERROR('011_seed_plan_change_request: PLAN_CHANGE has no final level 1.', 16, 1);
GO

/*
  🔴 THE PROHIBITION, ENFORCED RATHER THAN DESCRIBED (2.36).

  If a paid plan is ever seeded into the product seed, this fails the build and
  names the file to read. A comment asking people not to invent prices is not a
  guard, and the pressure to add "just a test plan" arrives in exactly the
  phase that needs one to test with — this one.

  ⚠️ It checks for a PUBLIC, non-default plan with a price, which is precisely
  "a tier a customer could be shown". A suite's fixture is removed in its
  finally, so a clean database has none; a fixture left behind by a killed run
  shows up here as a loud build failure, which is the correct outcome.
*/
IF EXISTS (SELECT 1 FROM dbo.m_mdm_plans
           WHERE Price > 0 AND IsPublic = 1 AND IsDefault = 0 AND Is_Deleted = 0)
BEGIN
    DECLARE @leaked nvarchar(400) =
        (SELECT STRING_AGG(PlanCode, ', ')
           FROM dbo.m_mdm_plans
          WHERE Price > 0 AND IsPublic = 1 AND IsDefault = 0 AND Is_Deleted = 0);

    RAISERROR('011_seed_plan_change_request: a PRICED PUBLIC plan exists (%s). 008_seed_plans.sql forbids seeding paid tiers — pricing is not finalised and a number we ship gets quoted back. If this is a suite fixture, the suite did not clean up.', 16, 1, @leaked);
END
GO

PRINT '    PLAN_CHANGE request type ready (PLN-YYYY-NNNNN, one final level, SUPER_ADMIN).';
GO
