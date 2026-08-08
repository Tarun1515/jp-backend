/*==============================================================================
  jp_sso — 002_indexes / 009_ix_t_sso_role_permissions.sql

  The unique index on (RoleId, PermissionId) is in the table script, and it
  already serves every RoleId-leading lookup — including the join in
  USP_GetUserClaims. Only the reverse direction needs an index of its own.
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
  "Which roles grant this permission?"

  Answers the admin question before a permission is retired, and supports the
  foreign key to t_sso_permissions — without it, touching a permission row
  scans this whole bridge table.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_role_permissions_PermissionId' AND object_id = OBJECT_ID('dbo.t_sso_role_permissions'))
BEGIN
    PRINT '    Creating index [IX_t_sso_role_permissions_PermissionId] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_role_permissions_PermissionId
        ON dbo.t_sso_role_permissions (PermissionId)
        INCLUDE (RoleId)
        WHERE Is_Deleted = 0;
END
GO
