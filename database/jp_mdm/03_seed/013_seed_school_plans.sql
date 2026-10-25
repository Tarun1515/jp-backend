/*==============================================================================
  jp_mdm — 013_seed_school_plans.sql

  SCHOOL REVAMP (SR-4). The three school plans, and the gating that makes them
  mean something.

  ---------------------------------------------------------------------------
  🔴 THE PRICES ARE DUMMY. THEY ARE IN THE PLAN NAME SO NOBODY CAN MISS IT.
  ---------------------------------------------------------------------------
  Client directive 2026-10-20 gave these figures on a call; the client then
  said on 2026-10-25 to put any dummy price in for now and get the mechanism
  working. So that is what these are — a working catalogue with placeholder
  money, not a price list.

  ⚠️ AND THE PLACEHOLDER IS IN THE NAME, NOT ONLY IN THIS COMMENT. Every paid
  plan is called "Standard (SAMPLE PRICING)" and so on, because a comment in a
  seed file is read by developers and a plan NAME is read by customers. 008
  forbade seeding paid tiers precisely because "a number we ship gets quoted
  back at us" — the name is what stops that happening while the numbers are
  still placeholders.

  🔴 WHEN THE REAL LIST ARRIVES: change the Price AND drop "(SAMPLE PRICING)"
  from the three names, in one commit. The MERGE below updates both on re-run,
  deliberately — see the note on it.

  FIELD_MATRIX.md §E still asks the client to confirm the figures and to
  answer the one question that is NOT about price: the free plan's single job
  post — per month, or ever? That is a behaviour decision and is seeded as
  per-month until they say otherwise.

      FREE        ₹0        JOB_POST 1
      STANDARD    ₹1,499/mo JOB_POST 10 · TEACHER_SEARCH ✓ · TEACHER_INVITE 25
      UNLIMITED   ₹3,999/mo JOB_POST unlimited · TEACHER_SEARCH ✓ · TEACHER_INVITE 100

  ⚠️ AND ONE NUMBER IS STILL A QUESTION, NOT A DECISION: the free plan's single
  job post is seeded as 1 PER MONTH, because that is what "1/month" on the call
  most likely meant. FIELD_MATRIX.md §E asks the client to choose between that
  and one EVER — a trial that never ends and a trial that converts are
  different businesses, and we cannot guess. If they pick "one ever", the
  change is this file's QuotaPerPeriod plus the period the engine counts over,
  and nothing else.

  ---------------------------------------------------------------------------
  🔴 THIS SUPERSEDES 008_seed_plans.sql's RULE AGAINST PRICED PUBLIC PLANS
  ---------------------------------------------------------------------------
  008 forbade seeding paid tiers, and 011_seed_plan_change_request.sql has
  enforced it with a build guard since 6.5A: a PUBLIC, non-default plan with a
  price failed the build. That rule was right for as long as pricing was
  unknown — "a number we ship gets quoted back" is exactly the risk.

  The client has now given prices. So the guard does not disappear; it CHANGES
  SHAPE in the same commit as this file — from "no priced public plan may
  exist" to "the catalogue is EXACTLY this seeded set". An unexpected plan row
  still fails the build, which is the part worth keeping: the thing being
  guarded was never "no prices", it was "no price nobody approved".

  ---------------------------------------------------------------------------
  GATING MODES CHANGE HERE TOO
  ---------------------------------------------------------------------------
  2.64 shipped the engine switched off: every feature FREE, no mapping, nothing
  gated. Three features now become real:

      JOB_POST        FREE -> METERED    the thing plans are actually sold on
      TEACHER_SEARCH  FREE -> BOOLEAN    included or not; no counting
      TEACHER_INVITE  FREE -> METERED    counted per period

  ⚠️ THE OTHER THREE STAY FREE. JOB_FEATURED, APPLICATION_VIEW and
  TEACHER_PROFILE_BOOST are not part of any plan the client described, and
  gating something nobody has priced is how a customer hits a wall we cannot
  explain. 🔒 APPLICATION_VIEW in particular must stay free — see the hard rule
  below.

  ---------------------------------------------------------------------------
  🔒 THE HARD RULE: A SCHOOL'S OWN DATA IS NEVER PAYWALLED
  ---------------------------------------------------------------------------
  Posting a job is a consuming action and it gates. Reading the applicants to
  a job you already posted is NOT — nor is your profile, your team, or your
  own branches. A school that lets its plan lapse must still be able to reach
  the people who applied while it was paying.

  That is why APPLICATION_VIEW stays FREE here, and sr-billing.mjs asserts it
  from the outside with an exhausted quota.

  IDEMPOTENT. Every statement keys on the stable Code (2.47) and re-running
  changes nothing.
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '  Seeding the school plan catalogue (SR-4) ...';
GO

/*------------------------------------------------------------------- plans */
/*
  ⚠️ UserTypeId 2 is School. The two paid plans are PUBLIC (a school may see
  and choose them) and NOT default — SCHOOL_FREE stays the default, because
  every new account starts free and pays later (SR-4's registration flow).
*/
MERGE dbo.m_mdm_plans AS tgt
USING (VALUES
        ('SCHOOL_STANDARD',  2, N'Standard (SAMPLE PRICING)',  30, CAST(1499.00 AS decimal(10,2)), 0, 1, 2),
        ('SCHOOL_UNLIMITED', 2, N'Unlimited (SAMPLE PRICING)', 30, CAST(3999.00 AS decimal(10,2)), 0, 1, 3)
      ) AS src (PlanCode, UserTypeId, Name, DurationDays, Price, IsDefault, IsPublic, DisplayOrder)
    ON tgt.PlanCode = src.PlanCode AND tgt.Is_Deleted = 0
WHEN MATCHED AND (tgt.Price <> src.Price OR tgt.Name <> src.Name
               OR tgt.DurationDays <> src.DurationDays OR tgt.IsPublic <> src.IsPublic)
    /*
      ⚠️ PRICE IS UPDATED ON RE-RUN, unlike a master's Name. A price is not the
      client's text to edit in the database — it is a number this file owns,
      and the day they send a corrected list, changing it here and re-running
      must actually change it. A plan whose price silently stayed at the old
      number would be the worst possible outcome of this whole section.
    */
    THEN UPDATE SET tgt.Name = src.Name, tgt.DurationDays = src.DurationDays,
                    tgt.Price = src.Price, tgt.IsPublic = src.IsPublic,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (PlanCode, UserTypeId, Name, DurationDays, Price, IsDefault, IsPublic, DisplayOrder)
         VALUES (src.PlanCode, src.UserTypeId, src.Name, src.DurationDays, src.Price,
                 src.IsDefault, src.IsPublic, src.DisplayOrder);
GO

/*------------------------------------------------------------ gating modes */
UPDATE dbo.m_mdm_features
   SET GatingModeId = 3, ModifiedOn = SYSUTCDATETIME()
 WHERE FeatureCode IN ('JOB_POST', 'TEACHER_INVITE')
   AND GatingModeId <> 3 AND Is_Deleted = 0;

UPDATE dbo.m_mdm_features
   SET GatingModeId = 2, ModifiedOn = SYSUTCDATETIME()
 WHERE FeatureCode = 'TEACHER_SEARCH'
   AND GatingModeId <> 2 AND Is_Deleted = 0;
GO

/*----------------------------------------------------------- the mappings */
/*
  🔴 NULL QuotaPerPeriod ON UNLIMITED'S JOB_POST, AND IT IS NOT A SENTINEL.

  036_entitlement_catalog.sql has said since 2.5 that NULL means unlimited
  within the plan and 0 means explicitly none — "these are NOT the same and the
  procedure must not conflate them". 013_entitlement.sql line ~695 implements
  exactly that: NULL skips the quota comparison entirely.

  So there is no magic number here. 999999 would have been a number somebody
  eventually hits, and a number that appears on a screen.
*/
MERGE dbo.m_mdm_plan_features AS tgt
USING (
    SELECT p.PlanId, f.FeatureId, v.IsIncluded, v.QuotaPerPeriod
      FROM (VALUES
             ('SCHOOL_FREE',      'JOB_POST',       1, 1),
             ('SCHOOL_FREE',      'TEACHER_SEARCH', 0, NULL),

             ('SCHOOL_STANDARD',  'JOB_POST',       1, 10),
             ('SCHOOL_STANDARD',  'TEACHER_SEARCH', 1, NULL),
             ('SCHOOL_STANDARD',  'TEACHER_INVITE', 1, 25),

             ('SCHOOL_UNLIMITED', 'JOB_POST',       1, NULL),
             ('SCHOOL_UNLIMITED', 'TEACHER_SEARCH', 1, NULL),
             ('SCHOOL_UNLIMITED', 'TEACHER_INVITE', 1, 100)
           ) AS v (PlanCode, FeatureCode, IsIncluded, QuotaPerPeriod)
      JOIN dbo.m_mdm_plans    p ON p.PlanCode    = v.PlanCode    AND p.Is_Deleted = 0
      JOIN dbo.m_mdm_features f ON f.FeatureCode = v.FeatureCode AND f.Is_Deleted = 0
) AS src
   ON tgt.PlanId = src.PlanId AND tgt.FeatureId = src.FeatureId AND tgt.Is_Deleted = 0
WHEN MATCHED AND (tgt.IsIncluded <> src.IsIncluded
               OR ISNULL(tgt.QuotaPerPeriod, -1) <> ISNULL(src.QuotaPerPeriod, -1))
    THEN UPDATE SET tgt.IsIncluded = src.IsIncluded,
                    tgt.QuotaPerPeriod = src.QuotaPerPeriod,
                    tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (PlanId, FeatureId, IsIncluded, QuotaPerPeriod)
         VALUES (src.PlanId, src.FeatureId, src.IsIncluded, src.QuotaPerPeriod);
GO

/*==============================================================================
  EXIT ASSERTIONS — the catalogue is exactly what this file says
==============================================================================*/

DECLARE @plans int = (SELECT COUNT(*) FROM dbo.m_mdm_plans WHERE UserTypeId = 2 AND Is_Deleted = 0);

DECLARE @unlimited int = (
    SELECT COUNT(*) FROM dbo.m_mdm_plan_features pf
      JOIN dbo.m_mdm_plans p    ON p.PlanId    = pf.PlanId
      JOIN dbo.m_mdm_features f ON f.FeatureId = pf.FeatureId
     WHERE p.PlanCode = 'SCHOOL_UNLIMITED' AND f.FeatureCode = 'JOB_POST'
       AND pf.QuotaPerPeriod IS NULL AND pf.IsIncluded = 1 AND pf.Is_Deleted = 0);

DECLARE @appView int = (
    SELECT GatingModeId FROM dbo.m_mdm_features WHERE FeatureCode = 'APPLICATION_VIEW' AND Is_Deleted = 0);

IF @plans <> 3
BEGIN
    DECLARE @m1 nvarchar(600) = N'013_seed_school_plans: expected 3 school plans, found '
        + CAST(@plans AS nvarchar(10)) + N'. The catalogue is a closed set (see 011''s guard).';
    RAISERROR('%s', 16, 1, @m1);
END

IF @unlimited <> 1
    RAISERROR('013_seed_school_plans: SCHOOL_UNLIMITED''s JOB_POST must be included with a NULL quota — NULL is how the engine means unlimited (013_entitlement line ~695). A number here is a wall somebody eventually hits.', 16, 1);

/*
  🔒 THE HARD RULE, ASSERTED AT BUILD TIME.

  A school's own data is never paywalled. APPLICATION_VIEW going anything other
  than FREE would mean a school that let its plan lapse cannot read the people
  who applied while it was paying — which is not a pricing decision, it is
  taking something back.
*/
IF @appView <> 1
    RAISERROR('013_seed_school_plans: 🔒 APPLICATION_VIEW IS NO LONGER FREE. A school''s own data is never paywalled — reading the applicants to a job you already posted is not a consuming action. If this is deliberate, it needs a decision in PROJECT_MEMORY first, not a seed change.', 16, 1);

/*
  🔒 THE PLACEHOLDER MARKER MAY NOT QUIETLY DISAPPEAR.

  The one way this goes wrong is somebody tidying "(SAMPLE PRICING)" out of
  the names because it looks untidy on a screen, leaving dummy money in front
  of a customer with nothing saying so.

  Removing it is correct ONLY together with the real prices, and both are in
  this file — so this guard asks for them to move together.
*/
DECLARE @unmarked nvarchar(400) =
    (SELECT STRING_AGG(PlanCode, ', ')
       FROM dbo.m_mdm_plans
      WHERE Price > 0 AND Is_Deleted = 0
        AND Name NOT LIKE '%SAMPLE PRICING%');

IF ISNULL(@unmarked, N'') <> N''
BEGIN
    DECLARE @m3 nvarchar(1200) =
        N'013_seed_school_plans: 🔒 A PRICED PLAN NO LONGER SAYS ITS PRICE IS A PLACEHOLDER: '
        + @unmarked
        + N'. The prices in this file are dummy figures the client asked for to get the mechanism working, and the marker is in the plan NAME because a customer reads the name and nobody reads this comment. If the real price list has arrived, change the Price here in the same commit as the name — not the name alone.';

    RAISERROR('%s', 16, 1, @m3);
END

PRINT '    School plans ready — 3 plans (SAMPLE PRICING), JOB_POST metered, UNLIMITED on a NULL quota.';
GO
