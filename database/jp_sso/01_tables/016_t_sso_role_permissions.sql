/*==============================================================================
  jp_sso — 016_t_sso_role_permissions.sql

  Bridge: which permissions a role grants.

  Many-to-many is always a bridge table in this system — never a
  comma-separated column (PROJECT_MEMORY 2.7). This is what USP_GetUserClaims
  joins through to build the `perms` array in the JWT.

  Bridge tables carry the full standard column set, same as every other table.
==============================================================================*/

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_sso_role_permissions' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_sso_role_permissions] ...';

    CREATE TABLE dbo.t_sso_role_permissions
    (
        RolePermissionId    bigint      IDENTITY(1,1) NOT NULL,
        RoleId              int         NOT NULL,
        PermissionId        int         NOT NULL,

        Is_Active           tinyint     NOT NULL
            CONSTRAINT DF_t_sso_role_permissions_Is_Active DEFAULT (1),
        Is_Deleted          tinyint     NOT NULL
            CONSTRAINT DF_t_sso_role_permissions_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2   NOT NULL
            CONSTRAINT DF_t_sso_role_permissions_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint      NULL,
        ModifiedOn          datetime2   NULL,
        ModifiedBy          bigint      NULL,

        CONSTRAINT PK_t_sso_role_permissions PRIMARY KEY CLUSTERED (RolePermissionId),

        CONSTRAINT FK_t_sso_role_permissions_t_sso_roles
            FOREIGN KEY (RoleId) REFERENCES dbo.t_sso_roles (RoleId),
        CONSTRAINT FK_t_sso_role_permissions_t_sso_permissions
            FOREIGN KEY (PermissionId) REFERENCES dbo.t_sso_permissions (PermissionId),

        CONSTRAINT CK_t_sso_role_permissions_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_sso_role_permissions_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );

END
ELSE
BEGIN
    PRINT '    Table [t_sso_role_permissions] already exists — skipped.';
END
GO

-- One grant per pair. Filtered, so a permission removed from a role and later
-- restored is a fresh row rather than a constraint violation.
-- Guarded independently of the table so a partial run can be repaired.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_sso_role_permissions_RoleId_PermissionId'
                 AND object_id = OBJECT_ID('dbo.t_sso_role_permissions'))
BEGIN
    PRINT '    Creating index [UQ_t_sso_role_permissions_RoleId_PermissionId] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_sso_role_permissions_RoleId_PermissionId
        ON dbo.t_sso_role_permissions (RoleId, PermissionId)
        WHERE Is_Deleted = 0;
END
GO
