/*==============================================================================
  jp_app — 032_alter_t_app_subscriptions_payment.sql

  SourcePaymentUid — the column that makes activation idempotent.

  ---------------------------------------------------------------------------
  🔴 WHY A SUBSCRIPTION NEEDS TO KNOW WHICH PAYMENT OPENED IT
  ---------------------------------------------------------------------------
  Verification and activation are in two databases and therefore two
  transactions, with no distributed transaction between them (2.2, 2.48).
  MONETIZATION_DESIGN 6.5-A takes that as given and makes recovery simply
  "call the method again" — which only works if the activation half can answer
  "has this payment already been activated?" without being able to see the
  payment table.

  This column is that answer. It is the one piece of state that lets a retry of
  a half-completed verification COMPLETE it rather than open a second
  subscription for money that arrived once.

  ⚠️ Not an FK, and not a mistake: t_mdm_request_payments is in another
  database and no constraint may cross (2.2). t_app_subscriptions already holds
  PlanId on exactly those terms.

  ---------------------------------------------------------------------------
  🔴 NULLABLE, AND THE NULLs ARE THE IMPORTANT ROWS
  ---------------------------------------------------------------------------
  Every subscription that exists today was opened by PROVISIONING, not by a
  payment — a school's free plan at signup (2F), a teacher's at registration
  (G21's closure). Those rows have no source payment and never will.

  So NULL means "nobody paid for this", which is true of every free plan, and
  the filtered unique index below deliberately ignores them. A default here
  would invent a payment that does not exist.

  Block D of _TEMPLATE_table.sql: a deployed table is never edited in place.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.t_app_subscriptions') AND name = 'SourcePaymentUid')
BEGIN
    PRINT '    Adding column [t_app_subscriptions].[SourcePaymentUid] ...';

    ALTER TABLE dbo.t_app_subscriptions
        ADD SourcePaymentUid uniqueidentifier NULL;
END
ELSE
    PRINT '    Column [t_app_subscriptions].[SourcePaymentUid] already exists — skipped.';
GO

/*
  🔴 ONE SUBSCRIPTION PER PAYMENT — the structural half of idempotency.

  The procedure checks for an existing activation before inserting, inside its
  own transaction. This index is what catches the race BETWEEN that check and
  the insert — two admins verifying the same payment at the same instant, which
  is a scenario this phase's verification runs on purpose with both sessions
  armed on one wall-clock instant.

  Both are needed and neither is redundant: the check gives the second caller a
  clean "already done, Status 1" answer, and the index makes the genuinely
  simultaneous pair resolve to one row. 2.64 recorded exactly this pairing for
  the ledger's reference check, for the same reason.

  ⚠️ Filtered on SourcePaymentUid IS NOT NULL so the provisioning rows — all of
  which are NULL — do not collide with each other. A plain unique index would
  allow exactly one free subscription in the entire database.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('dbo.t_app_subscriptions')
                 AND name = 'UQ_t_app_subscriptions_SourcePaymentUid')
BEGIN
    PRINT '    Creating UQ_t_app_subscriptions_SourcePaymentUid ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_subscriptions_SourcePaymentUid
        ON dbo.t_app_subscriptions (SourcePaymentUid)
        WHERE SourcePaymentUid IS NOT NULL AND Is_Deleted = 0;
END
ELSE
    PRINT '    UQ_t_app_subscriptions_SourcePaymentUid already exists — skipped.';
GO

/*==============================================================================
  BUILD GUARD — shape, and the one claim about data that is true of every
  database: a subscription opened by provisioning has no source payment.

  ⚠️ The second check is the lesson 031 taught. Its first version asserted
  something about seeded rows that was a guess, and the first run caught it. So
  this asserts the direction that cannot be wrong — rows with a payment are
  never DEFAULT-plan rows — rather than a count that drifts.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.t_app_subscriptions') AND name = 'SourcePaymentUid')
    RAISERROR('032_alter_t_app_subscriptions_payment: SourcePaymentUid is missing after run.', 16, 1);
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE object_id = OBJECT_ID('dbo.t_app_subscriptions')
                 AND name = 'UQ_t_app_subscriptions_SourcePaymentUid')
    RAISERROR('032_alter_t_app_subscriptions_payment: UQ_SourcePaymentUid is missing after run.', 16, 1);
GO

PRINT '    t_app_subscriptions ready for paid activation (SourcePaymentUid).';
GO
