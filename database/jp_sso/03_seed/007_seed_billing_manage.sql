/*==============================================================================
  jp_sso — 03_seed / 007_seed_billing_manage.sql

  BILLING.MANAGE — who may commit the account to money.

  ---------------------------------------------------------------------------
  🔴 THE HOLE THIS CLOSES, FOUND IN 6.5B
  ---------------------------------------------------------------------------
  6.5A shipped `POST /api/billing/plan-change` with no permission check. The
  owner comes from the token, so nobody could request a plan for somebody
  else's account — but ANY member of a school could request one for their own.

  A SCHOOL_VIEWER is read-only by design: it holds JOB.VIEW, APPLICANT.VIEW and
  REPORT.VIEW, and the 3F/3G rule is that actions it cannot take are ABSENT
  from its screens. Letting it commit the school to a payment was the one
  exception, and nothing anywhere said so.

  ⚠️ Found by measuring who gets the new menu row, not by a failing test: the
  row carries no PermissionCode (because SEEING your plan is a property of the
  account), so it appeared for the viewer — and that is what prompted the
  question of what the viewer could then DO.

  ---------------------------------------------------------------------------
  🔴 WHY A NEW PERMISSION AND NOT A REUSED ONE
  ---------------------------------------------------------------------------
  Reuse was looked for first, as 2.64 did when it reused SETTINGS.MANAGE. The
  school-side candidates, with their actual holders:

      PROFILE.EDIT    SCHOOL_OWNER          "may edit the school profile"
      USER.MANAGE     SCHOOL_OWNER          "may manage the team"
      BRANCH.MANAGE   SCHOOL_OWNER          "may manage campuses"

  All three are held by exactly the role that should hold billing, so reusing
  one would behave correctly TODAY. It was rejected anyway: none of them MEANS
  "may commit this account to a payment", and the first school that wants a
  finance person who handles billing without editing the profile would need a
  migration to separate them — performed under pressure, after somebody already
  has more access than intended.

  A permission is the only thing in this system that can express the
  distinction, which is the same argument 6.5A recorded for PAYMENT.VERIFY.

  ---------------------------------------------------------------------------
  🔴 WHAT IT GATES, AND WHAT IT DELIBERATELY DOES NOT
  ---------------------------------------------------------------------------
  GATED: requesting a plan change. It is a financial commitment.

  NOT GATED: seeing the plan panel. What plan the school is on, and how much of
  this month's allowance is left, is something an HR who is about to post a job
  genuinely needs — and hiding it would mean they discover the limit by being
  refused. So the MENU ROW carries no permission and the panel is readable by
  everyone; only the request control is gated, and 2.62 says an action somebody
  may not take is removed with an explanation rather than shown disabled.

  ---------------------------------------------------------------------------
  WHO HOLDS IT
  ---------------------------------------------------------------------------
  SCHOOL_OWNER — the person who answers for the school's money.

  TEACHER — because a teacher IS the account. There is one teacher role and no
  team, so withholding it would mean no teacher could ever change plan.

  🔒 NOT SENIOR_HR, NOT HR, NOT SCHOOL_VIEWER, and not any admin role: an
  administrator CONFIRMS payments (PAYMENT.VERIFY) and does not request plans
  on somebody's behalf. The guard below asserts that closed set.

  Re-runnable: MERGE on the stable codes (2.47).
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '  Seeding BILLING.MANAGE ...';
GO

/* ModuleId 11 = BILLING, created by 006 in 6.5A. */
MERGE dbo.t_sso_permissions AS tgt
USING (VALUES
        (11, 'BILLING.MANAGE', N'Request plan changes', 2)
      ) AS src (ModuleId, PermissionCode, PermissionName, DisplayOrder)
    ON tgt.PermissionCode = src.PermissionCode
WHEN MATCHED AND (tgt.ModuleId <> src.ModuleId
               OR tgt.PermissionName <> src.PermissionName)
    THEN UPDATE SET tgt.ModuleId       = src.ModuleId,
                    tgt.PermissionName = src.PermissionName,
                    tgt.DisplayOrder   = src.DisplayOrder,
                    tgt.ModifiedOn     = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (ModuleId, PermissionCode, PermissionName, DisplayOrder)
         VALUES (src.ModuleId, src.PermissionCode, src.PermissionName, src.DisplayOrder);
GO

PRINT '  Granting it to SCHOOL_OWNER and TEACHER ...';
GO

/*
  ⚠️ Resolved through the CODES, never the ids — an identity renumbers on a
  rebuilt database and the code is the contract (2.47).
*/
MERGE dbo.t_sso_role_permissions AS tgt
USING (
        SELECT r.RoleId, p.PermissionId
          FROM dbo.t_sso_roles r
         CROSS JOIN dbo.t_sso_permissions p
         WHERE r.RoleCode IN ('SCHOOL_OWNER', 'TEACHER')
           AND r.OrganizationUid IS NULL
           AND r.Is_Deleted = 0
           AND p.PermissionCode = 'BILLING.MANAGE'
      ) AS src (RoleId, PermissionId)
    ON tgt.RoleId = src.RoleId AND tgt.PermissionId = src.PermissionId
WHEN MATCHED AND (tgt.Is_Deleted = 1 OR tgt.Is_Active = 0)
    THEN UPDATE SET tgt.Is_Deleted = 0, tgt.Is_Active = 1,
                    tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (RoleId, PermissionId) VALUES (src.RoleId, src.PermissionId);
GO

/*==============================================================================
  BUILD GUARDS
==============================================================================*/

IF NOT EXISTS (SELECT 1 FROM dbo.t_sso_permissions
               WHERE PermissionCode = 'BILLING.MANAGE' AND Is_Active = 1 AND Is_Deleted = 0)
    RAISERROR('007_seed_billing_manage: BILLING.MANAGE is missing.', 16, 1);
GO

/*
  🔴 THE CLOSED SET, not "the roles I was thinking of are present".

  The failure that matters is an EXTRA holder — a viewer or an HR able to
  commit the school to a payment, which is exactly the hole this file closes.
  Asserting presence would pass while that was true.
*/
DECLARE @holders nvarchar(400);

SELECT @holders = STRING_AGG(r.RoleCode, ', ') WITHIN GROUP (ORDER BY r.RoleCode)
  FROM dbo.t_sso_role_permissions rp
  INNER JOIN dbo.t_sso_roles r       ON r.RoleId = rp.RoleId
  INNER JOIN dbo.t_sso_permissions p ON p.PermissionId = rp.PermissionId
 WHERE p.PermissionCode = 'BILLING.MANAGE'
   AND rp.Is_Deleted = 0 AND rp.Is_Active = 1
   AND r.Is_Deleted = 0;

IF ISNULL(@holders, '') <> 'SCHOOL_OWNER, TEACHER'
    RAISERROR('007_seed_billing_manage: BILLING.MANAGE is held by [%s]. It must be exactly SCHOOL_OWNER and TEACHER — a read-only viewer must not be able to commit the school to a payment, and an administrator confirms payments rather than requesting plans.', 16, 1, @holders);
GO

/*
  ⚠️ And the menu row stays UNGATED, asserted from the other side.

  Seeing which plan you are on is a property of the account, not a privilege —
  an HR about to post a job needs to know the limit before being refused by it.
  If somebody ever "tightens" this by attaching the permission to the row, the
  build fails and says why.
*/
IF EXISTS (SELECT 1 FROM dbo.m_sso_menus
           WHERE MenuCode IN ('SCHOOL_BILLING', 'TEACHER_BILLING')
             AND PermissionId IS NOT NULL)
    RAISERROR('007_seed_billing_manage: a billing MENU row has been given a PermissionCode. Seeing your own plan is not a privilege — only REQUESTING a change is gated (BILLING.MANAGE). Gating the row would hide the allowance an HR needs before they hit it.', 16, 1);
GO

PRINT '    BILLING.MANAGE ready (SCHOOL_OWNER + TEACHER; the menu row stays open).';
GO
