/*==============================================================================
  jp_app — 009_t_app_school_users.sql

  Who works at a school, and in what capacity.

  ---------------------------------------------------------------------------
  🔴 THIS IS NOT A ROLE TABLE, AND MUST NOT BECOME ONE
  ---------------------------------------------------------------------------
  Roles and permissions live in jp_sso — t_sso_roles, t_sso_permissions,
  t_sso_user_roles — and that is what decides what somebody may DO.

  RoleInSchool answers a different question: what they are TO THIS SCHOOL. It
  drives what the school's own team screen shows and who a job's notifications
  go to. Two people can both hold the HR permission set in jp_sso while one is
  the owner of this school and the other is a viewer at one campus.

  ⚠️ If a check ever reads RoleInSchool to decide whether an action is allowed,
  that check is in the wrong place. Permissions are in jp_sso.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_school_users' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_school_users] ...';

    CREATE TABLE dbo.t_app_school_users
    (
        SchoolUserId    bigint              IDENTITY(1,1) NOT NULL,
        SchoolId        bigint              NOT NULL,

        /*
          ⚠️ CROSS-DATABASE — t_sso_users.UserUid in jp_sso. No foreign key
          (decision 2.2), validated in the procedure, indexed below.

          uniqueidentifier, matching the live column — NOT the bigint UserId.
          The Uid is the key that crosses a database boundary in this system;
          the id is local to jp_sso.
        */
        UserUid         uniqueidentifier    NOT NULL,

        /*
          1 = Owner, 2 = Senior HR, 3 = HR, 4 = Viewer.

          A CHECK rather than a master table: these four are structural to the
          product and are branched on in code, so a fifth is a code change and
          not a data change. A master would suggest otherwise.
        */
        RoleInSchool    tinyint             NOT NULL,

        -- What it says on their card. Free text on purpose — "Vice Principal
        -- (Academics)" is not a value any list of ours would have had.
        DesignationText nvarchar(150)       NULL,

        -- ---- standard columns -------------------------------------------------
        Is_Active       tinyint             NOT NULL CONSTRAINT DF_t_app_school_users_Is_Active  DEFAULT (1),
        Is_Deleted      tinyint             NOT NULL CONSTRAINT DF_t_app_school_users_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2           NOT NULL CONSTRAINT DF_t_app_school_users_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint              NULL,
        ModifiedOn      datetime2           NULL,
        ModifiedBy      bigint              NULL,

        CONSTRAINT PK_t_app_school_users PRIMARY KEY CLUSTERED (SchoolUserId),
        CONSTRAINT FK_t_app_school_users_t_app_schools
            FOREIGN KEY (SchoolId) REFERENCES dbo.t_app_schools (SchoolId),
        CONSTRAINT CK_t_app_school_users_RoleInSchool CHECK (RoleInSchool IN (1, 2, 3, 4)),
        CONSTRAINT CK_t_app_school_users_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_school_users_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_school_users] already exists — skipped.';
END
GO
/*------------------------------------------------------------------------------
  🔴 ONE MEMBERSHIP PER PERSON PER SCHOOL.

  Without this, re-inviting somebody who is already on the team creates a second
  membership — and then their role is whichever row the query happened to read
  first, which is the kind of bug that presents as "sometimes I can see the
  branches page and sometimes I cannot".

  Filtered, so somebody removed from a school can be added back later.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_school_users_SchoolId_UserUid' AND object_id = OBJECT_ID('dbo.t_app_school_users'))
BEGIN
    PRINT '    Creating index [UQ_t_app_school_users_SchoolId_UserUid] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_school_users_SchoolId_UserUid
        ON dbo.t_app_school_users (SchoolId, UserUid)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  ⚠️ The cross-database reference, indexed because it has no foreign key.

  "Which schools does this person belong to" runs on every sign-in for a school
  user, and the answer has to come from an index rather than a scan.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_school_users_UserUid' AND object_id = OBJECT_ID('dbo.t_app_school_users'))
BEGIN
    PRINT '    Creating index [IX_t_app_school_users_UserUid] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_school_users_UserUid
        ON dbo.t_app_school_users (UserUid)
        INCLUDE (SchoolId, RoleInSchool)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  The school's own team list, owners first.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_school_users_SchoolId_RoleInSchool' AND object_id = OBJECT_ID('dbo.t_app_school_users'))
BEGIN
    PRINT '    Creating index [IX_t_app_school_users_SchoolId_RoleInSchool] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_school_users_SchoolId_RoleInSchool
        ON dbo.t_app_school_users (SchoolId, RoleInSchool)
        INCLUDE (UserUid, DesignationText)
        WHERE Is_Deleted = 0;
END
GO
