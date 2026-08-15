/*==============================================================================
  jp_mdm — 04_procedures / 008_plans.sql

  USP_GetDefaultPlan — which plan a new account of this user type starts on.

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

PRINT '    Plan procedures ready.';
GO
