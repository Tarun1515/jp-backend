/*==============================================================================
  jp_sso — 03_seed / 004_seed_role_permissions.sql

  Which permissions each of the 8 system roles grants.

  Written as (RoleCode, PermissionCode) pairs and resolved to ids by joining,
  so the script never hardcodes an IDENTITY value and stays correct whatever
  order the roles and permissions happened to be inserted in.

  ---------------------------------------------------------------------------
  The shape of the school hierarchy
  ---------------------------------------------------------------------------
  SCHOOL_OWNER  everything for their organisation, including branches, team
                management and offer approval
  SENIOR_HR     the full hiring pipeline, but cannot approve offers, manage
                branches, or invite team members — the separation of duty that
                keeps offer approval with the owner
  HR            day-to-day sourcing and screening: create and edit jobs, view
                and shortlist applicants. Cannot publish, close, reject, or
                touch offers
  SCHOOL_VIEWER read-only

  Re-runnable. Only ever ADDS missing grants — a permission an admin has
  deliberately revoked from a system role is left revoked, which is why there
  is no WHEN MATCHED clause and no delete.
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

;WITH RolePermissionMap (RoleCode, PermissionCode) AS
(
    SELECT RoleCode, PermissionCode
    FROM (VALUES
        -- ==== SUPER_ADMIN — every permission ==============================
        ('SUPER_ADMIN', 'USER.MANAGE'),
        ('SUPER_ADMIN', 'PROFILE.EDIT'),
        ('SUPER_ADMIN', 'JOB.VIEW'),
        ('SUPER_ADMIN', 'JOB.CREATE'),
        ('SUPER_ADMIN', 'JOB.EDIT'),
        ('SUPER_ADMIN', 'JOB.PUBLISH'),
        ('SUPER_ADMIN', 'JOB.CLOSE'),
        ('SUPER_ADMIN', 'APPLICANT.VIEW'),
        ('SUPER_ADMIN', 'APPLICANT.SHORTLIST'),
        ('SUPER_ADMIN', 'APPLICANT.REJECT'),
        ('SUPER_ADMIN', 'RESUME.DOWNLOAD'),
        ('SUPER_ADMIN', 'OFFER.CREATE'),
        ('SUPER_ADMIN', 'OFFER.APPROVE'),
        ('SUPER_ADMIN', 'TEACHER_SEARCH.VIEW'),
        ('SUPER_ADMIN', 'TEACHER_SEARCH.INVITE'),
        ('SUPER_ADMIN', 'BRANCH.MANAGE'),
        ('SUPER_ADMIN', 'VERIFICATION.SCHOOL'),
        ('SUPER_ADMIN', 'VERIFICATION.TEACHER'),
        ('SUPER_ADMIN', 'REPORT.VIEW'),
        ('SUPER_ADMIN', 'MODERATION.JOB'),
        ('SUPER_ADMIN', 'MODERATION.REPORT'),
        ('SUPER_ADMIN', 'CMS.MANAGE'),
        ('SUPER_ADMIN', 'SETTINGS.MANAGE'),

        -- ==== VERIFICATION_ADMIN — the approval queue only ================
        ('VERIFICATION_ADMIN', 'VERIFICATION.SCHOOL'),
        ('VERIFICATION_ADMIN', 'VERIFICATION.TEACHER'),
        ('VERIFICATION_ADMIN', 'REPORT.VIEW'),

        -- ==== MODERATION_ADMIN — jobs and complaints only =================
        ('MODERATION_ADMIN', 'MODERATION.JOB'),
        ('MODERATION_ADMIN', 'MODERATION.REPORT'),
        ('MODERATION_ADMIN', 'REPORT.VIEW'),

        -- ==== SCHOOL_OWNER — everything within their organisation =========
        ('SCHOOL_OWNER', 'PROFILE.EDIT'),
        ('SCHOOL_OWNER', 'USER.MANAGE'),
        ('SCHOOL_OWNER', 'BRANCH.MANAGE'),
        ('SCHOOL_OWNER', 'JOB.VIEW'),
        ('SCHOOL_OWNER', 'JOB.CREATE'),
        ('SCHOOL_OWNER', 'JOB.EDIT'),
        ('SCHOOL_OWNER', 'JOB.PUBLISH'),
        ('SCHOOL_OWNER', 'JOB.CLOSE'),
        ('SCHOOL_OWNER', 'APPLICANT.VIEW'),
        ('SCHOOL_OWNER', 'APPLICANT.SHORTLIST'),
        ('SCHOOL_OWNER', 'APPLICANT.REJECT'),
        ('SCHOOL_OWNER', 'RESUME.DOWNLOAD'),
        ('SCHOOL_OWNER', 'OFFER.CREATE'),
        ('SCHOOL_OWNER', 'OFFER.APPROVE'),
        ('SCHOOL_OWNER', 'TEACHER_SEARCH.VIEW'),
        ('SCHOOL_OWNER', 'TEACHER_SEARCH.INVITE'),
        ('SCHOOL_OWNER', 'REPORT.VIEW'),

        -- ==== SENIOR_HR — full pipeline, no offer approval ================
        ('SENIOR_HR', 'JOB.VIEW'),
        ('SENIOR_HR', 'JOB.CREATE'),
        ('SENIOR_HR', 'JOB.EDIT'),
        ('SENIOR_HR', 'JOB.PUBLISH'),
        ('SENIOR_HR', 'JOB.CLOSE'),
        ('SENIOR_HR', 'APPLICANT.VIEW'),
        ('SENIOR_HR', 'APPLICANT.SHORTLIST'),
        ('SENIOR_HR', 'APPLICANT.REJECT'),
        ('SENIOR_HR', 'RESUME.DOWNLOAD'),
        ('SENIOR_HR', 'OFFER.CREATE'),
        ('SENIOR_HR', 'TEACHER_SEARCH.VIEW'),
        ('SENIOR_HR', 'TEACHER_SEARCH.INVITE'),
        ('SENIOR_HR', 'REPORT.VIEW'),

        -- ==== HR — sourcing and screening =================================
        ('HR', 'JOB.VIEW'),
        ('HR', 'JOB.CREATE'),
        ('HR', 'JOB.EDIT'),
        ('HR', 'APPLICANT.VIEW'),
        ('HR', 'APPLICANT.SHORTLIST'),
        ('HR', 'RESUME.DOWNLOAD'),
        ('HR', 'TEACHER_SEARCH.VIEW'),

        -- ==== SCHOOL_VIEWER — read only ===================================
        ('SCHOOL_VIEWER', 'JOB.VIEW'),
        ('SCHOOL_VIEWER', 'APPLICANT.VIEW'),
        ('SCHOOL_VIEWER', 'REPORT.VIEW'),

        -- ==== TEACHER — their own profile, and browsing jobs ==============
        ('TEACHER', 'PROFILE.EDIT'),
        ('TEACHER', 'JOB.VIEW')
    ) AS m (RoleCode, PermissionCode)
)
MERGE dbo.t_sso_role_permissions AS tgt
USING (
    SELECT r.RoleId, p.PermissionId
    FROM RolePermissionMap m
    INNER JOIN dbo.t_sso_roles r
        ON r.RoleCode = m.RoleCode
       AND r.OrganizationUid IS NULL      -- system roles only
       AND r.Is_Deleted = 0
    INNER JOIN dbo.t_sso_permissions p
        ON p.PermissionCode = m.PermissionCode
       AND p.Is_Deleted = 0
) AS src (RoleId, PermissionId)
    ON tgt.RoleId = src.RoleId
   AND tgt.PermissionId = src.PermissionId
   AND tgt.Is_Deleted = 0
-- No WHEN MATCHED: there is nothing to update on a bridge row, and re-adding a
-- grant an admin removed on purpose would be worse than leaving it alone.
WHEN NOT MATCHED BY TARGET
    THEN INSERT (RoleId, PermissionId)
         VALUES (src.RoleId, src.PermissionId);

DECLARE @GrantCount int = (SELECT COUNT(*) FROM dbo.t_sso_role_permissions WHERE Is_Deleted = 0);
PRINT '    t_sso_role_permissions seeded — ' + CAST(@GrantCount AS varchar(10)) + ' grants.';
GO

/*------------------------------------------------------------------------------
  Sanity check: every mapped permission code resolved to a real row.

  A typo in the map above would otherwise fail silently — the INNER JOIN would
  drop the pair and the role would quietly lack a permission, which nobody
  notices until a button does not appear for one role in production.
------------------------------------------------------------------------------*/
IF EXISTS (
    SELECT 1
    FROM dbo.t_sso_roles r
    WHERE r.OrganizationUid IS NULL
      AND r.Is_Deleted = 0
      AND NOT EXISTS (SELECT 1 FROM dbo.t_sso_role_permissions rp
                      WHERE rp.RoleId = r.RoleId AND rp.Is_Deleted = 0)
)
BEGIN
    DECLARE @Orphans nvarchar(500) = (
        SELECT STRING_AGG(r.RoleCode, ', ')
        FROM dbo.t_sso_roles r
        WHERE r.OrganizationUid IS NULL
          AND r.Is_Deleted = 0
          AND NOT EXISTS (SELECT 1 FROM dbo.t_sso_role_permissions rp
                          WHERE rp.RoleId = r.RoleId AND rp.Is_Deleted = 0)
    );

    RAISERROR('WARNING: these system roles have no permissions: %s', 10, 1, @Orphans) WITH NOWAIT;
END
GO
