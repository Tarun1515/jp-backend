/*==============================================================================
  jp_mdm — 041_alter_school_registration_requested_plan.sql

  One column: the plan the school ASKED FOR while registering.

  ---------------------------------------------------------------------------
  🔴 WHAT THIS COLUMN IS, AND WHAT IT IS NOT
  ---------------------------------------------------------------------------
  It is a PREFERENCE recorded on an application. It is not a subscription, not
  a purchase, and not an entitlement. Nothing reads it to decide what a school
  may do.

  The account starts on the default plan — SCHOOL_FREE — exactly as
  USP_ProvisionSchoolFromApproval has always made it, and a paid choice becomes
  a PENDING PLAN_CHANGE REQUEST through the machinery 011_seed_plan_change_
  request.sql configured and USP_RequestPlanChange already implements. There is
  no second mechanism here; this column is the only thing the registration half
  was missing.

  ---------------------------------------------------------------------------
  🔴 WHY A CODE AND NOT A PlanId (2.47)
  ---------------------------------------------------------------------------
  Codes are the contract. Three reasons, in order of how much they would hurt:

    1. A draft lives for days or weeks — a school starts at their desk and
       finishes on a phone that evening, or next week. PlanId is a surrogate
       that a rebuilt database renumbers; PlanCode is the thing 011's build
       guard, 013's MERGE and every seed file key on.

    2. The admin queue and the school's own review screen render this. "3" is
       not something a human can check against a catalogue; SCHOOL_STANDARD is.

    3. The API resolves Code -> Id when it calls USP_RequestPlanChange, which
       is the same shape provisioning already uses for the default plan (the
       id is PASSED, never joined — 2.2).

  ---------------------------------------------------------------------------
  ⚠️ NULL AND 'SCHOOL_FREE' ARE DIFFERENT, AND BOTH ARE CORRECT
  ---------------------------------------------------------------------------
      NULL             This draft was started before the question existed, or
                       the school has not reached the review step yet.
      'SCHOOL_FREE'    They were asked and they chose Free.
      'SCHOOL_...'     They asked for a paid plan, and the account will STILL
                       start on Free with a pending request beside it.

  Collapsing the first two would be the cheap thing to do and it would throw
  away the one fact an admin may need later: whether this school was ever
  offered the choice. SR-0 found a field that registration collected and
  provisioning dropped; the lesson was that a field nobody can distinguish from
  "not asked" is a field that goes missing quietly.

  ---------------------------------------------------------------------------
  ⚠️ NO FOREIGN KEY, AND THAT IS NOT LAZINESS
  ---------------------------------------------------------------------------
  m_mdm_plans.PlanCode is unique through UQ_m_mdm_plans_PlanCode, which is
  FILTERED on Is_Deleted = 0 (035_m_mdm_plans.sql). SQL Server will not back a
  foreign key with a filtered index, so the choice is between dropping the
  filter on a master's business key — which would let a soft-deleted plan block
  a replacement code forever — and validating in the procedure.

  So USP_SaveSchoolRegistrationDraft refuses an unknown code (INVALID_PLAN)
  and that is where the rule lives, named, with a message somebody can act on.

  ⚠️ varchar(30) — the SAME width as m_mdm_plans.PlanCode. A narrower column
  would truncate a long code into one that silently matches nothing, and 040
  is in this folder precisely because that already happened once to
  m_mdm_district.Code.

  Block D of _TEMPLATE_table.sql: a deployed table is never edited in place.
  The column has its own guard, so run_all.sql stays replayable from scratch
  AND applies cleanly to a database that already holds drafts.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.t_mdm_school_registration_details')
                 AND name = 'RequestedPlanCode')
BEGIN
    PRINT '    Adding column [t_mdm_school_registration_details].[RequestedPlanCode] ...';

    ALTER TABLE dbo.t_mdm_school_registration_details
        ADD RequestedPlanCode varchar(30) NULL;
END
ELSE
    PRINT '    Column [t_mdm_school_registration_details].[RequestedPlanCode] already exists — skipped.';
GO

/*==============================================================================
  EXIT ASSERTIONS

  ⚠️ SHAPE, not data. Every existing draft has NULL here and that is the
  correct value for a draft started before the question was asked — so there is
  nothing about rows worth asserting.

  🔴 THE WIDTH IS ASSERTED, not just the existence. A column added as
  varchar(20) by a hand-edited copy of this file would accept SCHOOL_FREE and
  SCHOOL_STANDARD, truncate nothing today, and then silently cut a future code
  down to something that resolves to no plan at all. That failure appears weeks
  later as "the school asked for a plan and nothing happened", which is the
  exact class of bug SR-0's field matrix was written to find.
==============================================================================*/
DECLARE @type sysname = NULL, @len smallint = NULL;

SELECT @type = TYPE_NAME(c.user_type_id), @len = c.max_length
  FROM sys.columns c
 WHERE c.object_id = OBJECT_ID('dbo.t_mdm_school_registration_details')
   AND c.name = 'RequestedPlanCode';

IF @type IS NULL
    RAISERROR('041_alter_school_registration_requested_plan: [RequestedPlanCode] is missing after the run. Registration cannot carry the chosen plan without it, and the plan choice would vanish between the form and provisioning.', 16, 1);
ELSE IF @type <> N'varchar' OR @len <> 30
BEGIN
    DECLARE @m nvarchar(1000) =
        N'041_alter_school_registration_requested_plan: [RequestedPlanCode] is '
        + @type + N'(' + CAST(@len AS nvarchar(10))
        + N') and must be varchar(30) — the same width as m_mdm_plans.PlanCode. '
        + N'A narrower column truncates a plan code into one that matches no plan, '
        + N'which surfaces weeks later as a school whose chosen plan was silently ignored.';

    RAISERROR('%s', 16, 1, @m);
END
GO

PRINT '    t_mdm_school_registration_details carries the chosen plan (RequestedPlanCode).';
GO
