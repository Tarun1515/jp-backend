/*==============================================================================
  jp_mdm — 028_t_mdm_request_payments.sql

  Payment against a request.

  ⚠️ NOT USED IN MVP. The table exists because adding a payment table later, to
  a schema whose requests already carry foreign keys, is a migration rather than
  a script. Standard columns apply here exactly as everywhere else — the fact
  that nothing writes to it yet is not a reason to cut corners in its shape.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

-- Filtered indexes REQUIRE these, both to CREATE them and for any later
-- INSERT/UPDATE on the table (decision 2.29).
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_mdm_request_payments' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_mdm_request_payments] ...';

    CREATE TABLE dbo.t_mdm_request_payments
    (
        PaymentId           bigint            IDENTITY(1,1) NOT NULL,
        RequestId           bigint            NOT NULL,

        -- Plan lives in jp_app and does not exist yet. Plain int, no FK.
        PlanId              int               NULL,

        Amount              decimal(18,2)     NOT NULL,
        PaymentModeId       int               NOT NULL,
        GatewayRefNo        varchar(100)      NULL,
        PaymentStatusId     int               NOT NULL,
        -- Event timestamp: UTC datetime2 (decision 2.28).
        PaidOn              datetime2         NULL,

        /*
          ⚠️ CROSS-DATABASE REFERENCE — jp_sso.t_sso_users.UserId. NO foreign key here, and
          there must never be one (decision 2.2): SQL Server cannot enforce a FK
          across databases. Validated in the procedure and the API instead.
          t_sso_users.UserId is bigint — verified against the live column.
        */
        VerifiedByUserId    bigint            NULL,

        Is_Active           tinyint           NOT NULL CONSTRAINT DF_t_mdm_request_payments_Is_Active  DEFAULT (1),
        Is_Deleted          tinyint           NOT NULL CONSTRAINT DF_t_mdm_request_payments_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2         NOT NULL CONSTRAINT DF_t_mdm_request_payments_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint            NULL,
        ModifiedOn          datetime2         NULL,
        ModifiedBy          bigint            NULL,
        RowVersion          int               NOT NULL CONSTRAINT DF_t_mdm_request_payments_RowVersion DEFAULT (1),

        CONSTRAINT PK_t_mdm_request_payments PRIMARY KEY CLUSTERED (PaymentId),
        CONSTRAINT FK_t_mdm_request_payments_t_mdm_approval_requests
            FOREIGN KEY (RequestId) REFERENCES dbo.t_mdm_approval_requests (RequestId),
        CONSTRAINT FK_t_mdm_request_payments_m_mdm_payment_modes
            FOREIGN KEY (PaymentModeId) REFERENCES dbo.m_mdm_payment_modes (PaymentModeId),
        CONSTRAINT FK_t_mdm_request_payments_m_mdm_payment_status
            FOREIGN KEY (PaymentStatusId) REFERENCES dbo.m_mdm_payment_status (PaymentStatusId),
        CONSTRAINT CK_t_mdm_request_payments_Amount    CHECK (Amount >= 0),
        CONSTRAINT CK_t_mdm_request_payments_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_mdm_request_payments_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_mdm_request_payments] already exists — skipped.';
END
GO
/*------------------------------------------------------------------------------
  A gateway reference identifies one payment at the provider. Two rows
  carrying the same one means a webhook was processed twice — which is exactly
  how a double refund happens.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_mdm_request_payments_GatewayRefNo' AND object_id = OBJECT_ID('dbo.t_mdm_request_payments'))
BEGIN
    PRINT '    Creating index [UQ_t_mdm_request_payments_GatewayRefNo] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_mdm_request_payments_GatewayRefNo
        ON dbo.t_mdm_request_payments (GatewayRefNo)
        WHERE Is_Deleted = 0 AND GatewayRefNo IS NOT NULL;
END
GO
