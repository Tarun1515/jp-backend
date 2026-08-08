/*==============================================================================
  jp_sso — 002_indexes / 010_ix_t_sso_user_roles.sql

  The unique index on (UserId, RoleId, OrganizationUid) is in the table script
  and serves the UserId-leading lookup. These cover the other access paths.
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
  USP_GetUserClaims — every currently valid role for one user, on every login
  and every token refresh. The hottest read in this table.

  ValidFrom/ValidTo are DATE columns (decision 2.28), compared against
  dbo.fn_IstToday(). Because they are already calendar dates there is no
  conversion in the predicate, so this index seeks cleanly.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_roles_UserId_Validity' AND object_id = OBJECT_ID('dbo.t_sso_user_roles'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_roles_UserId_Validity] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_roles_UserId_Validity
        ON dbo.t_sso_user_roles (UserId, ValidFrom, ValidTo)
        INCLUDE (RoleId, OrganizationUid)
        WHERE Is_Deleted = 0 AND Is_Active = 1;
END
GO

/*------------------------------------------------------------------------------
  "Who holds this role?" — and FK support for t_sso_roles.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_roles_RoleId' AND object_id = OBJECT_ID('dbo.t_sso_user_roles'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_roles_RoleId] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_roles_RoleId
        ON dbo.t_sso_user_roles (RoleId)
        INCLUDE (UserId, OrganizationUid)
        WHERE Is_Deleted = 0;
END
GO

/*------------------------------------------------------------------------------
  "Every role grant within this school" — the team-management screen.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_roles_OrganizationUid' AND object_id = OBJECT_ID('dbo.t_sso_user_roles'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_roles_OrganizationUid] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_roles_OrganizationUid
        ON dbo.t_sso_user_roles (OrganizationUid)
        INCLUDE (UserId, RoleId)
        WHERE Is_Deleted = 0 AND OrganizationUid IS NOT NULL;
END
GO

-- FK support, and "which grants did this person make" for audit.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_user_roles_AssignedByUserId' AND object_id = OBJECT_ID('dbo.t_sso_user_roles'))
BEGIN
    PRINT '    Creating index [IX_t_sso_user_roles_AssignedByUserId] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_user_roles_AssignedByUserId
        ON dbo.t_sso_user_roles (AssignedByUserId)
        WHERE AssignedByUserId IS NOT NULL;
END
GO
