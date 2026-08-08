/*==============================================================================
  jp_sso — 008_t_sso_users.sql

  The identity root. One row per person who can sign in, of any type.

  This table knows NOTHING about schools or teachers. It sees a UserTypeId and
  an opaque OrganizationUid, and nothing else — that separation is what lets
  JP.Sso.Api deploy on its own (PROJECT_MEMORY 2.1).

  ---------------------------------------------------------------------------
  DATE vs datetime2 (decision 2.28)
  ---------------------------------------------------------------------------
  Every temporal column here is an INSTANT, not a calendar date, so all of them
  are datetime2 UTC: LastLoginOn and LastPasswordChangeOn are moments in time.
  There is no `date` column in this table.

  ---------------------------------------------------------------------------
  Email
  ---------------------------------------------------------------------------
  Normalised to lowercase before insert by the registration procedures
  (Phase 1B). CK_t_sso_users_Email_Lowercase makes that a database guarantee
  rather than a convention: the check compares under a BINARY collation,
  because under the database's case-INSENSITIVE collation `Email = LOWER(Email)`
  is trivially true and would enforce nothing at all.

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

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_sso_users' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_sso_users] ...';

    CREATE TABLE dbo.t_sso_users
    (
        UserId                  bigint              IDENTITY(1,1) NOT NULL,

        -- The public identifier. Everything outside this database — JWT claims,
        -- API payloads, URLs, and the OrganizationUid/UserUid columns in
        -- jp_mdm and jp_app — refers to a user by this, never by UserId.
        UserUid                 uniqueidentifier    NOT NULL
            CONSTRAINT DF_t_sso_users_UserUid DEFAULT (NEWID()),

        UserTypeId              int                 NOT NULL,
        StatusId                int                 NOT NULL,

        -- Stored lowercase; see the header note and the CHECK below.
        Email                   nvarchar(150)       NOT NULL,

        -- Nullable: email is the mandatory identifier, mobile is optional.
        -- The unique index below therefore has to exclude NULLs explicitly.
        Mobile                  varchar(15)         NULL,

        IsEmailVerified         bit                 NOT NULL
            CONSTRAINT DF_t_sso_users_IsEmailVerified DEFAULT (0),
        IsMobileVerified        bit                 NOT NULL
            CONSTRAINT DF_t_sso_users_IsMobileVerified DEFAULT (0),

        -- Tenant boundary. NULL for admins and teachers, who belong to no
        -- organisation. Deliberately NOT a foreign key — the organisation
        -- lives in jp_app, and no physical FK crosses a database (2.2).
        OrganizationUid         uniqueidentifier    NULL,

        -- Who created this account. Set for admin-created and invited users;
        -- NULL for self-registration. Self-referencing.
        CreatedByUserId         bigint              NULL,

        -- Instants, in UTC.
        LastLoginOn             datetime2           NULL,
        LastPasswordChangeOn    datetime2           NULL,

        -- Reset to 0 on a successful login; at 5 the account is locked for
        -- 30 minutes. Maintained by USP_RecordLoginAttempt (Phase 1B).
        FailedAttemptCount      int                 NOT NULL
            CONSTRAINT DF_t_sso_users_FailedAttemptCount DEFAULT (0),

        -- ---- standard columns ------------------------------------------------
        Is_Active               tinyint             NOT NULL
            CONSTRAINT DF_t_sso_users_Is_Active DEFAULT (1),
        Is_Deleted              tinyint             NOT NULL
            CONSTRAINT DF_t_sso_users_Is_Deleted DEFAULT (0),
        CreatedOn               datetime2           NOT NULL
            CONSTRAINT DF_t_sso_users_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CreatedBy               bigint              NULL,
        ModifiedOn              datetime2           NULL,
        ModifiedBy              bigint              NULL,
        [RowVersion]            int                 NOT NULL
            CONSTRAINT DF_t_sso_users_RowVersion DEFAULT (1),

        CONSTRAINT PK_t_sso_users PRIMARY KEY CLUSTERED (UserId),

        CONSTRAINT FK_t_sso_users_m_sso_user_types
            FOREIGN KEY (UserTypeId) REFERENCES dbo.m_sso_user_types (UserTypeId),
        CONSTRAINT FK_t_sso_users_m_sso_user_status
            FOREIGN KEY (StatusId) REFERENCES dbo.m_sso_user_status (StatusId),
        CONSTRAINT FK_t_sso_users_t_sso_users_CreatedByUserId
            FOREIGN KEY (CreatedByUserId) REFERENCES dbo.t_sso_users (UserId),

        CONSTRAINT CK_t_sso_users_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_sso_users_Is_Deleted CHECK (Is_Deleted IN (0, 1)),
        CONSTRAINT CK_t_sso_users_FailedAttemptCount CHECK (FailedAttemptCount >= 0),

        -- Enforces the lowercase normalisation the registration procs perform.
        -- The BIN2 collation is load-bearing: without it this comparison runs
        -- under the database's CI collation and is always true.
        CONSTRAINT CK_t_sso_users_Email_Lowercase
            CHECK (Email COLLATE Latin1_General_BIN2 = LOWER(Email) COLLATE Latin1_General_BIN2),

        -- Cheap sanity check only. Real validation is FluentValidation in the
        -- API; a database CHECK is the wrong place to litigate RFC 5322.
        CONSTRAINT CK_t_sso_users_Email_Shape
            CHECK (Email LIKE '_%@_%._%')
    );

END
ELSE
BEGIN
    PRINT '    Table [t_sso_users] already exists — skipped.';
END
GO

/*==============================================================================
  BUSINESS KEYS

  Guarded independently of the table above. If the table is created but an
  index fails, re-running this script repairs it — a single guard wrapping both
  would skip the whole block and leave the table permanently un-indexed.

  Email and Mobile are filtered on Is_Deleted = 0: a soft-deleted account must
  release its address so the same person can register again. Without the
  filter, a deleted row would block that address forever.

  Mobile additionally excludes NULLs. SQL Server treats NULLs as EQUAL in a
  unique index, so without `AND Mobile IS NOT NULL` the second user without a
  mobile number would fail to insert.
==============================================================================*/

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_sso_users_Email' AND object_id = OBJECT_ID('dbo.t_sso_users'))
BEGIN
    PRINT '    Creating index [UQ_t_sso_users_Email] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_sso_users_Email
        ON dbo.t_sso_users (Email)
        WHERE Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_sso_users_Mobile' AND object_id = OBJECT_ID('dbo.t_sso_users'))
BEGIN
    PRINT '    Creating index [UQ_t_sso_users_Mobile] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_sso_users_Mobile
        ON dbo.t_sso_users (Mobile)
        WHERE Is_Deleted = 0 AND Mobile IS NOT NULL;
END
GO

/*------------------------------------------------------------------------------
  UserUid is unique UNFILTERED — deliberately different from Email/Mobile.

  It is a NEWID() surrogate, never re-entered by a user, so there is no
  reuse-after-delete case to allow for. Leaving it unfiltered buys two things:
  a Uid can never resolve to two rows even if a query forgets the Is_Deleted
  predicate, and lookups that DO want soft-deleted rows (audit trails, restore,
  resolving a stale URL) can still seek this index — a filtered index is
  unusable unless the query repeats its filter.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_sso_users_UserUid' AND object_id = OBJECT_ID('dbo.t_sso_users'))
BEGIN
    PRINT '    Creating index [UQ_t_sso_users_UserUid] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_sso_users_UserUid
        ON dbo.t_sso_users (UserUid);
END
GO
