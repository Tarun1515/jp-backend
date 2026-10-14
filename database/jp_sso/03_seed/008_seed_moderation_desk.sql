/*==============================================================================
  jp_sso — 03_seed / 008_seed_moderation_desk.sql

  PHASE 7B — who may work the admin's operations desk.

  ---------------------------------------------------------------------------
  🔴 THREE OF THE FOUR PERMISSIONS ALREADY EXISTED, AND THAT IS THE POINT
  ---------------------------------------------------------------------------
  003 seeded MODERATION.JOB, MODERATION.REPORT and CMS.MANAGE in Phase 1, and
  004 granted them. They have sat there for seven phases with nothing behind
  them. 7B is what they gate, so this file does not invent them — it adds the
  one that was missing and ASSERTS THE CLOSED SETS, which is the half nobody
  had written.

  Measured before writing anything:

      MODERATION.JOB      SUPER_ADMIN, MODERATION_ADMIN
      MODERATION.REPORT   SUPER_ADMIN, MODERATION_ADMIN
      CMS.MANAGE          SUPER_ADMIN
      ENQUIRY.MANAGE      (did not exist)

  Those grants are already right. What was missing is the guard that keeps them
  right — 007's lesson is that asserting PRESENCE passes while an extra holder
  exists, and an extra holder is the failure that matters.

  ---------------------------------------------------------------------------
  🔴 WHY VERIFICATION_ADMIN HOLDS NEITHER MODERATION PERMISSION
  ---------------------------------------------------------------------------
  Verification answers "is this school real?" — a question about identity,
  settled once, before a school's first job goes live. Moderation answers "is
  this content acceptable?" — a question about what a verified school then
  posts, asked repeatedly.

  A verifier who could also pull jobs would be able to approve a school and
  then police its adverts, which is two jobs one person should not have to hold
  at once. The closed-set guard below is what stops that grant being added
  quietly.

  ---------------------------------------------------------------------------
  🔴 CMS.MANAGE ALSO GATES FEATURED PLACEMENT, AND THAT IS A REUSE
  ---------------------------------------------------------------------------
  Module 9 is called Content, and CMS.MANAGE means "may manage website
  content". Featuring a job or a school is a decision about WHAT THE PUBLIC
  SITE SHOWS — the same kind of decision as the FAQ copy and the content
  blocks, and held by the same role.

  ⚠️ Reuse was tested against 007's rule, which is whether an existing
  permission MEANS the thing. It does: all three surfaces change the public
  site's content, none of them touches a school's or teacher's own data, and
  all three belong to SUPER_ADMIN today. A FEATURED.MANAGE held by exactly the
  same role, gating exactly the same kind of act, would be a distinction with
  nothing on either side of it.

  ---------------------------------------------------------------------------
  🔴 WHY ENQUIRY.MANAGE IS NEW RATHER THAN MODERATION.REPORT REUSED
  ---------------------------------------------------------------------------
  A contact enquiry and an abuse report both arrive unbidden and both sit in a
  queue an admin dispositions with remarks, so reuse was tempting.

  It was rejected because acting on them is not the same act. Answering "how do
  we list our school?" is correspondence. Acting on a report can mean pulling a
  school's advert off the public site. Gating both on one permission means the
  person who answers the email can also pull content — and the first time this
  product has a support person who should do one and not the other, separating
  them is a migration performed under pressure.

  ⚠️ Both go to the same two roles TODAY, which is exactly the situation 007
  described for BILLING.MANAGE: the distinction costs nothing now and is the
  only thing that can express the separation later.

  Re-runnable: MERGE on the stable codes (2.47).
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '  Seeding ENQUIRY.MANAGE ...';
GO

/* Module 8 = MODERATION — the queue-triage family. */
MERGE dbo.t_sso_permissions AS tgt
USING (VALUES
        (8, 'ENQUIRY.MANAGE', N'Answer contact enquiries', 3)
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
           AND p.PermissionCode = 'ENQUIRY.MANAGE'
      ) AS src (RoleId, PermissionId)
    ON tgt.RoleId = src.RoleId AND tgt.PermissionId = src.PermissionId
WHEN MATCHED AND (tgt.Is_Deleted = 1 OR tgt.Is_Active = 0)
    THEN UPDATE SET tgt.Is_Deleted = 0, tgt.Is_Active = 1,
                    tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (RoleId, PermissionId) VALUES (src.RoleId, src.PermissionId);
GO

/*==============================================================================
  BUILD GUARDS — THE CLOSED SETS

  🔴 Each of these asserts the WHOLE holder list, not that the roles we had in
  mind are present. The failure that matters is an EXTRA holder, and a presence
  check passes while one exists — 007's lesson, applied to the four permissions
  7B puts behind real screens.

  Proven to fire: granting MODERATION.JOB to VERIFICATION_ADMIN fails the
  build, and so does granting CMS.MANAGE to MODERATION_ADMIN.
==============================================================================*/

DECLARE @expected TABLE (PermissionCode varchar(40), Holders nvarchar(400));

INSERT INTO @expected (PermissionCode, Holders)
VALUES
    ('MODERATION.JOB',    N'MODERATION_ADMIN, SUPER_ADMIN'),
    ('MODERATION.REPORT', N'MODERATION_ADMIN, SUPER_ADMIN'),
    ('ENQUIRY.MANAGE',    N'MODERATION_ADMIN, SUPER_ADMIN'),
    ('CMS.MANAGE',        N'SUPER_ADMIN');

DECLARE @drift nvarchar(max) = N'';

SELECT @drift = @drift + CHAR(10) + N'    ' + e.PermissionCode
              + N': expected [' + e.Holders + N'] but holds ['
              + ISNULL(actual.Holders, N'(nobody)') + N']'
  FROM @expected e
  OUTER APPLY (
        SELECT STRING_AGG(CAST(r.RoleCode AS nvarchar(40)), N', ') WITHIN GROUP (ORDER BY r.RoleCode) AS Holders
          FROM dbo.t_sso_role_permissions rp
         INNER JOIN dbo.t_sso_roles r       ON r.RoleId = rp.RoleId AND r.Is_Deleted = 0
         INNER JOIN dbo.t_sso_permissions p ON p.PermissionId = rp.PermissionId
         WHERE p.PermissionCode = e.PermissionCode
           AND rp.Is_Deleted = 0
           AND rp.Is_Active = 1
      ) AS actual
 WHERE ISNULL(actual.Holders, N'') <> e.Holders;

/*
  ⚠️ The message is assembled into a variable first. RAISERROR's substitution
  arguments must be variables or literals — CHAR(10) in the argument list is a
  syntax error, which is how the first version of this guard failed to deploy.
*/
IF @drift <> N''
BEGIN
    DECLARE @message nvarchar(max) =
        N'008_seed_moderation_desk: 🔒 A MODERATION-DESK PERMISSION HAS THE WRONG HOLDERS.' + @drift;

    RAISERROR('%s', 16, 1, @message);
END
GO

/*
  🔒 AND THE ONE THAT WOULD BE EASIEST TO ADD BY MISTAKE.

  VERIFICATION_ADMIN exists to answer "is this school real?". A grant of either
  moderation permission to it would read as a tidy consolidation and would hand
  one person both the approval of a school and the policing of what it posts.
  Named explicitly so the failure says WHY, not just that a set changed.
*/
IF EXISTS (SELECT 1
             FROM dbo.t_sso_role_permissions rp
            INNER JOIN dbo.t_sso_roles r       ON r.RoleId = rp.RoleId
            INNER JOIN dbo.t_sso_permissions p ON p.PermissionId = rp.PermissionId
            WHERE r.RoleCode = 'VERIFICATION_ADMIN'
              AND p.PermissionCode IN ('MODERATION.JOB', 'MODERATION.REPORT', 'CMS.MANAGE')
              AND rp.Is_Deleted = 0)
    RAISERROR('008_seed_moderation_desk: 🔒 VERIFICATION_ADMIN has been granted a moderation or content permission. Verification answers "is this school real" — once, before the first job. Moderation polices what a verified school then posts. One person holding both approves a school and then judges its adverts.', 16, 1);
GO

/*
  ⚠️ And no SCHOOL or TEACHER role may hold any of them. A school able to pull
  a job is a school able to pull a competitor's.
*/
DECLARE @outsiders nvarchar(400);

SELECT @outsiders = STRING_AGG(r.RoleCode + N'/' + p.PermissionCode, N', ')
  FROM dbo.t_sso_role_permissions rp
 INNER JOIN dbo.t_sso_roles r       ON r.RoleId = rp.RoleId
 INNER JOIN dbo.t_sso_permissions p ON p.PermissionId = rp.PermissionId
 WHERE r.RoleCode IN ('SCHOOL_OWNER', 'SENIOR_HR', 'HR', 'SCHOOL_VIEWER', 'TEACHER')
   AND p.PermissionCode IN ('MODERATION.JOB', 'MODERATION.REPORT', 'CMS.MANAGE', 'ENQUIRY.MANAGE')
   AND rp.Is_Deleted = 0;

IF @outsiders IS NOT NULL
    RAISERROR('008_seed_moderation_desk: 🔒 A school or teacher role holds a moderation-desk permission: %s. These gate the ADMIN desk; a school able to pull a job is a school able to pull a competitor''s.', 16, 1, @outsiders);
GO

PRINT '  Moderation desk permissions ready — 4 closed sets asserted.';
GO
