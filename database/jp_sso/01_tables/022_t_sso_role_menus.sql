/*==============================================================================
  jp_sso — 022_t_sso_role_menus.sql

  Per-role menu override. CREATED NOW, DELIBERATELY UNUSED IN MVP.

  USP_GetUserMenus does not read this table. In MVP a menu is visible when the
  user holds the permission attached to it, full stop — that keeps one rule in
  one place, and a school inventing a custom role automatically gets the right
  navigation without anyone touching menu data.

  The table exists now because it is cheap to create and expensive to retrofit:
  adding it later means a migration on a live database plus a rewrite of the
  proc. Empty, it costs nothing.

  WHEN IT IS TURNED ON, THE RULE IS:
      permission filtering decides the default;
      a row here with IsAllowed = 0 removes an item the permission would allow;
      a row with IsAllowed = 1 adds one it would not.
  Deny must win over allow, or the override is not an override.

  ⚠️ Whenever it does get wired up: this hides or shows a LINK. It is not
  access control. The route guard and the server's permission check stay
  exactly where they are (2.6).

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_sso_role_menus' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_sso_role_menus] ...';

    CREATE TABLE dbo.t_sso_role_menus
    (
        RoleMenuId      bigint          NOT NULL IDENTITY(1,1),
        RoleId          int             NOT NULL,
        MenuId          bigint          NOT NULL,

        -- 1 = show even without the permission, 0 = hide even with it.
        IsAllowed       bit             NOT NULL CONSTRAINT DF_t_sso_role_menus_IsAllowed DEFAULT (1),

        Is_Active       tinyint         NOT NULL CONSTRAINT DF_t_sso_role_menus_Is_Active  DEFAULT (1),
        Is_Deleted      tinyint         NOT NULL CONSTRAINT DF_t_sso_role_menus_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2       NOT NULL CONSTRAINT DF_t_sso_role_menus_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint          NULL,
        ModifiedOn      datetime2       NULL,
        ModifiedBy      bigint          NULL,

        CONSTRAINT PK_t_sso_role_menus PRIMARY KEY CLUSTERED (RoleMenuId),

        CONSTRAINT FK_t_sso_role_menus_Role FOREIGN KEY (RoleId) REFERENCES dbo.t_sso_roles (RoleId),
        CONSTRAINT FK_t_sso_role_menus_Menu FOREIGN KEY (MenuId) REFERENCES dbo.m_sso_menus (MenuId),

        CONSTRAINT CK_t_sso_role_menus_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_sso_role_menus_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );

END
ELSE
BEGIN
    PRINT '    Table [t_sso_role_menus] already exists - skipped.';
END
GO

-- One decision per role per menu. Two contradictory rows would make the
-- override non-deterministic, which is worse than having no override.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_sso_role_menus_RoleId_MenuId' AND object_id = OBJECT_ID('dbo.t_sso_role_menus'))
BEGIN
    PRINT '    Creating index [UQ_t_sso_role_menus_RoleId_MenuId] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_sso_role_menus_RoleId_MenuId
        ON dbo.t_sso_role_menus (RoleId, MenuId)
        WHERE Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_role_menus_MenuId' AND object_id = OBJECT_ID('dbo.t_sso_role_menus'))
BEGIN
    PRINT '    Creating index [IX_t_sso_role_menus_MenuId] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_role_menus_MenuId
        ON dbo.t_sso_role_menus (MenuId)
        INCLUDE (RoleId, IsAllowed)
        WHERE Is_Deleted = 0;
END
GO

PRINT '  022_t_sso_role_menus.sql done.';
GO
