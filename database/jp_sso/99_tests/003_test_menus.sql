/*==============================================================================
  jp_sso — 99_tests / 003_test_menus.sql

  USP_GetUserMenus and the menu seed.

  Everything runs inside ONE transaction which is ALWAYS rolled back, so the
  suite is safe against the real database and leaves nothing behind.

  ⚠️ The assertion log is a TABLE VARIABLE, not a #temp table. Temp tables are
  transactional — the final ROLLBACK would erase the results and the suite
  would report nothing while exiting 0. That was a real bug in test 001.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

SET NOCOUNT ON;
SET XACT_ABORT ON;
GO

DECLARE @results TABLE
(
    Seq       int IDENTITY(1,1),
    Area      varchar(30),
    Assertion nvarchar(200),
    Expected  nvarchar(200),
    Actual    nvarchar(200),
    Passed    bit
);

DECLARE @expected nvarchar(200), @actual nvarchar(200);

BEGIN TRANSACTION;

BEGIN TRY

    /*==========================================================================
      Fixtures. Three users of one type each, plus an HR who holds strictly
      fewer permissions than the owner — that contrast is what proves the
      filtering actually filters.
    ==========================================================================*/
    DECLARE @Hash varbinary(64) = CONVERT(varbinary(64), REPLICATE('h', 64));
    DECLARE @Salt varbinary(32) = CONVERT(varbinary(32), REPLICATE('s', 32));
    DECLARE @Today date = dbo.fn_IstToday();

    DECLARE @AdminId bigint, @OwnerId bigint, @HrId bigint, @TeacherId bigint, @NoRoleId bigint;
    DECLARE @OrgUid uniqueidentifier = NEWID();

    INSERT INTO dbo.t_sso_users (UserUid, UserTypeId, StatusId, Email, OrganizationUid, IsEmailVerified)
    VALUES (NEWID(), 1, 2, N'menutest.admin@test.local', NULL, 1);
    SET @AdminId = SCOPE_IDENTITY();

    INSERT INTO dbo.t_sso_users (UserUid, UserTypeId, StatusId, Email, OrganizationUid, IsEmailVerified)
    VALUES (NEWID(), 2, 2, N'menutest.owner@test.local', @OrgUid, 1);
    SET @OwnerId = SCOPE_IDENTITY();

    INSERT INTO dbo.t_sso_users (UserUid, UserTypeId, StatusId, Email, OrganizationUid, IsEmailVerified)
    VALUES (NEWID(), 2, 2, N'menutest.hr@test.local', @OrgUid, 1);
    SET @HrId = SCOPE_IDENTITY();

    INSERT INTO dbo.t_sso_users (UserUid, UserTypeId, StatusId, Email, OrganizationUid, IsEmailVerified)
    VALUES (NEWID(), 3, 2, N'menutest.teacher@test.local', NULL, 1);
    SET @TeacherId = SCOPE_IDENTITY();

    -- A school user with NO role at all: an invited account before anyone
    -- assigned them anything.
    INSERT INTO dbo.t_sso_users (UserUid, UserTypeId, StatusId, Email, OrganizationUid, IsEmailVerified)
    VALUES (NEWID(), 2, 2, N'menutest.norole@test.local', @OrgUid, 1);
    SET @NoRoleId = SCOPE_IDENTITY();

    INSERT INTO dbo.t_sso_user_roles (UserId, RoleId, OrganizationUid, ValidFrom)
    SELECT @AdminId, RoleId, NULL, @Today FROM dbo.t_sso_roles WHERE RoleCode = 'SUPER_ADMIN' AND OrganizationUid IS NULL;

    INSERT INTO dbo.t_sso_user_roles (UserId, RoleId, OrganizationUid, ValidFrom)
    SELECT @OwnerId, RoleId, @OrgUid, @Today FROM dbo.t_sso_roles WHERE RoleCode = 'SCHOOL_OWNER' AND OrganizationUid IS NULL;

    INSERT INTO dbo.t_sso_user_roles (UserId, RoleId, OrganizationUid, ValidFrom)
    SELECT @HrId, RoleId, @OrgUid, @Today FROM dbo.t_sso_roles WHERE RoleCode = 'HR' AND OrganizationUid IS NULL;

    INSERT INTO dbo.t_sso_user_roles (UserId, RoleId, OrganizationUid, ValidFrom)
    SELECT @TeacherId, RoleId, NULL, @Today FROM dbo.t_sso_roles WHERE RoleCode = 'TEACHER' AND OrganizationUid IS NULL;


    /*==========================================================================
      SEED shape
    ==========================================================================*/
    DECLARE @menuCount int = (SELECT COUNT(*) FROM dbo.m_sso_menus WHERE Is_Deleted = 0);

    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    SELECT '[seed]', N'menu rows exist', N'> 0', CAST(@menuCount AS nvarchar(20)),
           CASE WHEN @menuCount > 0 THEN 1 ELSE 0 END;

    -- A misspelled PermissionCode in the seed lands as NULL, which reads as
    -- "no permission required" — i.e. it would make an item visible to
    -- EVERYONE. Every menu that names a module action must have resolved.
    SET @actual = CAST((SELECT COUNT(*) FROM dbo.m_sso_menus m
                        WHERE m.Is_Deleted = 0 AND m.PermissionId IS NOT NULL
                          AND NOT EXISTS (SELECT 1 FROM dbo.t_sso_permissions p
                                          WHERE p.PermissionId = m.PermissionId AND p.Is_Deleted = 0)) AS nvarchar(20));
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[seed]', N'every PermissionId resolves to a live permission', N'0', @actual, CASE WHEN @actual = N'0' THEN 1 ELSE 0 END);

    SET @actual = CAST((SELECT COUNT(*) FROM dbo.m_sso_menus c
                        INNER JOIN dbo.m_sso_menus p ON p.MenuId = c.ParentMenuId
                        WHERE c.Is_Deleted = 0 AND p.ParentMenuId IS NOT NULL) AS nvarchar(20));
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[seed]', N'nothing nested deeper than 2 levels', N'0', @actual, CASE WHEN @actual = N'0' THEN 1 ELSE 0 END);

    SET @actual = CAST((SELECT COUNT(*) FROM dbo.m_sso_menus c
                        INNER JOIN dbo.m_sso_menus p ON p.MenuId = c.ParentMenuId
                        WHERE c.Is_Deleted = 0 AND ISNULL(c.UserTypeId, -1) <> ISNULL(p.UserTypeId, -1)) AS nvarchar(20));
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[seed]', N'child UserTypeId matches its parent', N'0', @actual, CASE WHEN @actual = N'0' THEN 1 ELSE 0 END);

    /*
      Two rows pointing at the same route WITHIN ONE USER TYPE is how a menu
      ends up rendered twice.

      Deliberately scoped to (UserTypeId, RoutePath) rather than to RoutePath
      alone. Since the three apps were split apart the paths carry no /admin,
      /school or /teacher prefix, so '/dashboard' legitimately appears three
      times — once per app. A global uniqueness check would now fail on
      correct data, which is the worst kind of test.
    */
    SET @actual = CAST((SELECT COUNT(*) FROM (SELECT UserTypeId, RoutePath FROM dbo.m_sso_menus
                                              WHERE Is_Deleted = 0 AND RoutePath IS NOT NULL
                                              GROUP BY UserTypeId, RoutePath HAVING COUNT(*) > 1) d) AS nvarchar(20));
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[seed]', N'no duplicate RoutePath within a user type', N'0', @actual, CASE WHEN @actual = N'0' THEN 1 ELSE 0 END);

    -- The corollary, asserted so the split cannot silently regress: the same
    -- path IS expected across user types, and each app only ever sees its own.
    SET @actual = CAST((SELECT COUNT(*) FROM (SELECT RoutePath FROM dbo.m_sso_menus
                                              WHERE Is_Deleted = 0 AND RoutePath IS NOT NULL AND UserTypeId IS NOT NULL
                                              GROUP BY RoutePath HAVING COUNT(DISTINCT UserTypeId) > 1) d) AS nvarchar(20));
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[seed]', N'shared paths across apps are expected (e.g. /dashboard)', N'> 0', @actual,
            CASE WHEN CAST(@actual AS int) > 0 THEN 1 ELSE 0 END);

    -- Every route must start with '/' — the Angular router treats a relative
    -- path as relative to the CURRENT route, so a missing slash produces a
    -- link that works from the dashboard and 404s from anywhere else.
    SET @actual = CAST((SELECT COUNT(*) FROM dbo.m_sso_menus
                        WHERE Is_Deleted = 0 AND RoutePath IS NOT NULL AND LEFT(RoutePath, 1) <> N'/') AS nvarchar(20));
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[seed]', N'every RoutePath is absolute', N'0', @actual, CASE WHEN @actual = N'0' THEN 1 ELSE 0 END);


    /*==========================================================================
      FILTERING — user type
    ==========================================================================*/
    DECLARE @menus TABLE
    (
        MenuId bigint, ParentMenuId bigint, MenuCode varchar(50), MenuName nvarchar(100),
        RoutePath nvarchar(200), IconName varchar(50), PermissionCode varchar(50),
        DisplayOrder int, IsMenuVisible bit, OpenInNewTab bit
    );

    DELETE FROM @menus;
    INSERT INTO @menus EXEC dbo.USP_GetUserMenus @AdminId;

    SET @actual = CAST((SELECT COUNT(*) FROM @menus WHERE MenuCode LIKE 'SCHOOL[_]%' OR MenuCode LIKE 'TEACHER[_]%') AS nvarchar(20));
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[usertype]', N'admin sees no school or teacher menus', N'0', @actual, CASE WHEN @actual = N'0' THEN 1 ELSE 0 END);

    SET @actual = CASE WHEN EXISTS (SELECT 1 FROM @menus WHERE MenuCode = 'ADMIN_DASHBOARD') THEN N'yes' ELSE N'no' END;
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[usertype]', N'admin sees the admin dashboard', N'yes', @actual, CASE WHEN @actual = N'yes' THEN 1 ELSE 0 END);

    DELETE FROM @menus;
    INSERT INTO @menus EXEC dbo.USP_GetUserMenus @TeacherId;

    SET @actual = CAST((SELECT COUNT(*) FROM @menus WHERE MenuCode LIKE 'ADMIN[_]%' OR MenuCode LIKE 'SCHOOL[_]%') AS nvarchar(20));
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[usertype]', N'teacher sees no admin or school menus', N'0', @actual, CASE WHEN @actual = N'0' THEN 1 ELSE 0 END);

    -- UserTypeId NULL means "everyone". The account pages are the reason that
    -- exists, and a pending school reaching them is decision 2.9.
    SET @actual = CASE WHEN EXISTS (SELECT 1 FROM @menus WHERE MenuCode = 'ACCOUNT_STATUS') THEN N'yes' ELSE N'no' END;
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[usertype]', N'shared (UserTypeId NULL) menus reach a teacher', N'yes', @actual, CASE WHEN @actual = N'yes' THEN 1 ELSE 0 END);


    /*==========================================================================
      FILTERING — permission
    ==========================================================================*/
    DECLARE @ownerCount int, @hrCount int;

    DELETE FROM @menus;
    INSERT INTO @menus EXEC dbo.USP_GetUserMenus @OwnerId;
    SET @ownerCount = (SELECT COUNT(*) FROM @menus);

    SET @actual = CASE WHEN EXISTS (SELECT 1 FROM @menus WHERE MenuCode = 'SCHOOL_BRANCHES') THEN N'yes' ELSE N'no' END;
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[permission]', N'owner holds BRANCH.MANAGE so sees Branches', N'yes', @actual, CASE WHEN @actual = N'yes' THEN 1 ELSE 0 END);

    SET @actual = CASE WHEN EXISTS (SELECT 1 FROM @menus WHERE MenuCode = 'SCHOOL_USERS') THEN N'yes' ELSE N'no' END;
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[permission]', N'owner holds USER.MANAGE so sees Team', N'yes', @actual, CASE WHEN @actual = N'yes' THEN 1 ELSE 0 END);

    DELETE FROM @menus;
    INSERT INTO @menus EXEC dbo.USP_GetUserMenus @HrId;
    SET @hrCount = (SELECT COUNT(*) FROM @menus);

    SET @actual = CASE WHEN EXISTS (SELECT 1 FROM @menus WHERE MenuCode = 'SCHOOL_BRANCHES') THEN N'yes' ELSE N'no' END;
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[permission]', N'HR lacks BRANCH.MANAGE so no Branches', N'no', @actual, CASE WHEN @actual = N'no' THEN 1 ELSE 0 END);

    SET @actual = CASE WHEN EXISTS (SELECT 1 FROM @menus WHERE MenuCode = 'SCHOOL_USERS') THEN N'yes' ELSE N'no' END;
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[permission]', N'HR lacks USER.MANAGE so no Team', N'no', @actual, CASE WHEN @actual = N'no' THEN 1 ELSE 0 END);

    -- Dashboard has PermissionId NULL, so it must survive for both.
    SET @actual = CASE WHEN EXISTS (SELECT 1 FROM @menus WHERE MenuCode = 'SCHOOL_DASHBOARD') THEN N'yes' ELSE N'no' END;
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[permission]', N'PermissionId NULL menu shown without any grant', N'yes', @actual, CASE WHEN @actual = N'yes' THEN 1 ELSE 0 END);

    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    SELECT '[permission]', N'HR sees strictly fewer menus than the owner',
           N'hr < owner', CAST(@hrCount AS nvarchar(10)) + N' < ' + CAST(@ownerCount AS nvarchar(10)),
           CASE WHEN @hrCount < @ownerCount THEN 1 ELSE 0 END;

    -- A user with no role holds no permissions, so only the unrestricted rows
    -- survive. Not zero rows — the dashboard and account pages remain.
    DELETE FROM @menus;
    INSERT INTO @menus EXEC dbo.USP_GetUserMenus @NoRoleId;

    SET @actual = CAST((SELECT COUNT(*) FROM @menus WHERE PermissionCode IS NOT NULL) AS nvarchar(20));
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[permission]', N'user with no role gets no permission-gated menu', N'0', @actual, CASE WHEN @actual = N'0' THEN 1 ELSE 0 END);


    /*==========================================================================
      GROUP NODES
    ==========================================================================*/
    DELETE FROM @menus;
    INSERT INTO @menus EXEC dbo.USP_GetUserMenus @AdminId;

    SET @actual = CASE WHEN EXISTS (SELECT 1 FROM @menus WHERE MenuCode = 'ADMIN_VERIFICATION') THEN N'yes' ELSE N'no' END;
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[group]', N'group node kept while it has surviving children', N'yes', @actual, CASE WHEN @actual = N'yes' THEN 1 ELSE 0 END);

    -- Every child must arrive with its parent, or the client cannot nest it
    -- and the item silently disappears from the rendered tree.
    SET @actual = CAST((SELECT COUNT(*) FROM @menus c
                        WHERE c.ParentMenuId IS NOT NULL
                          AND NOT EXISTS (SELECT 1 FROM @menus p WHERE p.MenuId = c.ParentMenuId)) AS nvarchar(20));
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[group]', N'no orphan child (parent always present)', N'0', @actual, CASE WHEN @actual = N'0' THEN 1 ELSE 0 END);

    /*
      THE ONE THAT MATTERS: strip the children's permissions and the empty
      heading must go with them. A group node carries no permission of its own,
      so filtering it on its own merits would leave "Verification" on screen
      for an admin who can verify nothing.
    */
    UPDATE dbo.t_sso_user_roles SET Is_Active = 0 WHERE UserId = @AdminId;

    DELETE FROM @menus;
    INSERT INTO @menus EXEC dbo.USP_GetUserMenus @AdminId;

    SET @actual = CASE WHEN EXISTS (SELECT 1 FROM @menus WHERE MenuCode = 'ADMIN_VERIFICATION') THEN N'yes' ELSE N'no' END;
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[group]', N'THE FIX: group node dropped when every child is filtered out', N'no', @actual, CASE WHEN @actual = N'no' THEN 1 ELSE 0 END);

    UPDATE dbo.t_sso_user_roles SET Is_Active = 1 WHERE UserId = @AdminId;


    /*==========================================================================
      ROLE VALIDITY (2.28) — an expired role must stop drawing menus
    ==========================================================================*/
    -- Both ends move. CK_t_sso_user_roles_ValidRange requires ValidTo >= ValidFrom,
    -- so setting only ValidTo to yesterday is rejected by the constraint — the
    -- constraint is right and the naive test was wrong (same trap as test 001).
    UPDATE dbo.t_sso_user_roles
       SET ValidFrom = DATEADD(day, -10, @Today), ValidTo = DATEADD(day, -1, @Today)
     WHERE UserId = @OwnerId;

    DELETE FROM @menus;
    INSERT INTO @menus EXEC dbo.USP_GetUserMenus @OwnerId;

    SET @actual = CAST((SELECT COUNT(*) FROM @menus WHERE PermissionCode IS NOT NULL) AS nvarchar(20));
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[validity]', N'role that expired yesterday grants no menu', N'0', @actual, CASE WHEN @actual = N'0' THEN 1 ELSE 0 END);

    UPDATE dbo.t_sso_user_roles SET ValidFrom = DATEADD(day, 1, @Today), ValidTo = NULL WHERE UserId = @OwnerId;

    DELETE FROM @menus;
    INSERT INTO @menus EXEC dbo.USP_GetUserMenus @OwnerId;

    SET @actual = CAST((SELECT COUNT(*) FROM @menus WHERE PermissionCode IS NOT NULL) AS nvarchar(20));
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[validity]', N'role starting tomorrow grants no menu yet', N'0', @actual, CASE WHEN @actual = N'0' THEN 1 ELSE 0 END);

    UPDATE dbo.t_sso_user_roles SET ValidFrom = @Today, ValidTo = NULL WHERE UserId = @OwnerId;


    /*==========================================================================
      Is_Active / soft delete
    ==========================================================================*/
    DELETE FROM @menus;
    INSERT INTO @menus EXEC dbo.USP_GetUserMenus @OwnerId;

    SET @actual = CASE WHEN EXISTS (SELECT 1 FROM @menus WHERE MenuCode = 'SCHOOL_REPORTS') THEN N'yes' ELSE N'no' END;
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[active]', N'Is_Active = 0 menu (not built yet) is not returned', N'no', @actual, CASE WHEN @actual = N'no' THEN 1 ELSE 0 END);

    -- Turning it on is an UPDATE, which is the whole point of seeding it now.
    UPDATE dbo.m_sso_menus SET Is_Active = 1 WHERE MenuCode = 'SCHOOL_REPORTS';

    DELETE FROM @menus;
    INSERT INTO @menus EXEC dbo.USP_GetUserMenus @OwnerId;

    SET @actual = CASE WHEN EXISTS (SELECT 1 FROM @menus WHERE MenuCode = 'SCHOOL_REPORTS') THEN N'yes' ELSE N'no' END;
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[active]', N'flipping Is_Active to 1 publishes it, no INSERT needed', N'yes', @actual, CASE WHEN @actual = N'yes' THEN 1 ELSE 0 END);

    UPDATE dbo.m_sso_menus SET Is_Deleted = 1 WHERE MenuCode = 'SCHOOL_JOBS';

    DELETE FROM @menus;
    INSERT INTO @menus EXEC dbo.USP_GetUserMenus @OwnerId;

    SET @actual = CASE WHEN EXISTS (SELECT 1 FROM @menus WHERE MenuCode = 'SCHOOL_JOBS') THEN N'yes' ELSE N'no' END;
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[active]', N'soft-deleted menu is not returned', N'no', @actual, CASE WHEN @actual = N'no' THEN 1 ELSE 0 END);


    /*==========================================================================
      IsMenuVisible is RETURNED, not filtered — the client needs both kinds
    ==========================================================================*/
    DELETE FROM @menus;
    INSERT INTO @menus EXEC dbo.USP_GetUserMenus @OwnerId;

    SET @actual = CASE WHEN EXISTS (SELECT 1 FROM @menus WHERE IsMenuVisible = 0) THEN N'yes' ELSE N'no' END;
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[visible]', N'invisible rows still returned (client route-checks with them)', N'yes', @actual, CASE WHEN @actual = N'yes' THEN 1 ELSE 0 END);


    /*==========================================================================
      Unknown user — empty set, not an error
    ==========================================================================*/
    DELETE FROM @menus;
    INSERT INTO @menus EXEC dbo.USP_GetUserMenus 999999999;

    SET @actual = CAST((SELECT COUNT(*) FROM @menus) AS nvarchar(20));
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[unknown]', N'unknown UserId returns an empty set, no error', N'0', @actual, CASE WHEN @actual = N'0' THEN 1 ELSE 0 END);

    -- A deleted user must not keep drawing menus off a still-live token.
    UPDATE dbo.t_sso_users SET Is_Deleted = 1 WHERE UserId = @HrId;

    DELETE FROM @menus;
    INSERT INTO @menus EXEC dbo.USP_GetUserMenus @HrId;

    SET @actual = CAST((SELECT COUNT(*) FROM @menus) AS nvarchar(20));
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[unknown]', N'soft-deleted user gets nothing', N'0', @actual, CASE WHEN @actual = N'0' THEN 1 ELSE 0 END);


    /*==========================================================================
      t_sso_role_menus exists but is deliberately NOT consulted in MVP
    ==========================================================================*/
    SET @actual = CASE WHEN EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_sso_role_menus') THEN N'yes' ELSE N'no' END;
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[override]', N't_sso_role_menus table exists (unused in MVP)', N'yes', @actual, CASE WHEN @actual = N'yes' THEN 1 ELSE 0 END);

    SET @actual = CASE WHEN EXISTS (
            SELECT 1 FROM sys.sql_modules m
            INNER JOIN sys.objects o ON o.object_id = m.object_id
            WHERE o.name = 'USP_GetUserMenus' AND m.definition LIKE '%t\_sso\_role\_menus%' ESCAPE '\'
              AND m.definition NOT LIKE '%--%t\_sso\_role\_menus%' ESCAPE '\')
        THEN N'yes' ELSE N'no' END;
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[override]', N'USP_GetUserMenus does not read it yet', N'no', @actual, CASE WHEN @actual = N'no' THEN 1 ELSE 0 END);

END TRY
BEGIN CATCH
    INSERT INTO @results (Area, Assertion, Expected, Actual, Passed)
    VALUES ('[FATAL]', N'suite ran to completion', N'no error',
            N'Msg ' + CAST(ERROR_NUMBER() AS nvarchar(10)) + N' line '
            + CAST(ERROR_LINE() AS nvarchar(10)) + N': ' + ERROR_MESSAGE(), 0);
END CATCH

-- ALWAYS. Nothing above this line is allowed to survive.
IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;


/*==============================================================================
  Report
==============================================================================*/
SELECT Seq,
       Area,
       Assertion,
       Expected,
       Actual,
       Result = CASE WHEN Passed = 1 THEN 'PASS' ELSE '**FAIL**' END
FROM @results
ORDER BY Seq;

DECLARE @total int = (SELECT COUNT(*) FROM @results);
DECLARE @passed int = (SELECT COUNT(*) FROM @results WHERE Passed = 1);

PRINT '';
PRINT '=========================================================';
PRINT '  MENU TESTS: ' + CAST(@passed AS varchar(10)) + ' / ' + CAST(@total AS varchar(10)) + ' passed';
PRINT '=========================================================';

IF @passed <> @total
BEGIN
    DECLARE @failed int = @total - @passed;

    -- Non-zero exit under sqlcmd -b, so a broken build cannot look green.
    RAISERROR('003_test_menus: %d of %d assertions FAILED.', 16, 1, @failed, @total);
END
GO
