/*==============================================================================
  jp_sso — 03_seed / 006_seed_billing_permission.sql

  The BILLING module and PAYMENT.VERIFY — held by SUPER_ADMIN alone.

  ---------------------------------------------------------------------------
  🔴 WHY A NEW PERMISSION, WHEN 2.64 DELIBERATELY REUSED ONE
  ---------------------------------------------------------------------------
  Phase 2.5 faced the same choice and went the other way: deciding what a plan
  INCLUDES is a system setting, so it reused SETTINGS.MANAGE rather than
  creating a permission that would need a role grant and a screen before it did
  anything. That was right for that decision, and it is wrong for this one.

  Confirming that money arrived is not a system setting. It is an operational
  act with a money trail, and the two differ in a way that matters later:

    SETTINGS.MANAGE   "may change how the product is configured"
    PAYMENT.VERIFY    "may assert that this school's cheque cleared"

  An operator will eventually want somebody in finance to hold the second
  without the first — a person who confirms payments but cannot re-price plans
  or flip a kill switch. If they share one permission that separation is
  impossible without a migration, and the migration happens under pressure
  because somebody has already been given too much access.

  ⚠️ So the reasoning is not "new feature, new permission" — it is that these
  two abilities will be granted to different people, and a permission is the
  only thing in this system that can express that.

  ---------------------------------------------------------------------------
  🔴 SEEDED TO SUPER_ADMIN ONLY, AND TO NO SCHOOL OR TEACHER ROLE
  ---------------------------------------------------------------------------
  A school verifying its own payment is the entire attack. The grant list below
  has exactly one row, and the verification forces the negative: a school owner
  and a teacher both calling the verify endpoint get 403.

  ---------------------------------------------------------------------------
  WHY A NEW MODULE RATHER THAN HANGING IT UNDER SETTINGS
  ---------------------------------------------------------------------------
  Modules group permissions for the admin UI, and VERIFICATION and MODERATION
  are each their own module with their own sidebar group. A payments queue is
  the same kind of thing: its own screen, its own queue, its own permission.
  Putting it under Settings would mean the admin UI offers "Settings" as the
  place to find a payment, which is where nobody would look.

  ⚠️ NO MENU ROW HERE. A menu is data (2.37) and the rule this project runs on
  is that the row arrives in the SAME commit as the route it points at — which
  is 6.5B, the screens. A menu row now would be a sidebar link to a 404.

  Re-runnable: MERGE on the stable codes (2.47).
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '  Seeding the BILLING module ...';
GO

/*
  ModuleId is explicit, not an identity default — the ten existing modules
  carry written ids and t_sso_permissions.ModuleId names them (2.47).
*/
MERGE dbo.m_sso_modules AS tgt
USING (VALUES
        (11, 'BILLING', N'Billing', 11)
      ) AS src (ModuleId, Code, Name, DisplayOrder)
    ON tgt.ModuleId = src.ModuleId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder,
                    tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (ModuleId, Code, Name, DisplayOrder)
         VALUES (src.ModuleId, src.Code, src.Name, src.DisplayOrder);
GO

PRINT '  Seeding PAYMENT.VERIFY ...';
GO

MERGE dbo.t_sso_permissions AS tgt
USING (VALUES
        (11, 'PAYMENT.VERIFY', N'Verify payments and activate plans', 1)
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

PRINT '  Granting it to SUPER_ADMIN (and nobody else) ...';
GO

/*
  ⚠️ Resolved through the CODES, never through ids. 004_seed_role_permissions
  does the same: a RoleId or PermissionId is an identity that renumbers on a
  rebuilt database, and the code is the contract (2.47).
*/
MERGE dbo.t_sso_role_permissions AS tgt
USING (
        SELECT r.RoleId, p.PermissionId
          FROM dbo.t_sso_roles r
         CROSS JOIN dbo.t_sso_permissions p
         WHERE r.RoleCode = 'SUPER_ADMIN'
           AND p.PermissionCode = 'PAYMENT.VERIFY'
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
               WHERE PermissionCode = 'PAYMENT.VERIFY' AND Is_Active = 1 AND Is_Deleted = 0)
    RAISERROR('006_seed_billing_permission: PAYMENT.VERIFY is missing.', 16, 1);
GO

/*
  🔴 EXACTLY ONE ROLE HOLDS IT, AND THAT ROLE IS SUPER_ADMIN.

  Not "SUPER_ADMIN holds it" — that would pass while a school role held it too.
  The count is the assertion, because the failure that matters is an EXTRA
  grant, and a school verifying its own payment is the whole attack.

  ⚠️ This is the shape 2.56's grep uses: assert the closed set, not the
  presence of the member you were thinking about.
*/
DECLARE @holders int, @who nvarchar(400);

SELECT @holders = COUNT(*),
       @who = STRING_AGG(r.RoleCode, ', ')
  FROM dbo.t_sso_role_permissions rp
  INNER JOIN dbo.t_sso_roles r       ON r.RoleId = rp.RoleId
  INNER JOIN dbo.t_sso_permissions p ON p.PermissionId = rp.PermissionId
 WHERE p.PermissionCode = 'PAYMENT.VERIFY'
   AND rp.Is_Deleted = 0 AND rp.Is_Active = 1
   AND r.Is_Deleted = 0;

IF @holders <> 1 OR @who <> 'SUPER_ADMIN'
    RAISERROR('006_seed_billing_permission: PAYMENT.VERIFY is held by %d role(s): %s. It must be SUPER_ADMIN and nobody else — a school verifying its own payment is the entire attack.', 16, 1, @holders, @who);
GO

/*
  ⚠️ And it is NOT held by any school or teacher role, checked from the other
  direction — a role could in principle be renamed.
*/
IF EXISTS (SELECT 1
             FROM dbo.t_sso_role_permissions rp
             INNER JOIN dbo.t_sso_roles r       ON r.RoleId = rp.RoleId
             INNER JOIN dbo.t_sso_permissions p ON p.PermissionId = rp.PermissionId
            WHERE p.PermissionCode = 'PAYMENT.VERIFY'
              AND r.UserTypeId <> 1          -- 1 = Admin
              AND rp.Is_Deleted = 0 AND r.Is_Deleted = 0)
    RAISERROR('006_seed_billing_permission: PAYMENT.VERIFY is granted to a non-admin role.', 16, 1);
GO

PRINT '    BILLING module and PAYMENT.VERIFY ready (SUPER_ADMIN only).';
GO
