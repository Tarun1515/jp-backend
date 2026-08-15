/*==============================================================================
  jp_app — 04_procedures / 012_subscription.sql

  USP_GetCurrentSubscription — which plan an account is on right now.

  ---------------------------------------------------------------------------
  WHY THIS IS THE ONLY NEW PROCEDURE IN 3I
  ---------------------------------------------------------------------------
  Both dashboards show a plan, and nothing else in the system returns one. The
  school's profile (2.57), its team (2.58) and the teacher's profile (2.60)
  between them cover every other tile on both screens, so those are read rather
  than duplicated.

  ---------------------------------------------------------------------------
  🔴 THE OWNER IS A Uid, AND WHICH Uid DEPENDS ON THE ACCOUNT TYPE
  ---------------------------------------------------------------------------
  t_app_subscriptions.OwnerUid is the ORGANISATION for a school and the USER for
  a teacher (2.51). Neither is a parameter a client picks: the API takes the
  organisation from the token's orgUid claim and the user from its uuid claim
  (2.39), and passes exactly one of them.

  ---------------------------------------------------------------------------
  ⚠️ THE PLAN'S NAME IS NOT IN THIS DATABASE
  ---------------------------------------------------------------------------
  Plans live in jp_mdm.m_mdm_plans and no query may cross (2.2). This returns
  PlanId; the API reads the plan from jp_mdm and joins the two in memory, which
  is the same shape provisioning already uses in the other direction.

  ---------------------------------------------------------------------------
  🔴 `Is_Active AS IsActive` — THE ALIAS IS LOAD-BEARING (2.61)
  ---------------------------------------------------------------------------
  Dapper does not strip underscores, so `Is_Active` never reaches an `IsActive`
  property and the value arrives as false with nothing failing. That shipped
  once already on BranchDto and survived two phases because no screen displayed
  it (G25). This screen displays it, and the HTTP verification reads the row and
  the JSON for exactly this column.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE dbo.USP_GetCurrentSubscription
    @OwnerUid uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    /*
      TOP (1) with the newest first.

      UQ_t_app_subscriptions_OneActivePerOwner already makes two ACTIVE rows
      impossible, but an owner can hold an expired one beside a live one, and a
      dashboard asking "what am I on" means the current one.

      ⚠️ An account with NO row at all returns nothing, and that is a state the
      screen has to render rather than crash on: 3B found seven organisations
      that had been given a plan they should not have had, and the repair left
      the possibility of none. The dashboard says "no plan on file" and carries
      on.
    */
    SELECT TOP (1)
        s.SubscriptionId,
        s.SubscriptionUid,
        s.OwnerUid,
        s.PlanId,
        s.StartsOn,
        s.EndsOn,
        s.StatusId,
        s.AutoRenew,

        -- 🔴 Aliased. See the header — this is the whole class of bug G25 records.
        s.Is_Active AS IsActive
    FROM dbo.t_app_subscriptions s
    WHERE s.OwnerUid = @OwnerUid
      AND s.Is_Deleted = 0
    ORDER BY s.Is_Active DESC, s.StartsOn DESC, s.SubscriptionId DESC;
END
GO

PRINT '    Subscription procedures ready.';
GO
