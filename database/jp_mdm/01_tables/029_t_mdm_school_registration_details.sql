/*==============================================================================
  jp_mdm — 029_t_mdm_school_registration_details.sql

  The school registration payload — a 1:1 extension of the request header.

  RequestId is BOTH the primary key and the foreign key: exactly one details row
  per request, enforced by the PK rather than by a procedure remembering to
  check. This is the payload as submitted; it is copied into t_app_schools by
  the API only once the request is approved.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_mdm_school_registration_details' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_mdm_school_registration_details] ...';

    CREATE TABLE dbo.t_mdm_school_registration_details
    (
        -- No IDENTITY: the key IS the request. 1:1 by construction.
        RequestId           bigint            NOT NULL,

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
        -- 1 = single school, 2 = part of a group. tinyint per spec.
        GroupType           tinyint           NULL,

        -- ⚠️ A YEAR, not a date. smallint rather than date on purpose: nobody
        -- knows the day a school was established, and a date column would
        -- invent a precision the data does not have (decision 2.28).
        EstablishedYear     smallint          NULL,

        AddressLine1        nvarchar(250)     NULL,
        AddressLine2        nvarchar(250)     NULL,
        CityId              int               NULL,
        DistrictId          int               NULL,
        StateId             int               NULL,
        Pincode             varchar(10)       NULL,

        PrincipalName       nvarchar(150)     NULL,
        PrincipalMobile     varchar(15)       NULL,
        HrContactName       nvarchar(150)     NULL,
        HrContactMobile     varchar(15)       NULL,
        ContactEmail        nvarchar(150)     NULL,
        ContactMobile       varchar(15)       NULL,
        Website             nvarchar(255)     NULL,
        AboutSchool         nvarchar(max)     NULL,

        Is_Active           tinyint           NOT NULL CONSTRAINT DF_t_mdm_school_registration_details_Is_Active  DEFAULT (1),
        Is_Deleted          tinyint           NOT NULL CONSTRAINT DF_t_mdm_school_registration_details_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2         NOT NULL CONSTRAINT DF_t_mdm_school_registration_details_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint            NULL,
        ModifiedOn          datetime2         NULL,
        ModifiedBy          bigint            NULL,

        CONSTRAINT PK_t_mdm_school_registration_details PRIMARY KEY CLUSTERED (RequestId),
        CONSTRAINT FK_t_mdm_school_registration_details_t_mdm_approval_requests
            FOREIGN KEY (RequestId) REFERENCES dbo.t_mdm_approval_requests (RequestId),
        CONSTRAINT FK_t_mdm_school_registration_details_m_mdm_school_type
            FOREIGN KEY (SchoolTypeId) REFERENCES dbo.m_mdm_school_type (SchoolTypeId),
        CONSTRAINT FK_t_mdm_school_registration_details_m_mdm_board
            FOREIGN KEY (BoardId) REFERENCES dbo.m_mdm_board (BoardId),
        CONSTRAINT FK_t_mdm_school_registration_details_m_mdm_city
            FOREIGN KEY (CityId) REFERENCES dbo.m_mdm_city (CityId),
        CONSTRAINT FK_t_mdm_school_registration_details_m_mdm_district
            FOREIGN KEY (DistrictId) REFERENCES dbo.m_mdm_district (DistrictId),
        CONSTRAINT FK_t_mdm_school_registration_details_m_mdm_state
            FOREIGN KEY (StateId) REFERENCES dbo.m_mdm_state (StateId),
        CONSTRAINT CK_t_mdm_school_registration_details_EstablishedYear
            CHECK (EstablishedYear IS NULL OR EstablishedYear BETWEEN 1800 AND 2200),
        CONSTRAINT CK_t_mdm_school_registration_details_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_mdm_school_registration_details_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_mdm_school_registration_details] already exists — skipped.';
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
                 AND Object_ID = OBJECT_ID(N'dbo.t_mdm_school_registration_details'))
BEGIN
    PRINT '    Adding [PanNumber] to [t_mdm_school_registration_details] ...';

    ALTER TABLE dbo.t_mdm_school_registration_details ADD PanNumber varchar(10) NULL;
END
GO
