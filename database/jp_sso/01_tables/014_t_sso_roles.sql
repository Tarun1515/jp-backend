/*==============================================================================
  jp_sso — 014_t_sso_roles.sql

  Roles. Both the eight seeded system roles and any custom role a school
  defines for itself.

  OrganizationUid is the discriminator:
    NULL    -> global role, seeded, shared by every organisation
    value   -> custom role, belongs to exactly that school

  IsSystemRole marks the seeded eight so the role editor can refuse to let a
  school rename or delete SCHOOL_OWNER out from under itself.
==============================================================================*/

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_sso_roles' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_sso_roles] ...';

    CREATE TABLE dbo.t_sso_roles
    (
        RoleId          int             IDENTITY(1,1) NOT NULL,

        RoleCode        varchar(50)     NOT NULL,
        RoleName        nvarchar(100)   NOT NULL,

        -- Which kind of user this role can be granted to.
        UserTypeId      int             NOT NULL,

        IsSystemRole    bit             NOT NULL
            CONSTRAINT DF_t_sso_roles_IsSystemRole DEFAULT (0),

        -- NULL = global. Not a foreign key: the organisation lives in jp_app.
        OrganizationUid uniqueidentifier NULL,

        Is_Active       tinyint         NOT NULL
            CONSTRAINT DF_t_sso_roles_Is_Active DEFAULT (1),
        Is_Deleted      tinyint         NOT NULL
            CONSTRAINT DF_t_sso_roles_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2       NOT NULL
            CONSTRAINT DF_t_sso_roles_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint          NULL,
        ModifiedOn      datetime2       NULL,
        ModifiedBy      bigint          NULL,

        CONSTRAINT PK_t_sso_roles PRIMARY KEY CLUSTERED (RoleId),

        CONSTRAINT FK_t_sso_roles_m_sso_user_types
            FOREIGN KEY (UserTypeId) REFERENCES dbo.m_sso_user_types (UserTypeId),

        CONSTRAINT CK_t_sso_roles_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_sso_roles_Is_Deleted CHECK (Is_Deleted IN (0, 1)),

        -- A system role is global by definition; a school cannot own one.
        CONSTRAINT CK_t_sso_roles_SystemRoleIsGlobal
            CHECK (IsSystemRole = 0 OR OrganizationUid IS NULL)
    );

END
ELSE
BEGIN
    PRINT '    Table [t_sso_roles] already exists — skipped.';
END
GO

/*==============================================================================
  A role code is unique WITHIN its scope.

  Two schools may each define a role called DEPUTY_HEAD; neither may define it
  twice. SQL Server treats NULLs as EQUAL in a unique index, which is exactly
  the behaviour wanted here — it means only ONE global role may carry a given
  code, so nobody can shadow SCHOOL_OWNER.

  Guarded independently of the table so a partial run can be repaired.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_sso_roles_RoleCode_OrganizationUid' AND object_id = OBJECT_ID('dbo.t_sso_roles'))
BEGIN
    PRINT '    Creating index [UQ_t_sso_roles_RoleCode_OrganizationUid] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_sso_roles_RoleCode_OrganizationUid
        ON dbo.t_sso_roles (RoleCode, OrganizationUid)
        WHERE Is_Deleted = 0;
END
GO
