/*==============================================================================
  jp_sso — 04_procedures / 008_menus.sql

  USP_GetUserMenus — the navigation a given user is actually allowed to see.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_GetUserMenus

  Returns a FLAT list. Deliberately not a recursive CTE hierarchy:

    - the client has to nest it for rendering anyway, so building a tree in SQL
      means building it twice;
    - a flat list plus ParentMenuId is a single index seek over ~30 rows, where
      a recursive CTE is an anchor plus one recursive pass per level;
    - this runs on every sign-in.

  ----------------------------------------------------------------------------
  WHAT "ALLOWED" MEANS
  ----------------------------------------------------------------------------
  1. UserTypeId matches, or the menu has none (NULL = every user type). This is
     what keeps the teacher portal out of a school's sidebar.
  2. PermissionId IS NULL (open to anyone who got this far), OR the user holds
     that permission through some active role.
  3. Is_Active = 1 AND Is_Deleted = 0, on the menu AND on every row joined
     through to reach it.
  4. Role validity respects ValidFrom / ValidTo against fn_IstToday() — a role
     that expired yesterday must not still be drawing menus (2.28).

  A PARENT SURVIVES IF ANY CHILD DOES. A group node carries no permission of
  its own, so filtering it on its own merits would keep an empty "Verification"
  heading on screen for an admin who can verify nothing. Parents are therefore
  re-checked against their surviving children at the end.

  ----------------------------------------------------------------------------
  ⚠️ THIS IS NOT ACCESS CONTROL
  ----------------------------------------------------------------------------
  This decides what is SHOWN. The route guard on the client and the permission
  check on the server decide what is ALLOWED, and both stay exactly where they
  are (2.6). A hidden menu has never stopped anyone typing a URL.

  t_sso_role_menus is intentionally NOT read here. It exists for a future
  explicit per-role override; in MVP the permission is the single rule.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetUserMenus
    @UserId bigint
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Today date = dbo.fn_IstToday();
    DECLARE @UserTypeId int;

    SELECT @UserTypeId = u.UserTypeId
    FROM dbo.t_sso_users u
    WHERE u.UserId = @UserId AND u.Is_Deleted = 0;

    -- Unknown or deleted user: empty set, not an error. The caller is
    -- authenticated by this point, so this only happens if an account was
    -- removed while its token was still alive — and an empty menu is exactly
    -- the right answer to that.
    IF @UserTypeId IS NULL
    BEGIN
        SELECT TOP (0)
               CAST(NULL AS bigint)        AS MenuId,
               CAST(NULL AS bigint)        AS ParentMenuId,
               CAST(NULL AS varchar(50))   AS MenuCode,
               CAST(NULL AS nvarchar(100)) AS MenuName,
               CAST(NULL AS nvarchar(200)) AS RoutePath,
               CAST(NULL AS varchar(50))   AS IconName,
               CAST(NULL AS varchar(50))   AS PermissionCode,
               CAST(NULL AS int)           AS DisplayOrder,
               CAST(NULL AS bit)           AS IsMenuVisible,
               CAST(NULL AS bit)           AS OpenInNewTab;
        RETURN;
    END

    -- The user's live permission set, resolved once.
    DECLARE @Permissions TABLE (PermissionId int NOT NULL PRIMARY KEY);

    INSERT INTO @Permissions (PermissionId)
    SELECT DISTINCT p.PermissionId
    FROM dbo.t_sso_user_roles ur
    INNER JOIN dbo.t_sso_roles r
            ON r.RoleId = ur.RoleId
           AND r.Is_Deleted = 0 AND r.Is_Active = 1
    INNER JOIN dbo.t_sso_role_permissions rp
            ON rp.RoleId = r.RoleId
           AND rp.Is_Deleted = 0 AND rp.Is_Active = 1
    INNER JOIN dbo.t_sso_permissions p
            ON p.PermissionId = rp.PermissionId
           AND p.Is_Deleted = 0 AND p.Is_Active = 1
    WHERE ur.UserId = @UserId
      AND ur.Is_Deleted = 0 AND ur.Is_Active = 1
      AND ur.ValidFrom <= @Today
      AND (ur.ValidTo IS NULL OR ur.ValidTo >= @Today);

    -- Leaves the user may see.
    DECLARE @Allowed TABLE (MenuId bigint NOT NULL PRIMARY KEY, ParentMenuId bigint NULL);

    INSERT INTO @Allowed (MenuId, ParentMenuId)
    SELECT m.MenuId, m.ParentMenuId
    FROM dbo.m_sso_menus m
    WHERE m.Is_Deleted = 0
      AND m.Is_Active = 1
      AND (m.UserTypeId IS NULL OR m.UserTypeId = @UserTypeId)
      AND m.RoutePath IS NOT NULL          -- leaves only; groups handled below
      AND (m.PermissionId IS NULL
           OR EXISTS (SELECT 1 FROM @Permissions up WHERE up.PermissionId = m.PermissionId));

    /*
      Group nodes: kept only if at least one child survived above. Written as a
      second INSERT rather than folded into the query above because a group's
      own permission tells you nothing — its children's do.
    */
    INSERT INTO @Allowed (MenuId, ParentMenuId)
    SELECT m.MenuId, m.ParentMenuId
    FROM dbo.m_sso_menus m
    WHERE m.Is_Deleted = 0
      AND m.Is_Active = 1
      AND (m.UserTypeId IS NULL OR m.UserTypeId = @UserTypeId)
      AND m.RoutePath IS NULL
      AND EXISTS (SELECT 1 FROM @Allowed a WHERE a.ParentMenuId = m.MenuId)
      AND NOT EXISTS (SELECT 1 FROM @Allowed a WHERE a.MenuId = m.MenuId);

    /*
      ParentMenuId first, so a client that renders in order gets top-level
      items before the children that hang off them. NULLs sort first in SQL
      Server, which is what we want — the roots.

      IsMenuVisible is returned rather than filtered on: the client uses this
      same list twice, once to draw the sidebar (visible rows) and once to
      decide whether a route may be opened at all (every row).
    */
    SELECT m.MenuId,
           m.ParentMenuId,
           m.MenuCode,
           m.MenuName,
           m.RoutePath,
           m.IconName,
           p.PermissionCode,
           m.DisplayOrder,
           m.IsMenuVisible,
           m.OpenInNewTab
    FROM dbo.m_sso_menus m
    INNER JOIN @Allowed a ON a.MenuId = m.MenuId
    LEFT JOIN dbo.t_sso_permissions p ON p.PermissionId = m.PermissionId
    ORDER BY m.ParentMenuId, m.DisplayOrder, m.MenuId;
END
GO

PRINT '  008_menus.sql done.';
GO
