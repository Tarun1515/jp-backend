/*==============================================================================
  jp_sso — 021_m_sso_menus.sql

  Master: the portal navigation tree.

  Menus live in jp_sso, not jp_app, because a menu row is only ever shown when
  the user holds the permission attached to it — and permissions live here. Any
  other home would mean a cross-database join on every sign-in, which 2.2
  forbids outright.

  WHY THIS TABLE EXISTS AT ALL
  ----------------------------
  Navigation was a hardcoded TypeScript array in each of the three layout
  components. That breaks decision 2.7 (no hardcoding), but more practically:
  from Phase 2 onward screens get added constantly, and a frontend build +
  deploy for every menu change is not a workable release process.

  TWO LEVELS ONLY (MVP)
  ---------------------
  ParentMenuId is a self-reference, but nothing here enforces a depth limit —
  the seed keeps it to two levels and the Angular tree builder renders two.
  A CHECK constraint cannot express "my parent has no parent" without a
  scalar function, and a function in a CHECK is evaluated per row on every
  write. If a third level is ever needed the client is where it should be
  caught, loudly, not silently rendered flat.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_sso_menus' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_sso_menus] ...';

    CREATE TABLE dbo.m_sso_menus
    (
        MenuId          bigint          NOT NULL IDENTITY(1,1),
        ParentMenuId    bigint          NULL,
        MenuCode        varchar(50)     NOT NULL,
        MenuName        nvarchar(100)   NOT NULL,

        /*
          NULL = every user type sees it.

          int, NOT tinyint as originally specced: m_sso_user_types.UserTypeId
          is int, and a foreign key column must match the type of the column it
          references. Same story for PermissionId below — t_sso_permissions.
          PermissionId is int, not bigint.
        */
        UserTypeId      int             NULL,

        -- NULL for a group/parent node, which is a heading rather than a link.
        RoutePath       nvarchar(200)   NULL,
        IconName        varchar(50)     NULL,

        -- NULL = no permission required (dashboards, notifications).
        PermissionId    int             NULL,

        DisplayOrder    int             NOT NULL CONSTRAINT DF_m_sso_menus_DisplayOrder DEFAULT (0),

        /*
          0 = routable but NOT drawn in the sidebar: detail pages, edit screens,
          modals. They still need a row, because the client uses this same list
          to decide whether a route is permitted at all.
        */
        IsMenuVisible   bit             NOT NULL CONSTRAINT DF_m_sso_menus_IsMenuVisible DEFAULT (1),
        OpenInNewTab    bit             NOT NULL CONSTRAINT DF_m_sso_menus_OpenInNewTab  DEFAULT (0),

        Is_Active       tinyint         NOT NULL CONSTRAINT DF_m_sso_menus_Is_Active  DEFAULT (1),
        Is_Deleted      tinyint         NOT NULL CONSTRAINT DF_m_sso_menus_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2       NOT NULL CONSTRAINT DF_m_sso_menus_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint          NULL,
        ModifiedOn      datetime2       NULL,
        ModifiedBy      bigint          NULL,

        CONSTRAINT PK_m_sso_menus PRIMARY KEY CLUSTERED (MenuId),

        CONSTRAINT FK_m_sso_menus_Parent
            FOREIGN KEY (ParentMenuId) REFERENCES dbo.m_sso_menus (MenuId),
        CONSTRAINT FK_m_sso_menus_UserType
            FOREIGN KEY (UserTypeId) REFERENCES dbo.m_sso_user_types (UserTypeId),
        CONSTRAINT FK_m_sso_menus_Permission
            FOREIGN KEY (PermissionId) REFERENCES dbo.t_sso_permissions (PermissionId),

        -- A node cannot be its own parent. Deeper cycles are not reachable
        -- through the seed and are not worth a trigger to prevent.
        CONSTRAINT CK_m_sso_menus_NotOwnParent CHECK (ParentMenuId IS NULL OR ParentMenuId <> MenuId),

        -- A leaf needs somewhere to go. A group node deliberately has no route.
        CONSTRAINT CK_m_sso_menus_LeafHasRoute
            CHECK (RoutePath IS NOT NULL OR ParentMenuId IS NULL),

        CONSTRAINT CK_m_sso_menus_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_m_sso_menus_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );

END
ELSE
BEGIN
    PRINT '    Table [m_sso_menus] already exists - skipped.';
END
GO

-- Each index carries its OWN guard. If the table is created but an index
-- fails, re-running repairs it; one guard around everything would skip the
-- whole block and leave the table permanently un-indexed (learned in 1A).
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_m_sso_menus_MenuCode' AND object_id = OBJECT_ID('dbo.m_sso_menus'))
BEGIN
    PRINT '    Creating index [UQ_m_sso_menus_MenuCode] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_m_sso_menus_MenuCode
        ON dbo.m_sso_menus (MenuCode)
        WHERE Is_Deleted = 0;
END
GO

/*------------------------------------------------------------------------------
  The shape USP_GetUserMenus reads in: scoped to a user type, then ordered.

  UserTypeId leads because every call filters on it. ParentMenuId and
  DisplayOrder follow so the ORDER BY is satisfied by the index rather than by
  a sort — this query runs on every sign-in.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_m_sso_menus_UserTypeId_Parent_Order' AND object_id = OBJECT_ID('dbo.m_sso_menus'))
BEGIN
    PRINT '    Creating index [IX_m_sso_menus_UserTypeId_Parent_Order] ...';

    CREATE NONCLUSTERED INDEX IX_m_sso_menus_UserTypeId_Parent_Order
        ON dbo.m_sso_menus (UserTypeId, ParentMenuId, DisplayOrder)
        INCLUDE (MenuCode, MenuName, RoutePath, IconName, PermissionId, IsMenuVisible, OpenInNewTab)
        WHERE Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_m_sso_menus_PermissionId' AND object_id = OBJECT_ID('dbo.m_sso_menus'))
BEGIN
    PRINT '    Creating index [IX_m_sso_menus_PermissionId] ...';

    CREATE NONCLUSTERED INDEX IX_m_sso_menus_PermissionId
        ON dbo.m_sso_menus (PermissionId)
        WHERE Is_Deleted = 0;
END
GO

PRINT '  021_m_sso_menus.sql done.';
GO
