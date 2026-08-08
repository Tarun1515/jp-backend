/*==============================================================================
  jp_sso — 015_t_sso_permissions.sql

  The fixed catalogue of things that can be done. Seeded only — a school
  composes new ROLES out of these, it never invents a new permission, because
  a permission code has to correspond to a check that exists in the code.

  PermissionCode is MODULE.ACTION, e.g. JOB.CREATE. These strings travel in the
  JWT `perms` claim and are matched by permissionGuard in Angular and
  ClaimsPrincipal.HasPermission on the server, so they are a public contract.
==============================================================================*/

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_sso_permissions' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_sso_permissions] ...';

    CREATE TABLE dbo.t_sso_permissions
    (
        PermissionId    int             IDENTITY(1,1) NOT NULL,

        ModuleId        int             NOT NULL,

        PermissionCode  varchar(50)     NOT NULL,
        PermissionName  nvarchar(150)   NOT NULL,

        DisplayOrder    int             NOT NULL
            CONSTRAINT DF_t_sso_permissions_DisplayOrder DEFAULT (0),

        Is_Active       tinyint         NOT NULL
            CONSTRAINT DF_t_sso_permissions_Is_Active DEFAULT (1),
        Is_Deleted      tinyint         NOT NULL
            CONSTRAINT DF_t_sso_permissions_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2       NOT NULL
            CONSTRAINT DF_t_sso_permissions_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint          NULL,
        ModifiedOn      datetime2       NULL,
        ModifiedBy      bigint          NULL,

        CONSTRAINT PK_t_sso_permissions PRIMARY KEY CLUSTERED (PermissionId),

        CONSTRAINT FK_t_sso_permissions_m_sso_modules
            FOREIGN KEY (ModuleId) REFERENCES dbo.m_sso_modules (ModuleId),

        CONSTRAINT CK_t_sso_permissions_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_sso_permissions_Is_Deleted CHECK (Is_Deleted IN (0, 1)),

        -- Enforces the MODULE.ACTION shape. A code without a dot would never
        -- match anything and would fail silently as a permission that is simply
        -- never granted.
        CONSTRAINT CK_t_sso_permissions_CodeShape
            CHECK (PermissionCode LIKE '[A-Z]%.[A-Z]%')
    );

END
ELSE
BEGIN
    PRINT '    Table [t_sso_permissions] already exists — skipped.';
END
GO

-- Guarded independently of the table so a partial run can be repaired.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_sso_permissions_PermissionCode' AND object_id = OBJECT_ID('dbo.t_sso_permissions'))
BEGIN
    PRINT '    Creating index [UQ_t_sso_permissions_PermissionCode] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_sso_permissions_PermissionCode
        ON dbo.t_sso_permissions (PermissionCode)
        WHERE Is_Deleted = 0;
END
GO
