/*==============================================================================
  jp_mdm — 04_procedures / 008_plans.sql

  USP_GetDefaultPlan — which plan a new account of this user type starts on.
  USP_GetPlanById    — the plan a subscription row points at (3I).
  USP_GetPlanByCode  — the plan a registration draft asked for, by code (SR-4).

  ---------------------------------------------------------------------------
  WHY THIS EXISTS RATHER THAN GOING THROUGH USP_GetMaster
  ---------------------------------------------------------------------------
  The generic master shape is Id / Code / Name / DisplayOrder / ParentId. A
  plan's answer to "is this the default" does not fit it, and bending the
  generic shape to carry one flag for one master is how a shared contract stops
  being shared.

  ⚠️ Read by the API during provisioning. Plans live here, subscriptions live
  in jp_app, and neither can join to the other (decision 2.2) — so the API
  reads the id here and passes it across, the same way it already carries the
  reconciliation list.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE dbo.USP_GetDefaultPlan
    @UserTypeId int
AS
BEGIN
    SET NOCOUNT ON;

    /*
      TOP (1) is belt and braces: UQ_m_mdm_plans_OneDefaultPerUserType already
      makes two defaults impossible. It is here so that if that index is ever
      dropped in a migration, this returns one plan rather than a result set
      the caller's QuerySingle would throw on — a school on an arbitrary plan
      is bad, a school that cannot be provisioned at all is worse.
    */
    SELECT TOP (1)
        p.PlanId,
        p.PlanCode,
        p.Name,
        p.UserTypeId,
        p.DurationDays,
        p.Price
    FROM dbo.m_mdm_plans p
    WHERE p.UserTypeId = @UserTypeId
      AND p.IsDefault  = 1
      AND p.Is_Active  = 1
      AND p.Is_Deleted = 0
    ORDER BY p.PlanId;
END
GO

/*==============================================================================
  USP_GetPlanById — one plan, by the id a subscription stores.

  ---------------------------------------------------------------------------
  THE OTHER HALF OF THE SAME CROSS-DATABASE READ (3I)
  ---------------------------------------------------------------------------
  Provisioning reads the DEFAULT plan here and passes its id into jp_app. Both
  dashboards need the journey back: jp_app holds a PlanId and no name, so the
  API reads the name here and joins the two in memory (2.2).

  ⚠️ No Is_Active filter, deliberately. A subscription can point at a plan that
  has since been withdrawn, and "your plan" is still the honest answer — hiding
  it would leave the dashboard showing an account with no plan at all, which is
  a different and wrong statement.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetPlanById
    @PlanId int
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.PlanId,
        p.PlanCode,
        p.Name,
        p.UserTypeId,
        p.DurationDays,
        p.Price
    FROM dbo.m_mdm_plans p
    WHERE p.PlanId = @PlanId
      AND p.Is_Deleted = 0;
END
GO

/*==============================================================================
  USP_GetPlanByCode — one plan, by the CODE that is the contract (2.47).

  ---------------------------------------------------------------------------
  WHY A THIRD READ RATHER THAN A FOURTH PARAMETER ON ONE OF THE OTHER TWO
  ---------------------------------------------------------------------------
  The three questions are genuinely different: "what does a new account start
  on", "what is the plan this subscription stores", and "which plan is this
  code". A single procedure taking an optional id and an optional code would
  have to decide what to do when it is given both, and the answer to that is
  never written down anywhere a caller can see it.

  ⚠️ WHO ASKS, AND WHY IT CANNOT BE A JOIN. Registration stores the plan the
  school ASKED FOR as a code (041). At provisioning the API has to turn that
  into the @PlanId USP_RequestPlanChange takes — and provisioning's other half
  is in jp_app, which cannot see this table (2.2). So the id is read here and
  PASSED, which is the same shape USP_GetDefaultPlan has used since 2D.

  🔴 IsPublic AND Is_Active ARE FILTERED, unlike USP_GetPlanById.

  That difference is the point. GetById answers "what is this account on", and a
  withdrawn plan is still the honest answer for a subscription that points at
  it. This one answers "may a school JOIN this plan", asked about a choice made
  days earlier — and a plan withdrawn since then must stop resolving, or
  approval would open a pending payment for a tier that no longer exists.

  ⚠️ No UserTypeId filter and none wanted: the caller passes the code it read
  off its own draft, and the draft's code was already checked against the
  school user type by USP_SaveSchoolRegistrationDraft. A second type check here
  would be a second answer to one question, and the pair would eventually
  disagree. The CALLER compares UserTypeId on the row it gets back.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetPlanByCode
    @PlanCode varchar(30)
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.PlanId,
        p.PlanCode,
        p.Name,
        p.UserTypeId,
        p.DurationDays,
        p.Price
    FROM dbo.m_mdm_plans p
    WHERE p.PlanCode  = @PlanCode
      AND p.IsPublic  = 1
      AND p.Is_Active = 1
      AND p.Is_Deleted = 0;
END
GO

PRINT '    Plan procedures ready.';
GO
