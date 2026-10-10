/*==============================================================================
  jp_app — 025_offer_masters.sql

  m_app_offer_status — the four states an OFFER can be in.

  Phase 6A (Offer Lite).

  ---------------------------------------------------------------------------
  🔴 AN OFFER'S STATUS IS NOT AN APPLICATION'S STATUS
  ---------------------------------------------------------------------------
  There are two machines here and they must not be confused:

      the OFFER        Sent -> Accepted / Declined / Withdrawn   (this table)
      the APPLICATION  … -> Selected -> OfferSent -> OfferAccepted -> Hired
                       (m_app_application_status, 023)

  The offer is the document; the application is where the candidate stands.
  Sending an offer writes one row here AND moves the application, in one
  transaction — but they answer different questions, and a school looking at
  "Declined" wants to know whether that is this offer or this candidate.

  ⚠️ FOUR ROWS, FOUR REACHABLE. Unlike 023, nothing here is seeded ahead of a
  phase that will make it reachable: Offer Lite is the whole of the offer
  model the client has asked for (point 7 of the open questions is still
  unanswered, and this schema is what the answer will be measured against).

  ---------------------------------------------------------------------------
  🔴 IsLive IS WHAT THE UNIQUE INDEX MEANS
  ---------------------------------------------------------------------------
  "One live offer per application" is enforced by a filtered unique index on
  t_app_offers, and a filtered index cannot join to this table — its predicate
  has to name the id. So IsLive is documentation of the id the index names, in
  the same spirit as 023's IsReachable: read by nothing at runtime, there so a
  person reading the seed can see why the index says `OfferStatusId = 1`.

  ⚠️ If a fifth status is ever added and it is LIVE, the index predicate must
  change with it. That is the one coupling this column exists to make visible.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_app_offer_status' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_app_offer_status] ...';

    CREATE TABLE dbo.m_app_offer_status
    (
        OfferStatusId      int            NOT NULL,
        Code               varchar(30)    NOT NULL,
        Name               nvarchar(100)  NOT NULL,

        /*
          What the TEACHER is told, on the same reasoning as 023's column. A
          school withdrawing an offer is an internal act; the teacher is told
          the offer was withdrawn, not why.
        */
        TeacherFacingName  nvarchar(100)  NOT NULL,

        /*
          🔴 1 = an offer in this state OCCUPIES the application. See the header.
        */
        IsLive             tinyint        NOT NULL CONSTRAINT DF_m_app_offer_status_IsLive DEFAULT (0),

        DisplayOrder       int            NOT NULL CONSTRAINT DF_m_app_offer_status_DisplayOrder DEFAULT (0),
        Is_Active          tinyint        NOT NULL CONSTRAINT DF_m_app_offer_status_Is_Active  DEFAULT (1),
        Is_Deleted         tinyint        NOT NULL CONSTRAINT DF_m_app_offer_status_Is_Deleted DEFAULT (0),
        CreatedOn          datetime2      NOT NULL CONSTRAINT DF_m_app_offer_status_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy          bigint         NULL,
        ModifiedOn         datetime2      NULL,
        ModifiedBy         bigint         NULL,

        CONSTRAINT PK_m_app_offer_status PRIMARY KEY CLUSTERED (OfferStatusId)
    );

    INSERT INTO dbo.m_app_offer_status
        (OfferStatusId, Code, Name, TeacherFacingName, IsLive, DisplayOrder)
    VALUES
        -- 🔴 1 is the ONLY live state, and the filtered index names it.
        (1, 'SENT',      N'Sent',      N'Offer received',  1, 1),
        (2, 'ACCEPTED',  N'Accepted',  N'You accepted',    0, 2),
        (3, 'DECLINED',  N'Declined',  N'You declined',    0, 3),
        (4, 'WITHDRAWN', N'Withdrawn', N'Offer withdrawn', 0, 4);
END
ELSE
BEGIN
    PRINT '    Table [m_app_offer_status] already exists — skipped.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_m_app_offer_status_Code' AND object_id = OBJECT_ID('dbo.m_app_offer_status'))
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UQ_m_app_offer_status_Code
        ON dbo.m_app_offer_status (Code) WHERE Is_Deleted = 0;
END
GO

/*------------------------------------------------------------------------------
  🔴 PHASE 6A FLIPS 023's FOUR UNREACHABLE APPLICATION STATUSES TO REACHABLE.

  023 seeded 7 OfferSent · 8 OfferAccepted · 9 OfferDeclined · 10 Hired with
  IsReachable = 0 and said, in its header, exactly when that would change:
  "until [t_app_offers] exists there is no action that could legitimately move
  an application into any of them."

  It exists now. The flag is data about what the product can do, so it is
  updated rather than re-seeded — the ids, which are the contract, do not move.

  ⚠️ THE FLAG IS NOT THE GUARD AND NEVER WAS. The transition map decides
  (fn_ApplicationTransitionAllowed, 016), and the generic status endpoint
  refuses these four regardless, because they are driven by the OFFER actions
  and not by a school picking a stage from a dropdown. Flipping this column
  authorises nothing.
------------------------------------------------------------------------------*/
UPDATE dbo.m_app_application_status
   SET IsReachable = 1,
       ModifiedOn  = SYSUTCDATETIME()
WHERE ApplicationStatusId IN (7, 8, 9, 10)
  AND IsReachable = 0
  AND Is_Deleted  = 0;

IF @@ROWCOUNT > 0
    PRINT '    m_app_application_status: the offer chain (7..10) is reachable from Phase 6A.';
GO

PRINT '    Offer masters ready.';
GO
