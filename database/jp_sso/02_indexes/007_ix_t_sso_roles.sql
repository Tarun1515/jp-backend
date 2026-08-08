/*==============================================================================
  jp_sso — 002_indexes / 007_ix_t_sso_roles.sql

  The unique index on (RoleCode, OrganizationUid) is in the table script.
==============================================================================*/

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*------------------------------------------------------------------------------
  "Every role available to this school" — the role picker on the invite screen,
  which must show the global system roles plus that school's own custom ones.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_roles_OrganizationUid' AND object_id = OBJECT_ID('dbo.t_sso_roles'))
BEGIN
    PRINT '    Creating index [IX_t_sso_roles_OrganizationUid] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_roles_OrganizationUid
        ON dbo.t_sso_roles (OrganizationUid)
        INCLUDE (RoleCode, RoleName, UserTypeId, IsSystemRole)
        WHERE Is_Deleted = 0;
END
GO

-- FK support, and "all roles valid for a school user".
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_roles_UserTypeId' AND object_id = OBJECT_ID('dbo.t_sso_roles'))
BEGIN
    PRINT '    Creating index [IX_t_sso_roles_UserTypeId] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_roles_UserTypeId
        ON dbo.t_sso_roles (UserTypeId)
        INCLUDE (RoleCode, RoleName, OrganizationUid)
        WHERE Is_Deleted = 0;
END
GO
