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

        /*
          Why it was rejected, as data rather than as prose.

          The remarks say it in words for the school to read; this says it in a
          way somebody can count. "How many registrations fail because the
          authorisation letter is wrong" is a question the business will ask,
          and grepping a free-text column is not an answer to it.

          NULL for an approve — nothing was rejected — and for a rejection
          recorded before this column existed.
        */
        RejectionReasonId   int               NULL,

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
        CONSTRAINT FK_t_mdm_request_approvals_m_mdm_rejection_reasons
            FOREIGN KEY (RejectionReasonId) REFERENCES dbo.m_mdm_rejection_reasons (RejectionReasonId),
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
  RejectionReasonId, added in Phase 2E.

  The column is in the CREATE above for a fresh database. This is the other
  path: a database that already exists, where CREATE never runs again.

  ⚠️ Both paths have to be here. A column that only appears in the CREATE is a
  column every existing environment silently lacks, and the failure surfaces as
  "invalid column name" from a procedure rather than from anything that names
  the migration.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE Name = N'RejectionReasonId'
                 AND Object_ID = OBJECT_ID(N'dbo.t_mdm_request_approvals'))
BEGIN
    PRINT '    Adding [RejectionReasonId] to [t_mdm_request_approvals] ...';

    ALTER TABLE dbo.t_mdm_request_approvals ADD RejectionReasonId int NULL;
END
GO
IF NOT EXISTS (SELECT 1 FROM sys.foreign_keys
               WHERE name = N'FK_t_mdm_request_approvals_m_mdm_rejection_reasons')
BEGIN
    PRINT '    Adding FK [FK_t_mdm_request_approvals_m_mdm_rejection_reasons] ...';

    ALTER TABLE dbo.t_mdm_request_approvals
        ADD CONSTRAINT FK_t_mdm_request_approvals_m_mdm_rejection_reasons
            FOREIGN KEY (RejectionReasonId) REFERENCES dbo.m_mdm_rejection_reasons (RejectionReasonId);
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
        INCLUDE (ActionTypeId, ActionByUserId, LevelNumber, Remarks, RejectionReasonId);
END
GO
/*------------------------------------------------------------------------------
  And the same for the index on an existing database: RejectionReasonId joined
  the result set, so it has to join the INCLUDE or the index stops covering and
  every trail read starts doing key lookups.

  DROP_EXISTING rather than DROP then CREATE — the index is never absent, so a
  read that lands mid-run does not fall back to a scan.
------------------------------------------------------------------------------*/
IF EXISTS (SELECT 1 FROM sys.indexes
           WHERE name = N'IX_t_mdm_request_approvals_RequestId'
             AND object_id = OBJECT_ID(N'dbo.t_mdm_request_approvals'))
   AND NOT EXISTS (
       SELECT 1
       FROM sys.index_columns ic
           INNER JOIN sys.indexes  i ON i.object_id = ic.object_id AND i.index_id = ic.index_id
           INNER JOIN sys.columns  c ON c.object_id = ic.object_id AND c.column_id = ic.column_id
       WHERE i.name  = N'IX_t_mdm_request_approvals_RequestId'
         AND i.object_id = OBJECT_ID(N'dbo.t_mdm_request_approvals')
         AND c.name  = N'RejectionReasonId')
BEGIN
    PRINT '    Rebuilding index [IX_t_mdm_request_approvals_RequestId] to cover RejectionReasonId ...';

    CREATE NONCLUSTERED INDEX IX_t_mdm_request_approvals_RequestId
        ON dbo.t_mdm_request_approvals (RequestId, ActionOn DESC)
        INCLUDE (ActionTypeId, ActionByUserId, LevelNumber, Remarks, RejectionReasonId)
        WITH (DROP_EXISTING = ON);
END
GO
