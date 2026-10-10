/*==============================================================================
  jp_app — 026_t_app_offers.sql

  t_app_offers — Offer Lite.

  Phase 6A.

  ---------------------------------------------------------------------------
  🔴 ONE LIVE OFFER PER APPLICATION, AND THE INDEX IS THE GUARD
  ---------------------------------------------------------------------------
  UQ_t_app_offers_LiveApplication is a filtered unique index on ApplicationId
  where the offer is Sent and not deleted. A SELECT-then-INSERT would let two
  sessions both pass their check and both write — which is precisely the race
  5A's apply path was built around, and the same resolution applies: the 2601
  is caught, the collision is verified to be on THIS index by name (the 3C
  lesson), and the row that already exists is re-read before anything is
  reported as "already done" (2.48).

  ⚠️ The predicate NAMES the status id — `OfferStatusId = 1` — because a
  filtered index cannot join to m_app_offer_status. 025's IsLive column is the
  documentation of that coupling; if a fifth live status is ever added, this
  predicate has to change with it.

  ---------------------------------------------------------------------------
  🔴 SchoolId, BranchId AND TeacherId ARE DENORMALISED, FOR 5A's REASON
  ---------------------------------------------------------------------------
  They are all reachable through ApplicationId. They are copied anyway, exactly
  as t_app_applications copies them (024): an offer is a document that must keep
  answering correctly after the job is closed, after the campus is soft-deleted,
  and whatever a later phase does to either. A join that resolves differently
  next year would change what a school is recorded as having offered.

  ---------------------------------------------------------------------------
  ⚠️ WHAT IS NOT HERE
  ---------------------------------------------------------------------------
  No approval columns. An offer that needs internal sign-off rides the approval
  engine through t_mdm_approval_requests, keyed by OfferUid — and jp_app does
  not carry a foreign key to jp_mdm (2.2). The offer knows nothing about levels
  or approvers; the engine knows nothing about salaries.

  ⚠️ Point 7 of the client's open questions — the full interview/offer scope —
  is STILL UNANSWERED. This is Offer Lite as the schema defines it, and it is
  what that answer will be measured against.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_offers' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_offers] ...';

    CREATE TABLE dbo.t_app_offers
    (
        OfferId             bigint            IDENTITY(1,1) NOT NULL,

        /*
          The public identifier. Everything on the wire uses this (2.39), and
          the entitlement ledger's reference for a metered offer would use it
          too — an id a client holds must not be a row number.
        */
        OfferUid            uniqueidentifier  NOT NULL CONSTRAINT DF_t_app_offers_OfferUid DEFAULT (NEWID()),

        ApplicationId       bigint            NOT NULL,

        -- Denormalised. See the header.
        SchoolId            bigint            NOT NULL,
        BranchId            bigint            NOT NULL,
        TeacherId           bigint            NOT NULL,

        /*
          What is being offered. DesignationId rather than free text so a school
          cannot offer a post that does not exist in the master (2.7), and so
          the offer can be compared against the job it came from.
        */
        DesignationId       int               NOT NULL,
        OfferedSalary       decimal(12, 2)    NULL,
        JoiningDate         date              NULL,

        /*
          ⚠️ time(0), not datetime. "Report at 8:00" is a clock time, not an
          instant — it does not move with a timezone and must not be stored as
          if it did (2.28).
        */
        ReportingTime       time(0)           NULL,

        TermsAndConditions  nvarchar(max)     NULL,

        OfferStatusId       int               NOT NULL CONSTRAINT DF_t_app_offers_OfferStatusId DEFAULT (1),

        SentOn              datetime2         NOT NULL CONSTRAINT DF_t_app_offers_SentOn DEFAULT (SYSUTCDATETIME()),
        SentByUserId        bigint            NULL,

        RespondedOn         datetime2         NULL,

        /*
          The teacher's own words when accepting or declining. Shown to the
          school — unlike a rejection reason, which travels the other way and
          is never shown to the teacher (024 / 017).
        */
        TeacherRemarks      nvarchar(1000)    NULL,

        /*
          Who withdrew it, and why. A withdrawal is the school acting against
          its own offer and the trail has to name somebody.
        */
        WithdrawnByUserId   bigint            NULL,
        WithdrawalReason    nvarchar(1000)    NULL,

        RowVersion          int               NOT NULL CONSTRAINT DF_t_app_offers_RowVersion DEFAULT (1),

        Is_Active           tinyint           NOT NULL CONSTRAINT DF_t_app_offers_Is_Active  DEFAULT (1),
        Is_Deleted          tinyint           NOT NULL CONSTRAINT DF_t_app_offers_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2         NOT NULL CONSTRAINT DF_t_app_offers_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint            NULL,
        ModifiedOn          datetime2         NULL,
        ModifiedBy          bigint            NULL,

        CONSTRAINT PK_t_app_offers PRIMARY KEY CLUSTERED (OfferId),

        CONSTRAINT FK_t_app_offers_t_app_applications
            FOREIGN KEY (ApplicationId) REFERENCES dbo.t_app_applications (ApplicationId),
        CONSTRAINT FK_t_app_offers_m_app_offer_status
            FOREIGN KEY (OfferStatusId) REFERENCES dbo.m_app_offer_status (OfferStatusId),
        CONSTRAINT FK_t_app_offers_t_app_school_branches
            FOREIGN KEY (BranchId) REFERENCES dbo.t_app_school_branches (BranchId),
        CONSTRAINT FK_t_app_offers_t_app_teachers
            FOREIGN KEY (TeacherId) REFERENCES dbo.t_app_teachers (TeacherId)
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_offers] already exists — skipped.';
END
GO

/*------------------------------------------------------------------------------
  🔴 THE GUARD. One LIVE offer per application.

  ⚠️ QUOTED_IDENTIFIER must be ON for a filtered index or this fails with
  Msg 1934 — which is why every script in this project sets it, and why
  `sqlcmd -I` is not optional.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_offers_LiveApplication' AND object_id = OBJECT_ID('dbo.t_app_offers'))
BEGIN
    PRINT '    Creating filtered unique index [UQ_t_app_offers_LiveApplication] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_offers_LiveApplication
        ON dbo.t_app_offers (ApplicationId)
        WHERE OfferStatusId = 1 AND Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_offers_OfferUid' AND object_id = OBJECT_ID('dbo.t_app_offers'))
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_offers_OfferUid
        ON dbo.t_app_offers (OfferUid) WHERE Is_Deleted = 0;
END
GO

-- The school's own list, and the teacher's. Both read by status.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_offers_School' AND object_id = OBJECT_ID('dbo.t_app_offers'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_t_app_offers_School
        ON dbo.t_app_offers (SchoolId, OfferStatusId)
        INCLUDE (ApplicationId, TeacherId, BranchId, SentOn, RespondedOn)
        WHERE Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_offers_Teacher' AND object_id = OBJECT_ID('dbo.t_app_offers'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_t_app_offers_Teacher
        ON dbo.t_app_offers (TeacherId, OfferStatusId)
        INCLUDE (ApplicationId, SchoolId, BranchId, SentOn, RespondedOn)
        WHERE Is_Deleted = 0;
END
GO

PRINT '    t_app_offers ready.';
GO
