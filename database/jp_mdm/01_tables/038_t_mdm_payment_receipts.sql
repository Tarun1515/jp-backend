/*==============================================================================
  jp_mdm — 038_t_mdm_payment_receipts.sql

  A receipt for money that arrived, and the counter that numbers it.

  ---------------------------------------------------------------------------
  🔴 A RECEIPT, NOT AN INVOICE — AND IT DOES NOT CLAIM TO BE ONE
  ---------------------------------------------------------------------------
  An invoice is a demand for payment and carries tax. This records that money
  WAS RECEIVED: how much, by what mode, against which plan, at what quoted
  price, for which period. GST computation, credit notes and refunds are out of
  this phase (2.63), and MONETIZATION_DESIGN 6.5-E says where each would land.

  The naming matters more than it looks: a table called t_mdm_invoices would
  invite somebody to add a tax column and a due date, and then the product is
  making tax statements it was never designed to make.

  ---------------------------------------------------------------------------
  🔴 IMMUTABLE BY INTENTION
  ---------------------------------------------------------------------------
  There is no ModifiedOn and no ModifiedBy, and that is not an omission. A
  receipt that can be edited is not a receipt. A correction is a NEW row
  pointing at the one it corrects — which is what the deferred credit-note
  shape is — and the column for it (CorrectsReceiptId) is NOT built here,
  because 2.63 keeps credit notes out and a built-but-unused column is how a
  half-feature ships.

  ⚠️ Is_Deleted exists because the house pattern uses it everywhere and a
  single table opting out breaks every generic read. It is a soft-delete for
  an administrative mistake, not an edit.

  ---------------------------------------------------------------------------
  🔴 WHY THE AMOUNTS ARE COPIED HERE RATHER THAN READ THROUGH PaymentId
  ---------------------------------------------------------------------------
  A receipt states what was true when it was issued. Prices are data and will
  change (2.7); plans can be renamed; a payment row can be soft-deleted. A
  receipt that joins out to find its own numbers would restate history every
  time any of those moved, which is exactly the failure a receipt exists to
  prevent.

  So Amount, PriceQuoted and PlanName are DENORMALISED on purpose. This is the
  one place in the schema where that is the correct answer rather than the lazy
  one, and the reason is written here so nobody "fixes" it into a join.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF OBJECT_ID('dbo.t_mdm_payment_receipts', 'U') IS NULL
BEGIN
    PRINT '    Creating table [t_mdm_payment_receipts] ...';

    CREATE TABLE dbo.t_mdm_payment_receipts
    (
        ReceiptId       bigint            IDENTITY(1, 1) NOT NULL,

        /*
          RCP-2026-00001. Allocated per IST year from t_mdm_receipt_number_series
          (2.46 pattern) — never MAX()+1. See USP_AllocateReceiptNo.
        */
        ReceiptNo       varchar(30)       NOT NULL,

        /*
          The payment this receipts. A plain id with an FK — both tables are in
          jp_mdm, so this is an ordinary relationship and 2.2 does not apply.
        */
        PaymentId       bigint            NOT NULL,

        /*
          🔴 Denormalised ON PURPOSE. See the header. These are what was true
          at issue time, not what a join would say today.
        */
        Amount          decimal(18, 2)    NOT NULL,
        PriceQuoted     decimal(10, 2)    NULL,
        PaymentModeId   int               NOT NULL,
        PaymentRefNo    varchar(100)      NULL,
        PlanId          int               NOT NULL,
        PlanName        nvarchar(100)     NOT NULL,

        /*
          The period this payment bought, as resolved at activation. NULL EndsOn
          would mean a perpetual plan — no paid plan is one, but the column
          follows t_app_subscriptions.EndsOn rather than inventing a stricter
          rule than the thing it describes.
        */
        PeriodStartsOn  datetime2         NOT NULL,
        PeriodEndsOn    datetime2         NULL,

        /*
          WHO verified, or NULL when a machine did. The gateway caller has no
          user (6.5-A), so VerifiedVia records the KIND of verification and is
          NOT NULL — "ADMIN" or "GATEWAY". A NULL verifier with no explanation
          would be unreadable the first time it appeared.
        */
        VerifiedByUserId bigint           NULL,
        VerifiedVia      varchar(10)      NOT NULL,
        IssuedOn         datetime2        NOT NULL
                         CONSTRAINT DF_t_mdm_payment_receipts_IssuedOn DEFAULT (SYSUTCDATETIME()),

        Is_Deleted      tinyint           NOT NULL
                        CONSTRAINT DF_t_mdm_payment_receipts_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2         NOT NULL
                        CONSTRAINT DF_t_mdm_payment_receipts_CreatedOn DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint            NULL,

        CONSTRAINT PK_t_mdm_payment_receipts PRIMARY KEY CLUSTERED (ReceiptId),

        CONSTRAINT FK_t_mdm_payment_receipts_t_mdm_request_payments
            FOREIGN KEY (PaymentId) REFERENCES dbo.t_mdm_request_payments (PaymentId),
        CONSTRAINT FK_t_mdm_payment_receipts_m_mdm_payment_modes
            FOREIGN KEY (PaymentModeId) REFERENCES dbo.m_mdm_payment_modes (PaymentModeId),
        CONSTRAINT FK_t_mdm_payment_receipts_m_mdm_plans
            FOREIGN KEY (PlanId) REFERENCES dbo.m_mdm_plans (PlanId),

        CONSTRAINT CK_t_mdm_payment_receipts_Amount     CHECK (Amount >= 0),
        CONSTRAINT CK_t_mdm_payment_receipts_Is_Deleted CHECK (Is_Deleted IN (0, 1)),

        /*
          🔴 The structural half of 6.5-A's seam: VerifiedVia says how, and the
          CHECK makes "ADMIN with no user" impossible. An admin verification
          with no admin recorded is the one state that would make the money
          trail useless, and a comment asking people not to do it is not a
          guard (2.36).
        */
        CONSTRAINT CK_t_mdm_payment_receipts_VerifiedVia
            CHECK (VerifiedVia IN ('ADMIN', 'GATEWAY')),
        CONSTRAINT CK_t_mdm_payment_receipts_AdminHasUser
            CHECK (VerifiedVia <> 'ADMIN' OR VerifiedByUserId IS NOT NULL)
    );
END
ELSE
    PRINT '    Table [t_mdm_payment_receipts] already exists — skipped.';
GO

/*
  ONE receipt per payment. This is the idempotency guard for the allocation:
  a retried verification must not mint a second receipt number for money that
  arrived once.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('dbo.t_mdm_payment_receipts')
                 AND name = 'UQ_t_mdm_payment_receipts_PaymentId')
BEGIN
    PRINT '    Creating UQ_t_mdm_payment_receipts_PaymentId ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_mdm_payment_receipts_PaymentId
        ON dbo.t_mdm_payment_receipts (PaymentId)
        WHERE Is_Deleted = 0;
END
ELSE
    PRINT '    UQ_t_mdm_payment_receipts_PaymentId already exists — skipped.';
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('dbo.t_mdm_payment_receipts')
                 AND name = 'UQ_t_mdm_payment_receipts_ReceiptNo')
BEGIN
    PRINT '    Creating UQ_t_mdm_payment_receipts_ReceiptNo ...';

    /*
      The last line of defence for the counter. If the allocation is ever
      got wrong, this turns a silent duplicate into a loud 2627 — the same
      relationship UQ_t_mdm_approval_requests_RequestNo has with RequestNo.
    */
    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_mdm_payment_receipts_ReceiptNo
        ON dbo.t_mdm_payment_receipts (ReceiptNo)
        WHERE Is_Deleted = 0;
END
ELSE
    PRINT '    UQ_t_mdm_payment_receipts_ReceiptNo already exists — skipped.';
GO

/*==============================================================================
  t_mdm_receipt_number_series — the counter, one row per IST year.

  🔴 WHY A SECOND SERIES TABLE AND NOT A ROW IN t_mdm_request_number_series
  ---------------------------------------------------------------------------
  That table's key is (RequestTypeId, SeriesYear) with an FK to
  m_mdm_request_types, because a request number is per request TYPE. A receipt
  is not a request type, and the only ways to reuse that table are to invent a
  fake request type for receipts, or to make its RequestTypeId nullable and its
  unique index conditional.

  Both make a working table ambiguous to serve a convenience. The counter
  PATTERN is what matters and is reused exactly (2.46); the row it counts is a
  different thing.
==============================================================================*/
IF OBJECT_ID('dbo.t_mdm_receipt_number_series', 'U') IS NULL
BEGIN
    PRINT '    Creating table [t_mdm_receipt_number_series] ...';

    CREATE TABLE dbo.t_mdm_receipt_number_series
    (
        SeriesId    int       IDENTITY(1, 1) NOT NULL,
        SeriesYear  smallint  NOT NULL,
        LastNumber  int       NOT NULL
                    CONSTRAINT DF_t_mdm_receipt_number_series_LastNumber DEFAULT (0),

        Is_Active   tinyint   NOT NULL
                    CONSTRAINT DF_t_mdm_receipt_number_series_Is_Active  DEFAULT (1),
        Is_Deleted  tinyint   NOT NULL
                    CONSTRAINT DF_t_mdm_receipt_number_series_Is_Deleted DEFAULT (0),
        CreatedOn   datetime2 NOT NULL
                    CONSTRAINT DF_t_mdm_receipt_number_series_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy   bigint    NULL,
        ModifiedOn  datetime2 NULL,
        ModifiedBy  bigint    NULL,

        CONSTRAINT PK_t_mdm_receipt_number_series PRIMARY KEY CLUSTERED (SeriesId),
        CONSTRAINT CK_t_mdm_receipt_number_series_LastNumber CHECK (LastNumber >= 0),
        CONSTRAINT CK_t_mdm_receipt_number_series_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_mdm_receipt_number_series_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
    PRINT '    Table [t_mdm_receipt_number_series] already exists — skipped.';
GO

/*
  🔴 This index is what makes the first allocation of a year safe.

  Two sessions can both find no row for the new year and both try to INSERT
  one. This index makes one of them lose with a 2601/2627, which the allocator
  swallows — and then both continue to the UPDATE, which is what both actually
  needed. Exactly the mechanism USP_SubmitApprovalRequest relies on.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('dbo.t_mdm_receipt_number_series')
                 AND name = 'UQ_t_mdm_receipt_number_series_Year')
BEGIN
    PRINT '    Creating UQ_t_mdm_receipt_number_series_Year ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_mdm_receipt_number_series_Year
        ON dbo.t_mdm_receipt_number_series (SeriesYear)
        WHERE Is_Deleted = 0;
END
ELSE
    PRINT '    UQ_t_mdm_receipt_number_series_Year already exists — skipped.';
GO

/*==============================================================================
  BUILD GUARD — shape only, for the reason 031 recorded.

  🔴 Including the two CHECKs that carry the design: a receipt verified by an
  ADMIN must name the admin. If that constraint is ever dropped, this file
  fails rather than letting an untraceable money record become possible.
==============================================================================*/
DECLARE @missing nvarchar(400) = N'';

IF OBJECT_ID('dbo.t_mdm_payment_receipts', 'U') IS NULL
    SET @missing = @missing + N't_mdm_payment_receipts ';

IF OBJECT_ID('dbo.t_mdm_receipt_number_series', 'U') IS NULL
    SET @missing = @missing + N't_mdm_receipt_number_series ';

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = 'CK_t_mdm_payment_receipts_AdminHasUser')
    SET @missing = @missing + N'CK_AdminHasUser ';

IF NOT EXISTS (SELECT 1 FROM sys.check_constraints
               WHERE name = 'CK_t_mdm_payment_receipts_VerifiedVia')
    SET @missing = @missing + N'CK_VerifiedVia ';

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('dbo.t_mdm_payment_receipts')
                 AND name = 'UQ_t_mdm_payment_receipts_PaymentId')
    SET @missing = @missing + N'UQ_PaymentId ';

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('dbo.t_mdm_receipt_number_series')
                 AND name = 'UQ_t_mdm_receipt_number_series_Year')
    SET @missing = @missing + N'UQ_SeriesYear ';

/*
  ⚠️ A receipt table with no ModifiedOn is the immutability claim in the header.
  Asserted, because the next person to add an audit column across the schema
  would add it here too, and the comment alone would not stop them.
*/
IF EXISTS (SELECT 1 FROM sys.columns
           WHERE object_id = OBJECT_ID('dbo.t_mdm_payment_receipts') AND name = 'ModifiedOn')
    SET @missing = @missing + N'(ModifiedOn was ADDED — a receipt is immutable, see the header) ';

IF @missing <> N''
    RAISERROR('038_t_mdm_payment_receipts: problem after run: %s', 16, 1, @missing);
GO

PRINT '    Payment receipts ready (immutable, numbered per IST year).';
GO
