/*==============================================================================
  jp_sso — 03_seed / 002_seed_roles.sql

  The 8 system roles.

  All are GLOBAL (OrganizationUid NULL) and IsSystemRole = 1, so the role
  editor can refuse to let a school rename or delete SCHOOL_OWNER out from
  under itself.

  RoleId is IDENTITY here, unlike the masters — a school can create custom
  roles, so ids are allocated rather than assigned. The MERGE therefore keys on
  RoleCode, which is the stable identifier. Application code matches on
  RoleCode (AppConstants.RoleCodes), never on RoleId.

  Re-runnable.
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

MERGE dbo.t_sso_roles AS tgt
USING (VALUES
        -- Admin roles (UserTypeId 1)
        ('SUPER_ADMIN',         N'Super administrator',        1),
        ('VERIFICATION_ADMIN',  N'Verification administrator', 1),
        ('MODERATION_ADMIN',    N'Moderation administrator',   1),

        -- School roles (UserTypeId 2)
        ('SCHOOL_OWNER',        N'School owner',               2),
        ('SENIOR_HR',           N'Senior HR',                  2),
        ('HR',                  N'HR',                         2),
        ('SCHOOL_VIEWER',       N'School viewer',              2),

        -- Teacher role (UserTypeId 3)
        ('TEACHER',             N'Teacher',                    3)
      ) AS src (RoleCode, RoleName, UserTypeId)
    -- Matched on the global row only: a school's custom role must never be
    -- overwritten just because it picked a colliding code.
    ON tgt.RoleCode = src.RoleCode
   AND tgt.OrganizationUid IS NULL
   AND tgt.Is_Deleted = 0
WHEN MATCHED AND (tgt.RoleName <> src.RoleName OR tgt.UserTypeId <> src.UserTypeId OR tgt.IsSystemRole <> 1)
    THEN UPDATE SET tgt.RoleName    = src.RoleName,
                    tgt.UserTypeId  = src.UserTypeId,
                    tgt.IsSystemRole = 1,
                    tgt.ModifiedOn  = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (RoleCode, RoleName, UserTypeId, IsSystemRole, OrganizationUid)
         VALUES (src.RoleCode, src.RoleName, src.UserTypeId, 1, NULL);

PRINT '    t_sso_roles seeded — 8 system roles.';
GO
