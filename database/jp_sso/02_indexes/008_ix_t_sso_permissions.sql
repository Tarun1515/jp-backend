/*==============================================================================
  jp_sso — 002_indexes / 008_ix_t_sso_permissions.sql

  The unique index on PermissionCode is in the table script.
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
  Permissions grouped by module — how the role editor renders the permission
  matrix, and the FK support for m_sso_modules.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_permissions_ModuleId' AND object_id = OBJECT_ID('dbo.t_sso_permissions'))
BEGIN
    PRINT '    Creating index [IX_t_sso_permissions_ModuleId] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_permissions_ModuleId
        ON dbo.t_sso_permissions (ModuleId, DisplayOrder)
        INCLUDE (PermissionCode, PermissionName)
        WHERE Is_Deleted = 0;
END
GO
