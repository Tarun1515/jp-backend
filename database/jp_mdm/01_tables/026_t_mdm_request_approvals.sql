/*==============================================================================
  jp_mdm — 026_t_mdm_request_approvals.sql

  The action trail — APPEND ONLY.

  🔴 Nothing in this table is ever UPDATEd. Each approve, reject or
  request-resubmit appends a row. The trail is the evidence of who decided what
  and when; an UPDATE would rewrite history, and the one time anybody reads this
  table is when a decision is being questioned.

  No RowVersion and no Uid: the request header owns both.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

-- Filtered indexes REQUIRE these, both to CREATE them and for any later
-- INSERT/UPDATE on the table (decision 2.29).
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_mdm_request_approvals' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_mdm_request_approvals] ...';

    CREATE TABLE dbo.t_mdm_request_approvals
    (
        ApprovalId          bigint            IDENTITY(1,1) NOT NULL,
        RequestId           bigint            NOT NULL,
        LevelNumber         tinyint           NOT NULL,
        ActionTypeId        int               NOT NULL,

        /*
          ⚠️ CROSS-DATABASE REFERENCE — jp_sso.t_sso_users.UserId. NO foreign key here, and
          there must never be one (decision 2.2): SQL Server cannot enforce a FK
          across databases. Validated in the procedure and the API instead.
          t_sso_users.UserId is bigint — verified against the live column.
        */
        ActionByUserId      bigint            NOT NULL,

        Remarks             nvarchar(1000)    NULL,
        -- Event timestamp: UTC datetime2 (decision 2.28).
        ActionOn            datetime2         NOT NULL CONSTRAINT DF_t_mdm_request_approvals_ActionOn DEFAULT (SYSUTCDATETIME()),
        IpAddress           varchar(45)       NULL,   -- 45 = longest IPv6 form

        Is_Active           tinyint           NOT NULL CONSTRAINT DF_t_mdm_request_approvals_Is_Active  DEFAULT (1),
        Is_Deleted          tinyint           NOT NULL CONSTRAINT DF_t_mdm_request_approvals_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2         NOT NULL CONSTRAINT DF_t_mdm_request_approvals_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint            NULL,
        ModifiedOn          datetime2         NULL,
        ModifiedBy          bigint            NULL,

        CONSTRAINT PK_t_mdm_request_approvals PRIMARY KEY CLUSTERED (ApprovalId),
        CONSTRAINT FK_t_mdm_request_approvals_t_mdm_approval_requests
            FOREIGN KEY (RequestId) REFERENCES dbo.t_mdm_approval_requests (RequestId),
        CONSTRAINT FK_t_mdm_request_approvals_m_mdm_action_types
            FOREIGN KEY (ActionTypeId) REFERENCES dbo.m_mdm_action_types (ActionTypeId),
        CONSTRAINT CK_t_mdm_request_approvals_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_mdm_request_approvals_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_mdm_request_approvals] already exists — skipped.';
END
GO
/*------------------------------------------------------------------------------
  The trail for one request, newest first — how USP_GetApprovalRequestById
  reads it. INCLUDE covers the whole result set so it never touches the table.

  Deliberately NOT unique: a request can legitimately be rejected, resubmitted
  and rejected again at the same level.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_mdm_request_approvals_RequestId' AND object_id = OBJECT_ID('dbo.t_mdm_request_approvals'))
BEGIN
    PRINT '    Creating index [IX_t_mdm_request_approvals_RequestId] ...';

    CREATE NONCLUSTERED INDEX IX_t_mdm_request_approvals_RequestId
        ON dbo.t_mdm_request_approvals (RequestId, ActionOn DESC)
        INCLUDE (ActionTypeId, ActionByUserId, LevelNumber, Remarks);
END
GO
