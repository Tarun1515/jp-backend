/*==============================================================================
  jp_app — 004_t_app_subscriptions.sql

  Who is on which plan.

  ⚠️ PULLED FORWARD from Phase 2.5 by Phase 2F, for the same reason as the
  branches table: provisioning happens in 2F, and every account has a plan from
  the moment it exists. See m_mdm_plans for the full argument.

  ---------------------------------------------------------------------------
  🔴 OwnerUid IS A Uid, NOT AN ID, AND THAT IS DELIBERATE
  ---------------------------------------------------------------------------
  A school's subscription belongs to its ORGANISATION, which lives in jp_sso.
  A teacher's will belong to their user, also jp_sso. Neither can be a foreign
  key from here (decision 2.2), so this stores the Uid — the only key that
  crosses a database boundary in this system — rather than an id whose meaning
  depends on which table you happened to mean.

  One column, two kinds of owner, distinguished by the plan's UserTypeId. That
  is not elegant, and the alternative — two nullable columns with a check
  constraint keeping exactly one populated — is worse in every way that
  matters: it doubles every query and the check is the thing that gets dropped.

  ⚠️ TEACHER SUBSCRIPTIONS ARE NOT CREATED YET. Teachers have no profile row
  (G12) and nothing to hang one off. Phase 3 must do THREE things: create
  t_app_teachers, backfill a profile for every teacher who registered before it
  existed, AND assign TEACHER_FREE to all of them. A Phase 3 that does only the
  first leaves every early teacher broken in a new way.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_subscriptions' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_subscriptions] ...';

    CREATE TABLE dbo.t_app_subscriptions
    (
        SubscriptionId      bigint            IDENTITY(1,1) NOT NULL,
        SubscriptionUid     uniqueidentifier  NOT NULL CONSTRAINT DF_t_app_subscriptions_SubscriptionUid DEFAULT (NEWID()),

        /*
          ⚠️ CROSS-DATABASE — jp_sso. The organisation for a school, the user
          for a teacher. No foreign key, and never one (decision 2.2).
        */
        OwnerUid            uniqueidentifier  NOT NULL,

        /*
          ⚠️ CROSS-DATABASE — m_mdm_plans in jp_mdm. No foreign key either, for
          the same reason. Resolved by the API, which reads the plan from jp_mdm
          and passes the id in — the same shape the whole orchestration takes.
        */
        PlanId              int               NOT NULL,

        -- Instants, UTC (decision 2.28). EndsOn NULL = does not expire, which
        -- is what both free plans are.
        StartsOn            datetime2         NOT NULL CONSTRAINT DF_t_app_subscriptions_StartsOn DEFAULT (SYSUTCDATETIME()),
        EndsOn              datetime2         NULL,

        -- ⚠️ CROSS-DATABASE — m_mdm_subscription_status. 1 = Active.
        StatusId            int               NOT NULL CONSTRAINT DF_t_app_subscriptions_StatusId DEFAULT (1),

        AutoRenew           tinyint           NOT NULL CONSTRAINT DF_t_app_subscriptions_AutoRenew DEFAULT (0),

        Is_Active           tinyint           NOT NULL CONSTRAINT DF_t_app_subscriptions_Is_Active  DEFAULT (1),
        Is_Deleted          tinyint           NOT NULL CONSTRAINT DF_t_app_subscriptions_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2         NOT NULL CONSTRAINT DF_t_app_subscriptions_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint            NULL,
        ModifiedOn          datetime2         NULL,
        ModifiedBy          bigint            NULL,
        RowVersion          int               NOT NULL CONSTRAINT DF_t_app_subscriptions_RowVersion DEFAULT (1),

        CONSTRAINT PK_t_app_subscriptions PRIMARY KEY CLUSTERED (SubscriptionId),
        CONSTRAINT CK_t_app_subscriptions_AutoRenew  CHECK (AutoRenew  IN (0, 1)),
        CONSTRAINT CK_t_app_subscriptions_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_subscriptions_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_subscriptions] already exists — skipped.';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_subscriptions_SubscriptionUid' AND object_id = OBJECT_ID('dbo.t_app_subscriptions'))
BEGIN
    PRINT '    Creating index [UQ_t_app_subscriptions_SubscriptionUid] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_subscriptions_SubscriptionUid
        ON dbo.t_app_subscriptions (SubscriptionUid);
END
GO
/*------------------------------------------------------------------------------
  🔴 ONE ACTIVE SUBSCRIPTION PER OWNER.

  The third guard that makes provisioning safe to repeat, alongside
  t_app_schools.SourceRequestUid and the one-head-office index.

  It also states the rule the Phase 2.5 engine will depend on: "what plan is
  this school on" has exactly one answer. An upgrade closes the old row before
  opening the new one — which this index forces, rather than leaving it to be
  remembered.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_subscriptions_OneActivePerOwner' AND object_id = OBJECT_ID('dbo.t_app_subscriptions'))
BEGIN
    PRINT '    Creating index [UQ_t_app_subscriptions_OneActivePerOwner] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_subscriptions_OneActivePerOwner
        ON dbo.t_app_subscriptions (OwnerUid)
        WHERE StatusId = 1 AND Is_Deleted = 0;
END
GO
