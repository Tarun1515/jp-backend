/*==============================================================================
  jp_app — 001_t_app_schools.sql

  ⚠️ PULLED FORWARD FROM PHASE 3 BY PHASE 2D.

  Phase 2D orchestrates the cross-database work that follows an approval:
  activate the user in jp_sso, then create the profile here. That second step
  needs somewhere to write, and jp_app had no tables at all.

  So this is the MINIMUM subset of the Phase 3 school table — enough for
  provisioning to be real rather than stubbed. Phase 3 will add the rest of the
  columns from DB_TABLE_STRUCTURE.md via numbered ALTER scripts (Block D), not
  by editing this CREATE.

  Present here: identity, the fields carried over from the registration
  payload, and the verification stamps.
  Absent, and Phase 3's job: suspension, ratings, subscription, branches.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_schools' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_schools] ...';

    CREATE TABLE dbo.t_app_schools
    (
        SchoolId            bigint            IDENTITY(1,1) NOT NULL,
        SchoolUid           uniqueidentifier  NOT NULL CONSTRAINT DF_t_app_schools_SchoolUid DEFAULT (NEWID()),

        /*
          ⚠️ CROSS-DATABASE, both of them. No foreign key and never one
          (decision 2.2).

          OrganizationUid ties the school to its users in jp_sso.
          SourceRequestUid is the jp_mdm approval request this school came from
          — and it is what makes provisioning IDEMPOTENT: a retry after a
          partial failure finds the existing row instead of creating a second
          school for the same approval.
        */
        OrganizationUid     uniqueidentifier  NOT NULL,
        SourceRequestUid    uniqueidentifier  NULL,

        SchoolName          nvarchar(200)     NOT NULL,
        SchoolTypeId        int               NULL,
        BoardId             int               NULL,
        AffiliationNumber   varchar(50)       NULL,
        RegistrationNo      varchar(50)       NULL,

        /*
          PAN. Collected at registration, and carried through provisioning so
          the school does not have to supply it twice.

          ⚠️ NULLABLE, and staying that way. Some smaller schools will not have
          it to hand at the moment they sign up, and blocking registration on a
          field an admin can chase later costs more sign-ups than it saves
          effort. Format is checked when a value IS given — AAAAA9999A,
          uppercased — but its absence is not an error.

          The PAN DOCUMENT is separate and already exists as a document type.
          Number and scan are collected together and verified together.
        */
        PanNumber           varchar(10)       NULL,

        LogoPath            nvarchar(500)     NULL,
        GroupType           tinyint           NULL,
        EstablishedYear     smallint          NULL,
        AboutSchool         nvarchar(max)     NULL,
        Website             nvarchar(255)     NULL,
        ContactEmail        nvarchar(150)     NULL,
        ContactMobile       varchar(15)       NULL,
        PrincipalName       nvarchar(150)     NULL,
        HrContactName       nvarchar(150)     NULL,
        HrContactMobile     varchar(15)       NULL,

        AddressLine1        nvarchar(250)     NULL,
        AddressLine2        nvarchar(250)     NULL,
        -- ⚠️ Nullable, and must stay nullable: the city dataset is empty (2.47).
        CityId              int               NULL,
        DistrictId          int               NULL,
        StateId             int               NULL,
        Pincode             varchar(10)       NULL,

        IsVerified          tinyint           NOT NULL CONSTRAINT DF_t_app_schools_IsVerified DEFAULT (0),
        VerifiedOn          datetime2         NULL,
        VerifiedByUserId    bigint            NULL,

        Is_Active           tinyint           NOT NULL CONSTRAINT DF_t_app_schools_Is_Active  DEFAULT (1),
        Is_Deleted          tinyint           NOT NULL CONSTRAINT DF_t_app_schools_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2         NOT NULL CONSTRAINT DF_t_app_schools_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint            NULL,
        ModifiedOn          datetime2         NULL,
        ModifiedBy          bigint            NULL,
        RowVersion          int               NOT NULL CONSTRAINT DF_t_app_schools_RowVersion DEFAULT (1),

        CONSTRAINT PK_t_app_schools PRIMARY KEY CLUSTERED (SchoolId),
        CONSTRAINT CK_t_app_schools_IsVerified CHECK (IsVerified IN (0, 1)),
        CONSTRAINT CK_t_app_schools_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_schools_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_schools] already exists — skipped.';
END
GO

/*------------------------------------------------------------------------------
  The public identifier. Unfiltered — a Uid must never be reused.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_t_app_schools_SchoolUid' AND object_id = OBJECT_ID('dbo.t_app_schools'))
BEGIN
    PRINT '    Creating index [UQ_t_app_schools_SchoolUid] ...';
    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_schools_SchoolUid ON dbo.t_app_schools (SchoolUid);
END
GO

/*------------------------------------------------------------------------------
  🔴 THE IDEMPOTENCY KEY.

  One school per approval request. This is what makes the cross-database retry
  safe: there is no distributed transaction, so provisioning CAN be attempted
  twice after a partial failure, and this index means the second attempt cannot
  create a duplicate school.

  Filtered to non-null because rows created by other routes (a manual import,
  Phase 3 migrations) have no source request.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'UQ_t_app_schools_SourceRequestUid' AND object_id = OBJECT_ID('dbo.t_app_schools'))
BEGIN
    PRINT '    Creating index [UQ_t_app_schools_SourceRequestUid] ...';
    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_schools_SourceRequestUid
        ON dbo.t_app_schools (SourceRequestUid)
        WHERE SourceRequestUid IS NOT NULL AND Is_Deleted = 0;
END
GO

/*------------------------------------------------------------------------------
  One organisation owns one school in MVP. Filtered so a soft delete frees it.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_app_schools_OrganizationUid' AND object_id = OBJECT_ID('dbo.t_app_schools'))
BEGIN
    PRINT '    Creating index [IX_t_app_schools_OrganizationUid] ...';
    CREATE NONCLUSTERED INDEX IX_t_app_schools_OrganizationUid
        ON dbo.t_app_schools (OrganizationUid) WHERE Is_Deleted = 0;
END
GO

/*------------------------------------------------------------------------------
  PanNumber, added in Phase 2F.

  In the CREATE above for a fresh database; here for one that already exists.
  ⚠️ Both paths, always. A column that lives only in the CREATE is a column
  every existing environment silently lacks, and it surfaces as "invalid
  column name" from a procedure rather than from anything naming the change.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE Name = N'PanNumber'
                 AND Object_ID = OBJECT_ID(N'dbo.t_app_schools'))
BEGIN
    PRINT '    Adding [PanNumber] to [t_app_schools] ...';

    ALTER TABLE dbo.t_app_schools ADD PanNumber varchar(10) NULL;
END
GO
