/*==============================================================================
  jp_sso — 03_seed / 005_seed_menus.sql

  The portal navigation tree, for all three user types.

  ----------------------------------------------------------------------------
  SOURCE OF TRUTH
  ----------------------------------------------------------------------------
  Every RoutePath below is a route that exists in ONE of the three apps:

      UserTypeId 1  ->  frontend/apps/admin/src/app/app.routes.ts
      UserTypeId 2  ->  frontend/apps/school/src/app/app.routes.ts
      UserTypeId 3  ->  frontend/apps/teacher/src/app/app.routes.ts
      UserTypeId NULL -> the shared account screens, in every app that has them

  ⚠️ THE PATHS CARRY NO APP PREFIX. They used to read /admin/dashboard,
  /school/dashboard, /teacher/dashboard, because one application served all
  three audiences under one origin. Each app now has its own deployment, so the
  prefix would only repeat the hostname — admin.staffroom.in/admin/dashboard.

  A consequence worth stating plainly: three rows now legitimately share the
  RoutePath '/dashboard', one per user type. Uniqueness is per
  (UserTypeId, RoutePath), never global, and test 003 asserts exactly that.

  When a route is added to an app, a row is added here in the same commit.
  That is the whole discipline.

  ----------------------------------------------------------------------------
  Is_Active — WHAT IT MEANS HERE
  ----------------------------------------------------------------------------
  Is_Active = 1 : the route is wired in app.routes.ts today. Most of them
                  currently resolve to the shared coming-soon placeholder,
                  which is still a real, reachable page — the navigation
                  structure is the deliverable, the screens land per phase.

  Is_Active = 0 : the screen is committed to in docs/PROJECT_MEMORY.md section
                  3 (scope) but has NO route yet. Seeded now so that shipping
                  it later is an UPDATE, not an INSERT, and so the intended
                  shape is visible from day one.

  ----------------------------------------------------------------------------
  PermissionId
  ----------------------------------------------------------------------------
  Resolved by PermissionCode, never hardcoded as an id — the permissions table
  uses IDENTITY, so ids are allocation order and are not stable across a
  rebuild. NULL means "no permission required": dashboards and notifications
  belong to everyone who reached that portal at all.

  ⚠️ Two menus deliberately DIFFER from the hardcoded arrays they replace:

    /branches  was  roles: [SCHOOL_OWNER]   ->  now BRANCH.MANAGE
        BRANCH.MANAGE is granted only to SCHOOL_OWNER, so the visible result is
        identical today. Driving it from the permission means a school's custom
        role that includes BRANCH.MANAGE gets the menu automatically, which is
        the entire reason school roles are permission bundles (2.9).

    /notifications  had no filter  ->  still none. Kept explicit.

  Re-runnable. Keyed on MenuCode.
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

SET NOCOUNT ON;
GO

/*------------------------------------------------------------------------------
  Pass 1 — every node, parents included, with the parent stated as a CODE.

  Two passes rather than one because ParentMenuId is an IDENTITY value that
  does not exist until the parent row has been written. Resolving the code to
  an id in pass 2 keeps this file readable and keeps it re-runnable: nothing
  here depends on what the identity counter happened to be last time.
------------------------------------------------------------------------------*/
DECLARE @src TABLE
(
    MenuCode        varchar(50)     NOT NULL PRIMARY KEY,
    ParentCode      varchar(50)     NULL,
    MenuName        nvarchar(100)   NOT NULL,
    UserTypeId      int             NULL,
    RoutePath       nvarchar(200)   NULL,
    IconName        varchar(50)     NULL,
    PermissionCode  varchar(50)     NULL,
    DisplayOrder    int             NOT NULL,
    IsMenuVisible   bit             NOT NULL,
    Is_Active       tinyint         NOT NULL
);

INSERT INTO @src
    (MenuCode, ParentCode, MenuName, UserTypeId, RoutePath, IconName, PermissionCode, DisplayOrder, IsMenuVisible, Is_Active)
VALUES
-- =============================================================================
-- Shared — every user type. Reachable while PENDING, which is the point:
-- these are the only screens an unapproved school can open (2.9).
-- IsMenuVisible = 0 because they render outside the portal shell and have no
-- sidebar entry; they are here so the client can still permission-check them.
-- =============================================================================
-- DisplayOrder 900+ on purpose: these are UserTypeId NULL, so they appear in
-- every user's list. A low order would interleave them with that portal's own
-- items and, although IsMenuVisible = 0 keeps them out of the sidebar, it
-- would scramble the ordering of anything a client renders unfiltered.
('ACCOUNT_STATUS',          NULL, N'Account status',        NULL, N'/account/status',    'shield-check',  NULL, 900, 0, 1),
('ACCOUNT_DOCUMENTS',       NULL, N'My documents',          NULL, N'/account/documents', 'file-text',     NULL, 910, 0, 1),

-- =============================================================================
-- ADMIN CONSOLE (UserTypeId 1)
-- =============================================================================
('ADMIN_DASHBOARD',         NULL, N'Dashboard',             1, N'/dashboard',             'layout-dashboard', NULL,                  10, 1, 1),

-- Group node: no route of its own, children carry the links.
('ADMIN_VERIFICATION',      NULL, N'Verification',          1, NULL,                            'badge-check',      NULL,                  20, 1, 1),
('ADMIN_VERIFY_SCHOOLS',    'ADMIN_VERIFICATION', N'Schools',  1, N'/verification/schools',  'school',        'VERIFICATION.SCHOOL', 10, 1, 1),
('ADMIN_VERIFY_TEACHERS',   'ADMIN_VERIFICATION', N'Teachers', 1, N'/verification/teachers', 'graduation-cap','VERIFICATION.TEACHER',20, 1, 1),

('ADMIN_MODERATION',        NULL, N'Moderation',            1, NULL,                            'gavel',            NULL,                  30, 1, 1),
('ADMIN_MODERATE_JOBS',     'ADMIN_MODERATION', N'Jobs',       1, N'/moderation/jobs',       'briefcase',     'MODERATION.JOB',      10, 1, 1),
('ADMIN_MODERATE_REPORTS',  'ADMIN_MODERATION', N'Reports',    1, N'/moderation/reports',    'flag',          'MODERATION.REPORT',   20, 1, 1),

('ADMIN_USERS',             NULL, N'Users',                 1, N'/users',                 'users',            'USER.MANAGE',         40, 1, 1),
('ADMIN_MASTERS',           NULL, N'Master data',           1, N'/masters',               'database',         'SETTINGS.MANAGE',     50, 1, 1),
('ADMIN_CMS',               NULL, N'CMS',                   1, N'/cms',                   'newspaper',        'CMS.MANAGE',          60, 1, 1),
('ADMIN_REPORTS',           NULL, N'Analytics',             1, N'/reports',               'bar-chart-3',      'REPORT.VIEW',         70, 1, 1),
('ADMIN_SETTINGS',          NULL, N'Settings',              1, N'/settings',              'settings',         'SETTINGS.MANAGE',     80, 1, 1),

-- =============================================================================
-- SCHOOL PORTAL (UserTypeId 2)
-- =============================================================================
('SCHOOL_DASHBOARD',        NULL, N'Dashboard',             2, N'/dashboard',            'layout-dashboard', NULL,                  10, 1, 1),
('SCHOOL_PROFILE',          NULL, N'School profile',        2, N'/profile',              'building-2',       'PROFILE.EDIT',        20, 1, 1),
-- ⚠️ "Campuses", not "Branches". The screen, its copy and the school's own
-- vocabulary all say campus; a sidebar saying something else is one more word
-- for the same thing. The ROUTE stays /branches — renaming it would break every
-- saved link for a label change (3F).
('SCHOOL_BRANCHES',         NULL, N'Campuses',              2, N'/branches',             'map-pin',          'BRANCH.MANAGE',       30, 1, 1),
('SCHOOL_JOBS',             NULL, N'Jobs',                  2, N'/jobs',                 'briefcase',        'JOB.VIEW',            40, 1, 1),
-- 🔴 HIDDEN UNTIL PHASE 5 (3I). IsMenuVisible = 0.
--
-- /applicants was a STATIC MOCKUP — fifty rows out of a fixture file with no
-- HTTP call, and one of the two screens that looked the most finished (G6). 3I
-- removed its route; the component survives under _design-reference/ as the
-- design for Phase 5.
--
-- ⚠️ The menu row is data (2.37), so leaving it visible would put a sidebar
-- entry in front of every school that leads to a 404. It comes back the day
-- applications exist — which is why the row stays here rather than being
-- deleted: its permission, order and icon are already settled.
('SCHOOL_APPLICANTS',       NULL, N'Applicants',            2, N'/applicants',           'user-check',       'APPLICANT.VIEW',      50, 0, 1),
('SCHOOL_TEACHER_SEARCH',   NULL, N'Find teachers',         2, N'/teacher-search',       'search',           'TEACHER_SEARCH.VIEW', 60, 1, 1),
('SCHOOL_OFFERS',           NULL, N'Offers',                2, N'/offers',               'file-signature',   'OFFER.CREATE',        70, 1, 1),
('SCHOOL_USERS',            NULL, N'Team',                  2, N'/users',                'users',            'USER.MANAGE',         80, 1, 1),
('SCHOOL_NOTIFICATIONS',    NULL, N'Notifications',         2, N'/notifications',        'bell',             NULL,                  90, 1, 1),

-- Committed in scope (Reports/dashboard), no route yet -> inactive.
('SCHOOL_REPORTS',          NULL, N'Reports',               2, N'/reports',              'bar-chart-3',      'REPORT.VIEW',        100, 1, 0),

-- =============================================================================
-- TEACHER PORTAL (UserTypeId 3)
-- =============================================================================
('TEACHER_DASHBOARD',       NULL, N'Dashboard',             3, N'/dashboard',           'layout-dashboard', NULL,                  10, 1, 1),
('TEACHER_PROFILE',         NULL, N'My profile',            3, N'/profile',             'user',             'PROFILE.EDIT',        20, 1, 1),
('TEACHER_JOBS',            NULL, N'Find jobs',             3, N'/jobs',                'search',           'JOB.VIEW',            30, 1, 1),
('TEACHER_APPLICATIONS',    NULL, N'My applications',       3, N'/applications',        'send',             NULL,                  40, 1, 1),
('TEACHER_SAVED_JOBS',      NULL, N'Saved jobs',            3, N'/saved-jobs',          'bookmark',         NULL,                  50, 1, 1),
('TEACHER_INVITATIONS',     NULL, N'Invitations',           3, N'/invitations',         'mail',             NULL,                  60, 1, 1),
('TEACHER_DOCUMENTS',       NULL, N'Documents',             3, N'/documents',           'file-text',        NULL,                  70, 1, 1),
('TEACHER_NOTIFICATIONS',   NULL, N'Notifications',         3, N'/notifications',       'bell',             NULL,                  80, 1, 1);


/*------------------------------------------------------------------------------
  Sanity check BEFORE writing anything.

  A typo in a PermissionCode would otherwise land as PermissionId NULL, which
  reads as "no permission required" — i.e. a misspelling would make an item
  visible to EVERYONE. That failure is silent and in the wrong direction, so it
  is caught here instead.
------------------------------------------------------------------------------*/
IF EXISTS (SELECT 1 FROM @src s
           WHERE s.PermissionCode IS NOT NULL
             AND NOT EXISTS (SELECT 1 FROM dbo.t_sso_permissions p
                             WHERE p.PermissionCode = s.PermissionCode AND p.Is_Deleted = 0))
BEGIN
    DECLARE @bad nvarchar(1000) = (
        SELECT STUFF((SELECT ', ' + s.PermissionCode FROM @src s
                      WHERE s.PermissionCode IS NOT NULL
                        AND NOT EXISTS (SELECT 1 FROM dbo.t_sso_permissions p
                                        WHERE p.PermissionCode = s.PermissionCode AND p.Is_Deleted = 0)
                      FOR XML PATH('')), 1, 2, ''));

    RAISERROR('005_seed_menus: unknown PermissionCode(s): %s. Run 003_seed_permissions.sql first.', 16, 1, @bad);
    RETURN;
END


/*------------------------------------------------------------------------------
  Pass 1 — upsert the rows themselves, parent left NULL for now.

  NOTE: no GO between the DECLARE of @src above and its last use below. A table
  variable does not survive a batch separator, so a GO here would leave @src
  undeclared and the MERGE would fail to compile.
------------------------------------------------------------------------------*/
;WITH src AS
(
    SELECT s.MenuCode, s.MenuName, s.UserTypeId, s.RoutePath, s.IconName,
           s.DisplayOrder, s.IsMenuVisible, s.Is_Active,
           PermissionId = p.PermissionId
    FROM @src s
    LEFT JOIN dbo.t_sso_permissions p
           ON p.PermissionCode = s.PermissionCode AND p.Is_Deleted = 0
)
MERGE dbo.m_sso_menus AS tgt
USING src ON tgt.MenuCode = src.MenuCode AND tgt.Is_Deleted = 0
WHEN MATCHED AND (
        ISNULL(tgt.MenuName, N'')      <> ISNULL(src.MenuName, N'')
     OR ISNULL(tgt.UserTypeId, -1)     <> ISNULL(src.UserTypeId, -1)
     OR ISNULL(tgt.RoutePath, N'')     <> ISNULL(src.RoutePath, N'')
     OR ISNULL(tgt.IconName, '')       <> ISNULL(src.IconName, '')
     OR ISNULL(tgt.PermissionId, -1)   <> ISNULL(src.PermissionId, -1)
     OR tgt.DisplayOrder               <> src.DisplayOrder
     OR tgt.IsMenuVisible              <> src.IsMenuVisible
     OR tgt.Is_Active                  <> src.Is_Active)
    THEN UPDATE SET
        MenuName      = src.MenuName,
        UserTypeId    = src.UserTypeId,
        RoutePath     = src.RoutePath,
        IconName      = src.IconName,
        PermissionId  = src.PermissionId,
        DisplayOrder  = src.DisplayOrder,
        IsMenuVisible = src.IsMenuVisible,
        Is_Active     = src.Is_Active,
        ModifiedOn    = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (MenuCode, ParentMenuId, MenuName, UserTypeId, RoutePath, IconName,
                 PermissionId, DisplayOrder, IsMenuVisible, Is_Active)
         VALUES (src.MenuCode, NULL, src.MenuName, src.UserTypeId, src.RoutePath, src.IconName,
                 src.PermissionId, src.DisplayOrder, src.IsMenuVisible, src.Is_Active);

PRINT '    m_sso_menus: pass 1 (nodes) done - ' + CAST(@@ROWCOUNT AS varchar(10)) + ' row(s) affected.';


/*------------------------------------------------------------------------------
  Pass 2 — resolve ParentCode to ParentMenuId now that every row has an id.
------------------------------------------------------------------------------*/
UPDATE m
   SET m.ParentMenuId = parent.MenuId,
       m.ModifiedOn   = SYSUTCDATETIME()
FROM dbo.m_sso_menus m
INNER JOIN @src s        ON s.MenuCode = m.MenuCode
INNER JOIN dbo.m_sso_menus parent
        ON parent.MenuCode = s.ParentCode AND parent.Is_Deleted = 0
WHERE m.Is_Deleted = 0
  AND ISNULL(m.ParentMenuId, -1) <> parent.MenuId;

PRINT '    m_sso_menus: pass 2 (parents) done - ' + CAST(@@ROWCOUNT AS varchar(10)) + ' row(s) affected.';
GO


/*------------------------------------------------------------------------------
  Post-conditions. Cheap, and each one has already been a real bug somewhere.
------------------------------------------------------------------------------*/
IF EXISTS (SELECT 1 FROM dbo.m_sso_menus c
           INNER JOIN dbo.m_sso_menus p ON p.MenuId = c.ParentMenuId
           WHERE c.Is_Deleted = 0 AND p.ParentMenuId IS NOT NULL)
BEGIN
    RAISERROR('005_seed_menus: a menu is nested more than 2 levels deep. The client renders 2.', 16, 1);
END
GO

IF EXISTS (SELECT 1 FROM dbo.m_sso_menus c
           INNER JOIN dbo.m_sso_menus p ON p.MenuId = c.ParentMenuId
           WHERE c.Is_Deleted = 0 AND ISNULL(c.UserTypeId, -1) <> ISNULL(p.UserTypeId, -1))
BEGIN
    RAISERROR('005_seed_menus: a child menu has a different UserTypeId from its parent. The parent would render empty.', 16, 1);
END
GO

DECLARE @total int, @active int, @groups int;

SELECT @total  = COUNT(*),
       @active = SUM(CASE WHEN Is_Active = 1 THEN 1 ELSE 0 END),
       @groups = SUM(CASE WHEN RoutePath IS NULL THEN 1 ELSE 0 END)
FROM dbo.m_sso_menus WHERE Is_Deleted = 0;

PRINT '  005_seed_menus.sql done - ' + CAST(@total AS varchar(10)) + ' menus ('
    + CAST(@active AS varchar(10)) + ' active, '
    + CAST(@groups AS varchar(10)) + ' group nodes).';
GO
