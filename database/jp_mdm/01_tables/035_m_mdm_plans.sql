/*==============================================================================
  jp_mdm — 035_m_mdm_plans.sql

  Subscription plans, and the subscription statuses that go with them.

  ⚠️ PULLED FORWARD from Phase 2.5 by Phase 2F. Monetization proper — features,
  gating modes, credits, consumption, invoices — is NOT here and should not be
  added here. Only the piece that cannot wait is.

  ---------------------------------------------------------------------------
  🔴 WHY IT CANNOT WAIT
  ---------------------------------------------------------------------------
  Provisioning happens in Phase 2F. The rule is: EVERY ACCOUNT HAS A PLAN FROM
  THE MOMENT IT EXISTS. There is no "no subscription" state.

  A nullable subscription means a null check in every gated path added from
  Phase 3 onward, and one of them will be missed — the miss being a school that
  quietly gets everything, or quietly gets nothing, with no error to notice.
  Assigning a plan inside the provisioning transaction means the engine in
  Phase 2.5 arrives to a table where every row already has one, with no legacy
  to reconcile.

  ---------------------------------------------------------------------------
  ⚠️ TWO ROWS ONLY, AND NEITHER HAS A PRICE
  ---------------------------------------------------------------------------
  Pricing is not finalised. The public FAQ says so in as many words. A seeded
  paid tier is a number that gets quoted back at us by a client who read it in
  a database we shipped, so there is exactly one free plan per user type and
  nothing else. Adding tiers is a Phase 2.5 decision made with the client.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*==============================================================================
  m_mdm_subscription_status

  Not asked for by name, added because StatusId has to mean something. Three
  rows and a FK beats a tinyint with the meanings written in a comment — the
  comment is what drifts.
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_mdm_subscription_status' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_mdm_subscription_status] ...';

    CREATE TABLE dbo.m_mdm_subscription_status
    (
        SubscriptionStatusId int            NOT NULL,
        Code                 varchar(30)    NOT NULL,
        Name                 nvarchar(100)  NOT NULL,
        DisplayOrder         int            NOT NULL CONSTRAINT DF_m_mdm_subscription_status_DisplayOrder DEFAULT (0),

        Is_Active            tinyint        NOT NULL CONSTRAINT DF_m_mdm_subscription_status_Is_Active  DEFAULT (1),
        Is_Deleted           tinyint        NOT NULL CONSTRAINT DF_m_mdm_subscription_status_Is_Deleted DEFAULT (0),
        CreatedOn            datetime2      NOT NULL CONSTRAINT DF_m_mdm_subscription_status_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy            bigint         NULL,
        ModifiedOn           datetime2      NULL,
        ModifiedBy           bigint         NULL,

        CONSTRAINT PK_m_mdm_subscription_status PRIMARY KEY CLUSTERED (SubscriptionStatusId),
        CONSTRAINT CK_m_mdm_subscription_status_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_m_mdm_subscription_status_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [m_mdm_subscription_status] already exists — skipped.';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_m_mdm_subscription_status_Code' AND object_id = OBJECT_ID('dbo.m_mdm_subscription_status'))
BEGIN
    PRINT '    Creating index [UQ_m_mdm_subscription_status_Code] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_m_mdm_subscription_status_Code
        ON dbo.m_mdm_subscription_status (Code)
        WHERE Is_Deleted = 0;
END
GO


/*==============================================================================
  m_mdm_plans
==============================================================================*/
IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_mdm_plans' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_mdm_plans] ...';

    CREATE TABLE dbo.m_mdm_plans
    (
        PlanId              int               IDENTITY(1,1) NOT NULL,
        PlanCode            varchar(30)       NOT NULL,

        /*
          ⚠️ CROSS-DATABASE MEANING — m_sso_user_types in jp_sso. No foreign
          key and never one (decision 2.2). 2 = School, 3 = Teacher.

          A plan belongs to one user type: a school plan offered to a teacher
          is not a pricing mistake, it is a plan whose limits mean nothing.
        */
        UserTypeId          int               NOT NULL,

        Name                nvarchar(100)     NOT NULL,

        /*
          NULL means it does not expire. The free plans are perpetual, and
          giving them an end date would mean writing a renewal job in Phase 2F
          for something nobody is paying for.
        */
        DurationDays        int               NULL,

        Price               decimal(10, 2)    NOT NULL CONSTRAINT DF_m_mdm_plans_Price DEFAULT (0),

        /*
          🔴 The plan a new account of this user type gets. Exactly one per
          user type, enforced by a filtered unique index below — provisioning
          resolves the default by user type, and two defaults would make that
          resolution arbitrary.
        */
        IsDefault           tinyint           NOT NULL CONSTRAINT DF_m_mdm_plans_IsDefault DEFAULT (0),

        -- Whether it appears on a public pricing page. Nothing reads this yet.
        IsPublic            tinyint           NOT NULL CONSTRAINT DF_m_mdm_plans_IsPublic DEFAULT (1),

        DisplayOrder        int               NOT NULL CONSTRAINT DF_m_mdm_plans_DisplayOrder DEFAULT (0),

        Is_Active           tinyint           NOT NULL CONSTRAINT DF_m_mdm_plans_Is_Active  DEFAULT (1),
        Is_Deleted          tinyint           NOT NULL CONSTRAINT DF_m_mdm_plans_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2         NOT NULL CONSTRAINT DF_m_mdm_plans_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint            NULL,
        ModifiedOn          datetime2         NULL,
        ModifiedBy          bigint            NULL,

        CONSTRAINT PK_m_mdm_plans PRIMARY KEY CLUSTERED (PlanId),
        CONSTRAINT CK_m_mdm_plans_IsDefault CHECK (IsDefault IN (0, 1)),
        CONSTRAINT CK_m_mdm_plans_IsPublic  CHECK (IsPublic  IN (0, 1)),
        CONSTRAINT CK_m_mdm_plans_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_m_mdm_plans_Is_Deleted CHECK (Is_Deleted IN (0, 1)),
        CONSTRAINT CK_m_mdm_plans_Price CHECK (Price >= 0)
    );
END
ELSE
BEGIN
    PRINT '    Table [m_mdm_plans] already exists — skipped.';
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_m_mdm_plans_PlanCode' AND object_id = OBJECT_ID('dbo.m_mdm_plans'))
BEGIN
    PRINT '    Creating index [UQ_m_mdm_plans_PlanCode] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_m_mdm_plans_PlanCode
        ON dbo.m_mdm_plans (PlanCode)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  🔴 ONE DEFAULT PLAN PER USER TYPE.

  Provisioning asks "what does a new school get" and expects one answer. Two
  rows flagged default makes that a lottery decided by whichever the query plan
  happened to read first — and the symptom is one school on the wrong plan
  months later, with nothing in any log about it.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_m_mdm_plans_OneDefaultPerUserType' AND object_id = OBJECT_ID('dbo.m_mdm_plans'))
BEGIN
    PRINT '    Creating index [UQ_m_mdm_plans_OneDefaultPerUserType] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_m_mdm_plans_OneDefaultPerUserType
        ON dbo.m_mdm_plans (UserTypeId)
        WHERE IsDefault = 1 AND Is_Deleted = 0;
END
GO
