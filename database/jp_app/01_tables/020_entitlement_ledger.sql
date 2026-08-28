/*==============================================================================
  jp_app — 020_entitlement_ledger.sql

  The append-only entitlement ledger, and its three small masters. Phase 2.5.

  Governed by jp-docs/MONETIZATION_DESIGN.md — Decisions 4, 5 and 6.

  ---------------------------------------------------------------------------
  🔴 THE PROHIBITION THIS ENGINE CARRIES EVERYWHERE (2.56 — LOCKED)
  ---------------------------------------------------------------------------
  The entitlement engine and contact unlock never reference each other, in
  either direction.

  Nothing in this file, and nothing that reads it, may appear in
  fn_TeacherContactUnlocked — and that function's two paths (the teacher
  applied, or accepted an invitation) may never appear here. A subscription
  buys CAPABILITY: whether a school may search at all, how many invites it may
  send. It never buys a teacher's phone number.

  If a requirement seems to need a plan check inside contact unlock, the
  requirement is being described wrongly: what is sold is reach, and reach is
  invites.

  ---------------------------------------------------------------------------
  WHAT A LEDGER IS FOR HERE
  ---------------------------------------------------------------------------
  Every balance in this system is RECOMPUTABLE from these rows. There is no
  cached balance column and no stored counter, so there is nothing that can
  drift out of agreement with the truth.

  - Credit balance  = SUM(Units) over live rows for (OwnerUid, FeatureId)
  - Quota used      = COUNT of live quota-sourced consumes inside the period

  ⚠️ Quota is DERIVED, not reset. There is no scheduled job, because a job that
  must run at every IST month boundary for every owner is a job that will one
  day not run — and its failure is silent: quotas simply do not reset and
  customers quietly lose allowance. A new period starts empty because it is
  new. See fn_QuotaPeriodForUtc.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  m_app_ledger_entry_types

  Four kinds of row. Grant and Consume are MVP; Reversal is MVP (refunds and
  the support remedy for stuck credits); Expiry exists so Phase 6.5 adds rows
  rather than reshaping the table.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_app_ledger_entry_types' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_app_ledger_entry_types] ...';

    CREATE TABLE dbo.m_app_ledger_entry_types
    (
        EntryTypeId   tinyint        NOT NULL,
        Code          varchar(30)    NOT NULL,
        Name          nvarchar(100)  NOT NULL,
        DisplayOrder  int            NOT NULL CONSTRAINT DF_m_app_ledger_entry_types_DisplayOrder DEFAULT (0),

        Is_Active     tinyint        NOT NULL CONSTRAINT DF_m_app_ledger_entry_types_Is_Active  DEFAULT (1),
        Is_Deleted    tinyint        NOT NULL CONSTRAINT DF_m_app_ledger_entry_types_Is_Deleted DEFAULT (0),
        CreatedOn     datetime2      NOT NULL CONSTRAINT DF_m_app_ledger_entry_types_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy     bigint         NULL,
        ModifiedOn    datetime2      NULL,
        ModifiedBy    bigint         NULL,

        CONSTRAINT PK_m_app_ledger_entry_types PRIMARY KEY CLUSTERED (EntryTypeId),
        CONSTRAINT CK_m_app_ledger_entry_types_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_m_app_ledger_entry_types_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );

    INSERT INTO dbo.m_app_ledger_entry_types (EntryTypeId, Code, Name, DisplayOrder)
    VALUES (1, 'GRANT',    N'Grant',    1),
           (2, 'CONSUME',  N'Consume',  2),
           (3, 'REVERSAL', N'Reversal', 3),
           (4, 'EXPIRY',   N'Expiry',   4);
END
ELSE
BEGIN
    PRINT '    Table [m_app_ledger_entry_types] already exists — skipped.';
END
GO


/*==============================================================================
  m_app_ledger_sources

  Which pocket a consume came out of. NULL on non-consume rows.

  🔴 This is what makes "quota before credits" auditable after the fact. Without
  it the ledger would record that four units were spent and be unable to say
  whether the customer's included allowance or their purchased credits paid for
  them — which is exactly the question a billing dispute asks.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_app_ledger_sources' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_app_ledger_sources] ...';

    CREATE TABLE dbo.m_app_ledger_sources
    (
        SourceId      tinyint        NOT NULL,
        Code          varchar(30)    NOT NULL,
        Name          nvarchar(100)  NOT NULL,
        DisplayOrder  int            NOT NULL CONSTRAINT DF_m_app_ledger_sources_DisplayOrder DEFAULT (0),

        Is_Active     tinyint        NOT NULL CONSTRAINT DF_m_app_ledger_sources_Is_Active  DEFAULT (1),
        Is_Deleted    tinyint        NOT NULL CONSTRAINT DF_m_app_ledger_sources_Is_Deleted DEFAULT (0),
        CreatedOn     datetime2      NOT NULL CONSTRAINT DF_m_app_ledger_sources_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy     bigint         NULL,
        ModifiedOn    datetime2      NULL,
        ModifiedBy    bigint         NULL,

        CONSTRAINT PK_m_app_ledger_sources PRIMARY KEY CLUSTERED (SourceId),
        CONSTRAINT CK_m_app_ledger_sources_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_m_app_ledger_sources_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );

    INSERT INTO dbo.m_app_ledger_sources (SourceId, Code, Name, DisplayOrder)
    VALUES (1, 'QUOTA',  N'Plan quota', 1),
           (2, 'CREDIT', N'Credits',    2);
END
ELSE
BEGIN
    PRINT '    Table [m_app_ledger_sources] already exists — skipped.';
END
GO


/*==============================================================================
  m_app_ref_entity_types

  What a consume was FOR. This is the idempotency key's type half.

  ⚠️ MANUAL exists so an admin grant or correction carries a reference like
  everything else. It is the only type whose RefEntityUid is not a row in some
  other table — it is a NEWID() minted at the moment of the decision, so that
  two separate support actions never collide with each other.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_app_ref_entity_types' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_app_ref_entity_types] ...';

    CREATE TABLE dbo.m_app_ref_entity_types
    (
        RefEntityTypeId  tinyint        NOT NULL,
        Code             varchar(30)    NOT NULL,
        Name             nvarchar(100)  NOT NULL,
        DisplayOrder     int            NOT NULL CONSTRAINT DF_m_app_ref_entity_types_DisplayOrder DEFAULT (0),

        Is_Active        tinyint        NOT NULL CONSTRAINT DF_m_app_ref_entity_types_Is_Active  DEFAULT (1),
        Is_Deleted       tinyint        NOT NULL CONSTRAINT DF_m_app_ref_entity_types_Is_Deleted DEFAULT (0),
        CreatedOn        datetime2      NOT NULL CONSTRAINT DF_m_app_ref_entity_types_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy        bigint         NULL,
        ModifiedOn       datetime2      NULL,
        ModifiedBy       bigint         NULL,

        CONSTRAINT PK_m_app_ref_entity_types PRIMARY KEY CLUSTERED (RefEntityTypeId),
        CONSTRAINT CK_m_app_ref_entity_types_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_m_app_ref_entity_types_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );

    INSERT INTO dbo.m_app_ref_entity_types (RefEntityTypeId, Code, Name, DisplayOrder)
    VALUES (1, 'JOB',         N'Job',         1),
           (2, 'INVITE',      N'Invitation',  2),
           (3, 'APPLICATION', N'Application', 3),
           (4, 'MANUAL',      N'Manual',      4);
END
ELSE
BEGIN
    PRINT '    Table [m_app_ref_entity_types] already exists — skipped.';
END
GO


/*==============================================================================
  t_app_feature_ledger

  Append-only. Every entitlement event, and the only source of every balance.

  ---------------------------------------------------------------------------
  🔴 A BOOLEAN CHECK WRITES NOTHING HERE
  ---------------------------------------------------------------------------
  A row that can never change a balance is not a ledger entry — it is an access
  log wearing a ledger's clothes. A school browsing search results all
  afternoon would write thousands of such rows in the same table where every
  row that DOES change a number lives, and every balance query would need a
  filter forever. The day somebody forgets that filter, the sums still come out
  right while every row count in every report is wrong.

  Access auditing, if it is ever wanted, belongs in its own table with its own
  retention policy.

  ---------------------------------------------------------------------------
  ⚠️ APPEND-ONLY HAS EXACTLY ONE EXCEPTION, AND IT IS ReversedOn
  ---------------------------------------------------------------------------
  A consume is never updated and never deleted. A mistake is corrected by a
  REVERSAL row pointing at it (ReversalOfEntryId) — and by stamping ReversedOn
  on the original, in the same transaction.

  That stamp is the one after-the-fact write in this table, and it exists
  because the idempotency index needs a filterable column. A reversal cannot
  free the reference if the freeing fact lives only in a second row.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_feature_ledger' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_feature_ledger] ...';

    CREATE TABLE dbo.t_app_feature_ledger
    (
        EntryId            bigint             IDENTITY(1,1) NOT NULL,
        EntryUid           uniqueidentifier   NOT NULL CONSTRAINT DF_t_app_feature_ledger_EntryUid DEFAULT (NEWID()),

        /*
          The organisation for a school, the user for a teacher (2.51) — the
          same rule t_app_subscriptions.OwnerUid follows, and it must be the
          same value or the subscription lock protects nothing.

          🔴 Never a client parameter. The API takes it from the token's orgUid
          or uuid claim (2.39).
        */
        OwnerUid           uniqueidentifier   NOT NULL,

        /*
          ⚠️ CROSS-DATABASE — m_mdm_features in jp_mdm. No foreign key and never
          one (2.2). The API resolves the feature there and passes the id here,
          the same shape provisioning already uses to carry PlanId across.
        */
        FeatureId          int                NOT NULL,

        EntryTypeId        tinyint            NOT NULL,

        /*
          Consumes only; NULL on grants, reversals and expiries. Which pocket
          paid — see m_app_ledger_sources.
        */
        SourceId           tinyint            NULL,

        /*
          SIGNED. Consumes and expiries are negative; grants and reversals are
          positive. This is what lets a balance be a plain SUM rather than a
          CASE over entry types — and a CASE that has to be repeated in every
          balance query is a CASE that will eventually be written differently
          in two of them.
        */
        Units              int                NOT NULL,

        /*
          What this consume was for. Together with FeatureId these form the
          idempotency key — see UQ_t_app_feature_ledger_Reference below.
        */
        RefEntityTypeId    tinyint            NULL,
        RefEntityUid       uniqueidentifier   NULL,

        -- Reversal rows point at what they reverse.
        ReversalOfEntryId  bigint             NULL,

        -- Stamped on the ORIGINAL when it is reversed. The one late write.
        ReversedOn         datetime2          NULL,

        /*
          When the event happened, in UTC (2.28). Distinct from CreatedOn:
          CreatedOn is when the row was written, OccurredOn is when the thing
          happened. They are the same today and will not be the day a backdated
          correction is entered.

          🔴 The period window filters on THIS column.
        */
        OccurredOn         datetime2          NOT NULL CONSTRAINT DF_t_app_feature_ledger_OccurredOn DEFAULT (SYSUTCDATETIME()),

        Notes              nvarchar(400)      NULL,

        Is_Active          tinyint            NOT NULL CONSTRAINT DF_t_app_feature_ledger_Is_Active  DEFAULT (1),
        Is_Deleted         tinyint            NOT NULL CONSTRAINT DF_t_app_feature_ledger_Is_Deleted DEFAULT (0),
        CreatedOn          datetime2          NOT NULL CONSTRAINT DF_t_app_feature_ledger_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy          bigint             NULL,
        ModifiedOn         datetime2          NULL,
        ModifiedBy         bigint             NULL,

        CONSTRAINT PK_t_app_feature_ledger PRIMARY KEY CLUSTERED (EntryId),

        CONSTRAINT FK_t_app_feature_ledger_EntryType
            FOREIGN KEY (EntryTypeId)     REFERENCES dbo.m_app_ledger_entry_types (EntryTypeId),
        CONSTRAINT FK_t_app_feature_ledger_Source
            FOREIGN KEY (SourceId)        REFERENCES dbo.m_app_ledger_sources (SourceId),
        CONSTRAINT FK_t_app_feature_ledger_RefEntityType
            FOREIGN KEY (RefEntityTypeId) REFERENCES dbo.m_app_ref_entity_types (RefEntityTypeId),
        CONSTRAINT FK_t_app_feature_ledger_ReversalOf
            FOREIGN KEY (ReversalOfEntryId) REFERENCES dbo.t_app_feature_ledger (EntryId),

        /*
          A consume must say which pocket paid; nothing else may claim one.
          Without this, a grant with SourceId = CREDIT would be counted by the
          quota-usage query as if it were spending.
        */
        CONSTRAINT CK_t_app_feature_ledger_SourceOnConsume
            CHECK ((EntryTypeId = 2 AND SourceId IS NOT NULL)
                OR (EntryTypeId <> 2 AND SourceId IS NULL)),

        -- Only a reversal points at something, and a reversal must.
        CONSTRAINT CK_t_app_feature_ledger_ReversalOf
            CHECK ((EntryTypeId = 3 AND ReversalOfEntryId IS NOT NULL)
                OR (EntryTypeId <> 3 AND ReversalOfEntryId IS NULL)),

        /*
          Signs are structural, not conventional. A positive consume would make
          SUM(Units) grow when a customer spends.
        */
        CONSTRAINT CK_t_app_feature_ledger_UnitSign
            CHECK ((EntryTypeId IN (1, 3) AND Units > 0)      -- grant, reversal
                OR (EntryTypeId IN (2, 4) AND Units < 0)),    -- consume, expiry

        -- Both halves of a reference, or neither. A half key indexes nothing.
        CONSTRAINT CK_t_app_feature_ledger_Reference
            CHECK ((RefEntityTypeId IS NULL     AND RefEntityUid IS NULL)
                OR (RefEntityTypeId IS NOT NULL AND RefEntityUid IS NOT NULL)),

        CONSTRAINT CK_t_app_feature_ledger_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_feature_ledger_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_feature_ledger] already exists — skipped.';
END
GO

/*------------------------------------------------------------------------------
  🔴 IDEMPOTENCY. This index IS the mechanism — not a check in a procedure.

  The caller passes what it is doing (RefEntityTypeId = JOB, RefEntityUid = the
  job's Uid) and a second consume for the same action becomes impossible at the
  storage layer, where it cannot be raced.

  Three conditions in the filter, each load-bearing:

    Is_Deleted = 0        soft-deleted rows never constrain anything (2.4)

    EntryTypeId = 2       grants and reversals carry no reference and must not
                          collide with each other

    ReversedOn IS NULL    🔴 A REVERSED CONSUME FREES ITS REFERENCE. If we
                          refunded a job posting, that job may legitimately be
                          posted and charged again. Without this condition a
                          refund would permanently prevent the customer from
                          redoing the very thing they were refunded for — the
                          opposite of what a refund means.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_feature_ledger_Reference' AND object_id = OBJECT_ID('dbo.t_app_feature_ledger'))
BEGIN
    PRINT '    Creating index [UQ_t_app_feature_ledger_Reference] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_feature_ledger_Reference
        ON dbo.t_app_feature_ledger (FeatureId, RefEntityTypeId, RefEntityUid)
        WHERE Is_Deleted = 0 AND EntryTypeId = 2 AND ReversedOn IS NULL;
END
GO
/*------------------------------------------------------------------------------
  The period-count index.

  Every metered consume runs two aggregates inside the critical section: units
  used in this period, and the credit balance. Both filter on (OwnerUid,
  FeatureId) and the first adds a range on OccurredOn, so this covers both.

  INCLUDE carries everything the aggregates read, which keeps them off the
  clustered index entirely — worth having, because they run while a lock is
  held and every millisecond is a millisecond another session waits.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_feature_ledger_OwnerFeaturePeriod' AND object_id = OBJECT_ID('dbo.t_app_feature_ledger'))
BEGIN
    PRINT '    Creating index [IX_t_app_feature_ledger_OwnerFeaturePeriod] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_feature_ledger_OwnerFeaturePeriod
        ON dbo.t_app_feature_ledger (OwnerUid, FeatureId, OccurredOn)
        INCLUDE (EntryTypeId, SourceId, Units, ReversedOn)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  Reversal lookups — "has this entry been reversed, and by what".
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_feature_ledger_ReversalOf' AND object_id = OBJECT_ID('dbo.t_app_feature_ledger'))
BEGIN
    PRINT '    Creating index [IX_t_app_feature_ledger_ReversalOf] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_feature_ledger_ReversalOf
        ON dbo.t_app_feature_ledger (ReversalOfEntryId)
        WHERE ReversalOfEntryId IS NOT NULL AND Is_Deleted = 0;
END
GO

PRINT '    Entitlement ledger ready.';
GO
