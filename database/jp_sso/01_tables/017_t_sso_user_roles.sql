/*==============================================================================
  jp_sso — 017_t_sso_user_roles.sql

  Bridge: which roles a user holds, and where.

  OrganizationUid is repeated here rather than only on the role. A user can in
  principle hold the same role at more than one organisation, and the claim
  builder needs to know which organisation a grant applies to without joining
  back through the role.

  ---------------------------------------------------------------------------
  ValidFrom / ValidTo are DATE, not datetime2 (decision 2.28)
  ---------------------------------------------------------------------------
  "This HR account is valid until 31 March" is a calendar statement. A calendar
  date has no timezone, so storing it as an instant would force a choice about
  which midnight is meant — and get it wrong by 5.5 hours for every user.

  AssignedOn, by contrast, IS an instant, and stays datetime2 UTC.

  These are the only two `date` columns in the whole of jp_sso.
==============================================================================*/

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_sso_user_roles' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_sso_user_roles] ...';

    CREATE TABLE dbo.t_sso_user_roles
    (
        UserRoleId          bigint              IDENTITY(1,1) NOT NULL,
        UserId              bigint              NOT NULL,
        RoleId              int                 NOT NULL,

        -- Scope of the grant. NULL for admins and teachers.
        OrganizationUid     uniqueidentifier    NULL,

        -- NULL for roles granted by the system during registration.
        AssignedByUserId    bigint              NULL,

        -- An instant: when the grant was made.
        AssignedOn          datetime2           NOT NULL
            CONSTRAINT DF_t_sso_user_roles_AssignedOn DEFAULT (SYSUTCDATETIME()),

        -- Calendar dates, evaluated against dbo.fn_IstToday().
        ValidFrom           date                NOT NULL
            CONSTRAINT DF_t_sso_user_roles_ValidFrom DEFAULT (CAST(DATEADD(MINUTE, 330, SYSUTCDATETIME()) AS date)),
        ValidTo             date                NULL,

        Is_Active           tinyint             NOT NULL
            CONSTRAINT DF_t_sso_user_roles_Is_Active DEFAULT (1),
        Is_Deleted          tinyint             NOT NULL
            CONSTRAINT DF_t_sso_user_roles_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2           NOT NULL
            CONSTRAINT DF_t_sso_user_roles_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint              NULL,
        ModifiedOn          datetime2           NULL,
        ModifiedBy          bigint              NULL,

        CONSTRAINT PK_t_sso_user_roles PRIMARY KEY CLUSTERED (UserRoleId),

        CONSTRAINT FK_t_sso_user_roles_t_sso_users
            FOREIGN KEY (UserId) REFERENCES dbo.t_sso_users (UserId),
        CONSTRAINT FK_t_sso_user_roles_t_sso_roles
            FOREIGN KEY (RoleId) REFERENCES dbo.t_sso_roles (RoleId),
        CONSTRAINT FK_t_sso_user_roles_t_sso_users_AssignedBy
            FOREIGN KEY (AssignedByUserId) REFERENCES dbo.t_sso_users (UserId),

        CONSTRAINT CK_t_sso_user_roles_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_sso_user_roles_Is_Deleted CHECK (Is_Deleted IN (0, 1)),

        -- A grant cannot expire before it starts. Same-day grants are allowed.
        CONSTRAINT CK_t_sso_user_roles_ValidRange
            CHECK (ValidTo IS NULL OR ValidTo >= ValidFrom)
    );

END
ELSE
BEGIN
    PRINT '    Table [t_sso_user_roles] already exists — skipped.';
END
GO

-- One live grant per (user, role, scope).
-- Guarded independently of the table so a partial run can be repaired.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_sso_user_roles_UserId_RoleId_OrganizationUid'
                 AND object_id = OBJECT_ID('dbo.t_sso_user_roles'))
BEGIN
    PRINT '    Creating index [UQ_t_sso_user_roles_UserId_RoleId_OrganizationUid] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_sso_user_roles_UserId_RoleId_OrganizationUid
        ON dbo.t_sso_user_roles (UserId, RoleId, OrganizationUid)
        WHERE Is_Deleted = 0;
END
GO
