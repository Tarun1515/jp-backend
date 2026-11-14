/*==============================================================================
  jp_sso — 03_seed / 009_seed_campus_pin_permission.sql

  SCHOOL REVAMP (SR-2) — who may correct a school's campus pin.

      MODERATION.CAMPUS_PIN      SUPER_ADMIN, MODERATION_ADMIN

  ---------------------------------------------------------------------------
  🔴 A NEW PERMISSION, AND THE TWO REUSES THAT WERE CONSIDERED FIRST
  ---------------------------------------------------------------------------
  007's rule for this decision is whether an EXISTING permission MEANS the
  thing. Both candidates were weighed against the act itself: an administrator
  overwriting the map position a school set for its own campus, or recording
  that a nine-kilometre discrepancy is correct.

  VERIFICATION.SCHOOL — REJECTED, and it was the first choice.
      The surface reads like verification: "is this school where it says it
      is?" is an identity question, VERIFICATION_ADMIN already answers identity
      questions, and the campus-pin desk sits beside the verification queue in
      the admin's day.

      It was rejected on what the permission GATES, not on what it reads like.
      Verification is settled ONCE, before a school's first job goes live —
      008's header is explicit about that, and about why a verifier must not
      also police a verified school. A campus pin is corrected at any time,
      years after approval, about a campus that did not exist when the school
      was verified. Granting this to VERIFICATION.SCHOOL would hand every
      verifier a permanent write on every school's location data, which is a
      wider and longer-lived power than the one-time approval they were trusted
      with.

  MODERATION.REPORT — REJECTED, and this is 008's ENQUIRY.MANAGE argument
      repeated almost word for word. Reading complaints and moving a school's
      location are not the same act: one is triage of what the public sent in,
      the other writes a figure a school supplied and that teachers will search
      on. Gating both on one permission means whoever works the reports queue
      can also relocate any campus on the platform, and separating them later
      is a migration performed under pressure.

  🔴 SO IT IS NEW, AND IT IS A MODERATION PERMISSION RATHER THAN A VERIFICATION
  ONE. Correcting another school's coordinates is policing the content a
  verified school publishes — which is what moderation means here — even though
  the content is a coordinate rather than an advert.

  ⚠️ IT GOES TO THE SAME TWO ROLES AS MODERATION.JOB TODAY, which is exactly
  the situation 007 described for BILLING.MANAGE and 008 for ENQUIRY.MANAGE:
  the distinction costs nothing now and is the only thing that can express the
  separation later.

  ---------------------------------------------------------------------------
  🔴 WHY A SEPARATE FILE AND NOT A LINE IN 008
  ---------------------------------------------------------------------------
  008 is Phase 7B's record of the moderation desk and of the four closed sets
  it asserts. Editing it would put SR-2 content inside 7B's account of itself
  and make its "measured before writing anything" table untrue — the same
  reason Block D of _TEMPLATE_table.sql forbids editing a deployed CREATE.

  🔴 AND IT MUST RUN BEFORE 005_seed_menus.sql. 005 asserts that every
  PermissionCode its menu rows name EXISTS, and one of them is now
  MODERATION.CAMPUS_PIN. Listed after 005, the whole build fails with "unknown
  PermissionCode(s)" — which is precisely what happened to 008 and 006, and is
  why run_all.sql carries that ordering comment. This file is registered in the
  same place and for the same reason.

  Re-runnable: MERGE on the stable code (2.47).
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '  Seeding MODERATION.CAMPUS_PIN ...';
GO

/*
  Module 8 = MODERATION — the queue-triage family, where MODERATION.JOB,
  MODERATION.REPORT and ENQUIRY.MANAGE already live.

  DisplayOrder 4: JOB is 1, REPORT is 2, ENQUIRY.MANAGE is 3 (008).
*/
MERGE dbo.t_sso_permissions AS tgt
USING (VALUES
        (8, 'MODERATION.CAMPUS_PIN', N'Correct a campus map pin', 4)
      ) AS src (ModuleId, PermissionCode, PermissionName, DisplayOrder)
    ON tgt.PermissionCode = src.PermissionCode
   AND tgt.Is_Deleted = 0
WHEN MATCHED AND (tgt.ModuleId <> src.ModuleId
               OR tgt.PermissionName <> src.PermissionName
               OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.ModuleId       = src.ModuleId,
                    tgt.PermissionName = src.PermissionName,
                    tgt.DisplayOrder   = src.DisplayOrder,
                    tgt.ModifiedOn     = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (ModuleId, PermissionCode, PermissionName, DisplayOrder)
         VALUES (src.ModuleId, src.PermissionCode, src.PermissionName, src.DisplayOrder);
GO

PRINT '  Granting it to SUPER_ADMIN and MODERATION_ADMIN ...';
GO

/* ⚠️ Resolved through the CODES, never the ids — an identity renumbers (2.47). */
MERGE dbo.t_sso_role_permissions AS tgt
USING (
        SELECT r.RoleId, p.PermissionId
          FROM dbo.t_sso_roles r
         CROSS JOIN dbo.t_sso_permissions p
         WHERE r.RoleCode IN ('SUPER_ADMIN', 'MODERATION_ADMIN')
           AND r.OrganizationUid IS NULL
           AND r.Is_Deleted = 0
           AND p.PermissionCode = 'MODERATION.CAMPUS_PIN'
      ) AS src (RoleId, PermissionId)
    ON tgt.RoleId = src.RoleId AND tgt.PermissionId = src.PermissionId
WHEN MATCHED AND (tgt.Is_Deleted = 1 OR tgt.Is_Active = 0)
    THEN UPDATE SET tgt.Is_Deleted = 0, tgt.Is_Active = 1,
                    tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (RoleId, PermissionId) VALUES (src.RoleId, src.PermissionId);
GO

/*==============================================================================
  BUILD GUARDS — THE CLOSED SET

  🔴 008's rule: assert the WHOLE holder list, not that the roles we had in mind
  are present. The failure that matters is an EXTRA holder, and a presence check
  passes while one exists (007's lesson).

  ⚠️ 008 asserts ITS four and is deliberately left alone; this file asserts its
  one. Adding a fifth row to 008's table would have been the tidier-looking
  change and would have made 7B's file claim to be the authority on a permission
  that did not exist when it was written.

  Proven to fire: granting MODERATION.CAMPUS_PIN to VERIFICATION_ADMIN fails the
  build, and so does withholding it from MODERATION_ADMIN.
==============================================================================*/
DECLARE @holders nvarchar(400) =
    (SELECT STRING_AGG(CAST(r.RoleCode AS nvarchar(40)), N', ') WITHIN GROUP (ORDER BY r.RoleCode)
       FROM dbo.t_sso_role_permissions rp
      INNER JOIN dbo.t_sso_roles r       ON r.RoleId = rp.RoleId AND r.Is_Deleted = 0
      INNER JOIN dbo.t_sso_permissions p ON p.PermissionId = rp.PermissionId
      WHERE p.PermissionCode = 'MODERATION.CAMPUS_PIN'
        AND rp.Is_Deleted = 0
        AND rp.Is_Active  = 1);

IF ISNULL(@holders, N'(nobody)') <> N'MODERATION_ADMIN, SUPER_ADMIN'
BEGIN
    DECLARE @drift nvarchar(1000) =
        N'009_seed_campus_pin_permission: 🔒 MODERATION.CAMPUS_PIN HAS THE WRONG HOLDERS. Expected '
      + N'[MODERATION_ADMIN, SUPER_ADMIN] but holds [' + ISNULL(@holders, N'(nobody)') + N']. '
      + N'It is the right to overwrite the map position a school set for its own campus. See this '
      + N'file''s header for why it is neither VERIFICATION.SCHOOL nor MODERATION.REPORT.';

    RAISERROR('%s', 16, 1, @drift);
END
GO

/*
  🔒 AND THE ONE THAT WOULD BE EASIEST TO ADD BY MISTAKE.

  VERIFICATION_ADMIN was the first candidate for this permission and is the
  role somebody will reach for when the campus-pin desk turns out to sit beside
  the verification queue on screen. Named explicitly so the failure says WHY,
  not just that a set changed — and because 008 already refuses that role every
  other moderation permission, so a grant here would be the one inconsistency.
*/
IF EXISTS (SELECT 1
             FROM dbo.t_sso_role_permissions rp
            INNER JOIN dbo.t_sso_roles r       ON r.RoleId = rp.RoleId
            INNER JOIN dbo.t_sso_permissions p ON p.PermissionId = rp.PermissionId
            WHERE r.RoleCode = 'VERIFICATION_ADMIN'
              AND p.PermissionCode = 'MODERATION.CAMPUS_PIN'
              AND rp.Is_Deleted = 0)
    RAISERROR('009_seed_campus_pin_permission: 🔒 VERIFICATION_ADMIN has been granted MODERATION.CAMPUS_PIN. Verification is settled ONCE, before a school''s first job goes live (008''s header). A campus pin is corrected years later, about a campus that did not exist when the school was verified — a permanent write on every school''s location data is wider than the one-time approval a verifier was trusted with.', 16, 1);
GO

/*
  ⚠️ And no SCHOOL or TEACHER role may hold it. 008's outsiders guard, for the
  sharper version of its reason: a school able to correct a campus pin is a
  school able to move a competitor's campus out of every nearby search.
*/
DECLARE @outsiders nvarchar(400);

/*
  ⚠️ CAST(... AS nvarchar(40)), LIKE THE GUARD ABOVE. `RoleCode` is varchar and
  the separator here is an N-literal; STRING_AGG refuses the pair with
  "Argument data type nvarchar is invalid for argument 2", which reads as a
  problem with the SEPARATOR and is actually a mismatch with the EXPRESSION.
  The sibling guard twenty lines up already had the cast — this one did not,
  and the build stopped on it.
*/
SELECT @outsiders = STRING_AGG(CAST(r.RoleCode AS nvarchar(40)), N', ')
  FROM dbo.t_sso_role_permissions rp
 INNER JOIN dbo.t_sso_roles r       ON r.RoleId = rp.RoleId
 INNER JOIN dbo.t_sso_permissions p ON p.PermissionId = rp.PermissionId
 WHERE r.RoleCode IN ('SCHOOL_OWNER', 'SENIOR_HR', 'HR', 'SCHOOL_VIEWER', 'TEACHER')
   AND p.PermissionCode = 'MODERATION.CAMPUS_PIN'
   AND rp.Is_Deleted = 0;

IF @outsiders IS NOT NULL
    RAISERROR('009_seed_campus_pin_permission: 🔒 A school or teacher role holds MODERATION.CAMPUS_PIN: %s. It gates the ADMIN desk; a school able to correct a campus pin is a school able to move a competitor''s campus out of every nearby search.', 16, 1, @outsiders);
GO

PRINT '  Campus pin permission ready — closed set asserted.';
GO
