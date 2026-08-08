/*==============================================================================
  jp_sso — 03_seed / 003_seed_permissions.sql

  The 23 permissions from DB_TABLE_STRUCTURE.md, grouped into the 10 modules.

  These codes travel in the JWT `perms` claim and are matched by
  permissionGuard() in Angular and ClaimsPrincipal.HasPermission() on the
  server. They are a public contract — renaming one is a breaking change that
  has to land on both sides at once.

  Module assignment note: TEACHER_SEARCH.* sits under APPLICANTS. Both are
  candidate-discovery surfaces, and the fixed 10-module list has no better home
  for it. It is a grouping label for the role editor UI only — nothing branches
  on a permission's module.

  Keyed on PermissionCode; PermissionId is IDENTITY. Re-runnable.
==============================================================================*/

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

SET NOCOUNT ON;
GO

MERGE dbo.t_sso_permissions AS tgt
USING (VALUES
        -- ---- Users (module 2) --------------------------------------------
        (2,  'USER.MANAGE',            N'Manage users and invitations',      1),
        (2,  'PROFILE.EDIT',           N'Edit profile',                      2),

        -- ---- Jobs (module 3) ---------------------------------------------
        (3,  'JOB.VIEW',               N'View jobs',                         1),
        (3,  'JOB.CREATE',             N'Create jobs',                       2),
        (3,  'JOB.EDIT',               N'Edit jobs',                         3),
        (3,  'JOB.PUBLISH',            N'Publish jobs',                      4),
        (3,  'JOB.CLOSE',              N'Close jobs',                        5),

        -- ---- Applicants (module 4) ---------------------------------------
        (4,  'APPLICANT.VIEW',         N'View applicants',                   1),
        (4,  'APPLICANT.SHORTLIST',    N'Shortlist applicants',              2),
        (4,  'APPLICANT.REJECT',       N'Reject applicants',                 3),
        (4,  'RESUME.DOWNLOAD',        N'Download resumes',                  4),
        (4,  'OFFER.CREATE',           N'Create offers',                     5),
        (4,  'OFFER.APPROVE',          N'Approve offers',                    6),
        (4,  'TEACHER_SEARCH.VIEW',    N'Search teachers',                   7),
        (4,  'TEACHER_SEARCH.INVITE',  N'Invite teachers to apply',          8),

        -- ---- Branches (module 5) -----------------------------------------
        (5,  'BRANCH.MANAGE',          N'Manage branches',                   1),

        -- ---- Verification (module 6) -------------------------------------
        (6,  'VERIFICATION.SCHOOL',    N'Verify school registrations',       1),
        (6,  'VERIFICATION.TEACHER',   N'Verify teacher profiles',           2),

        -- ---- Reports (module 7) ------------------------------------------
        (7,  'REPORT.VIEW',            N'View reports and dashboards',       1),

        -- ---- Moderation (module 8) ---------------------------------------
        (8,  'MODERATION.JOB',         N'Moderate job postings',             1),
        (8,  'MODERATION.REPORT',      N'Handle complaints and reports',     2),

        -- ---- CMS (module 9) ----------------------------------------------
        (9,  'CMS.MANAGE',             N'Manage website content',            1),

        -- ---- Settings (module 10) ----------------------------------------
        (10, 'SETTINGS.MANAGE',        N'Manage system settings',            1)
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

PRINT '    t_sso_permissions seeded — 23 permissions across 10 modules.';
GO
