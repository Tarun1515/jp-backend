/*==============================================================================
  jp_mdm — 030_t_mdm_teacher_registration_details.sql

  The teacher registration payload — a 1:1 extension of the request header.

  Same shape rule as the school details table: RequestId is both PK and FK.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_mdm_teacher_registration_details' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_mdm_teacher_registration_details] ...';

    CREATE TABLE dbo.t_mdm_teacher_registration_details
    (
        RequestId           bigint            NOT NULL,

        FullName            nvarchar(150)     NOT NULL,

        -- 🔴 date, NOT datetime2. A date of birth is a calendar date with no
        -- instant attached: it does not shift with a timezone, and storing it
        -- as a UTC timestamp is how someone born on the 1st becomes the 31st
        -- for five and a half hours of every day (decision 2.28).
        DOB                 date              NULL,

        GenderId            int               NULL,
        QualificationId     int               NULL,

        -- Months, not years — a range filter is then a plain integer compare
        -- and 18 months does not have to round to 1 or 2.
        TotalExperienceMonths int             NULL,

        CurrentCityId       int               NULL,
        CurrentStateId      int               NULL,
        CurrentSchool       nvarchar(200)     NULL,

        Is_Active           tinyint           NOT NULL CONSTRAINT DF_t_mdm_teacher_registration_details_Is_Active  DEFAULT (1),
        Is_Deleted          tinyint           NOT NULL CONSTRAINT DF_t_mdm_teacher_registration_details_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2         NOT NULL CONSTRAINT DF_t_mdm_teacher_registration_details_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint            NULL,
        ModifiedOn          datetime2         NULL,
        ModifiedBy          bigint            NULL,

        CONSTRAINT PK_t_mdm_teacher_registration_details PRIMARY KEY CLUSTERED (RequestId),
        CONSTRAINT FK_t_mdm_teacher_registration_details_t_mdm_approval_requests
            FOREIGN KEY (RequestId) REFERENCES dbo.t_mdm_approval_requests (RequestId),
        CONSTRAINT FK_t_mdm_teacher_registration_details_m_mdm_gender
            FOREIGN KEY (GenderId) REFERENCES dbo.m_mdm_gender (GenderId),
        CONSTRAINT FK_t_mdm_teacher_registration_details_m_mdm_qualification
            FOREIGN KEY (QualificationId) REFERENCES dbo.m_mdm_qualification (QualificationId),
        CONSTRAINT FK_t_mdm_teacher_registration_details_m_mdm_city
            FOREIGN KEY (CurrentCityId) REFERENCES dbo.m_mdm_city (CityId),
        CONSTRAINT FK_t_mdm_teacher_registration_details_m_mdm_state
            FOREIGN KEY (CurrentStateId) REFERENCES dbo.m_mdm_state (StateId),
        CONSTRAINT CK_t_mdm_teacher_registration_details_Experience
            CHECK (TotalExperienceMonths IS NULL OR TotalExperienceMonths BETWEEN 0 AND 1200),
        CONSTRAINT CK_t_mdm_teacher_registration_details_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_mdm_teacher_registration_details_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_mdm_teacher_registration_details] already exists — skipped.';
END
GO
