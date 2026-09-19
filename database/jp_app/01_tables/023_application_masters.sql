/*==============================================================================
  jp_app — 023_application_masters.sql

  m_app_application_status — the ten states an application can be in.
  Phase 5.

  ---------------------------------------------------------------------------
  🔴 TEN ROWS SEEDED, SIX REACHABLE. THE OTHER FOUR ARE PHASE 6.
  ---------------------------------------------------------------------------
  1 Applied · 2 Viewed · 3 Shortlisted · 4 Interview · 5 Selected · 6 Rejected
  are reachable now.

  7 OfferSent · 8 OfferAccepted · 9 OfferDeclined · 10 Hired are NOT. The offer
  chain is Phase 6 (t_app_offers), and until it exists there is no action that
  could legitimately move an application into any of them.

  ⚠️ They are seeded anyway, and that is deliberate: the ids are a contract
  (2.47), and inventing them later would mean either renumbering — which
  rewrites the meaning of every history row already written — or bolting them
  on at 11..14 in an order that reads like an accident.

  🔴 THE GUARD IS THE TRANSITION MAP, NOT THIS TABLE. A status existing here is
  not permission to move to it. USP_SetApplicationStatus refuses 7..10
  outright, and the verification proves it by trying.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_app_application_status' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_app_application_status] ...';

    CREATE TABLE dbo.m_app_application_status
    (
        ApplicationStatusId  int            NOT NULL,
        Code                 varchar(30)    NOT NULL,
        Name                 nvarchar(100)  NOT NULL,

        /*
          What the TEACHER is told. Kept separate from Name because the two
          audiences need different words for the same fact: a school sees
          "Rejected", and the teacher's list should not shout it back at them
          every time they open the app.

          ⚠️ Not a euphemism — "Not selected" is true and complete. The
          rejection REASON, if the school gave one, is never shown to the
          teacher in this phase (see USP_SetApplicationStatus).
        */
        TeacherFacingName    nvarchar(100)  NOT NULL,

        /*
          🔴 0 = this phase cannot reach it. Read by nothing at runtime — the
          transition map is the enforcement — and here so that a person reading
          the seed can see which four are waiting for Phase 6 without going to
          find the map.
        */
        IsReachable          tinyint        NOT NULL CONSTRAINT DF_m_app_application_status_IsReachable DEFAULT (1),

        DisplayOrder         int            NOT NULL CONSTRAINT DF_m_app_application_status_DisplayOrder DEFAULT (0),

        Is_Active            tinyint        NOT NULL CONSTRAINT DF_m_app_application_status_Is_Active  DEFAULT (1),
        Is_Deleted           tinyint        NOT NULL CONSTRAINT DF_m_app_application_status_Is_Deleted DEFAULT (0),
        CreatedOn            datetime2      NOT NULL CONSTRAINT DF_m_app_application_status_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy            bigint         NULL,
        ModifiedOn           datetime2      NULL,
        ModifiedBy           bigint         NULL,

        CONSTRAINT PK_m_app_application_status PRIMARY KEY CLUSTERED (ApplicationStatusId),
        CONSTRAINT CK_m_app_application_status_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_m_app_application_status_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );

    INSERT INTO dbo.m_app_application_status
        (ApplicationStatusId, Code, Name, TeacherFacingName, IsReachable, DisplayOrder)
    VALUES
        ( 1, 'APPLIED',        N'Applied',        N'Applied',              1,  1),
        ( 2, 'VIEWED',         N'Viewed',         N'Seen by the school',   1,  2),
        ( 3, 'SHORTLISTED',    N'Shortlisted',    N'Shortlisted',          1,  3),
        ( 4, 'INTERVIEW',      N'Interview',      N'Interview',            1,  4),
        ( 5, 'SELECTED',       N'Selected',       N'Selected',             1,  5),
        ( 6, 'REJECTED',       N'Rejected',       N'Not selected',         1,  6),

        -- 🔴 Phase 6. Seeded so the ids never move; refused by the map today.
        ( 7, 'OFFER_SENT',     N'Offer sent',     N'Offer received',       0,  7),
        ( 8, 'OFFER_ACCEPTED', N'Offer accepted', N'Offer accepted',       0,  8),
        ( 9, 'OFFER_DECLINED', N'Offer declined', N'Offer declined',       0,  9),
        (10, 'HIRED',          N'Hired',          N'Hired',                0, 10);
END
ELSE
BEGIN
    PRINT '    Table [m_app_application_status] already exists — skipped.';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_m_app_application_status_Code' AND object_id = OBJECT_ID('dbo.m_app_application_status'))
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UQ_m_app_application_status_Code
        ON dbo.m_app_application_status (Code) WHERE Is_Deleted = 0;
END
GO

PRINT '    Application masters ready.';
GO
