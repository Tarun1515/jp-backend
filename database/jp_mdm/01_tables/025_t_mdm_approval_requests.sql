/*==============================================================================
  jp_mdm — 025_t_mdm_approval_requests.sql

  The approval request header — the aggregate root of the approval engine.

  One row per submission. The typed payload lives in a 1:1 details table
  (school or teacher), documents and the action trail hang off this row.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

-- Filtered indexes REQUIRE these, both to CREATE them and for any later
-- INSERT/UPDATE on the table (decision 2.29).
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_mdm_approval_requests' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_mdm_approval_requests] ...';

    CREATE TABLE dbo.t_mdm_approval_requests
    (
        RequestId           bigint            IDENTITY(1,1) NOT NULL,
        RequestUid          uniqueidentifier  NOT NULL CONSTRAINT DF_t_mdm_approval_requests_RequestUid DEFAULT (NEWID()),

        -- Human-facing reference, e.g. REG-SCH-2026-00001. Generated from a
        -- SEQUENCE in USP_SubmitApprovalRequest — never MAX()+1, which races.
        RequestNo           varchar(30)       NOT NULL,

        RequestTypeId       int               NOT NULL,
        StatusId            int               NOT NULL,
        CurrentApprovalLevel tinyint          NOT NULL CONSTRAINT DF_t_mdm_approval_requests_CurrentApprovalLevel DEFAULT (1),

        /*
          ⚠️ CROSS-DATABASE REFERENCE — jp_sso. There is NO foreign key here and
          there must never be one (decision 2.2). SQL Server cannot enforce a FK
          across databases, and adding one is not a "fix" — it will not compile.
          The value is validated in the stored procedure and in the API.
        */
        -- The thing being approved: a school, a teacher, a branch. Which table
        -- it lives in depends on RequestTypeId, so this cannot be a FK even
        -- within one database.
        EntityUid           uniqueidentifier  NOT NULL,
        OrganizationUid     uniqueidentifier  NULL,
        RequestorUserId     bigint            NOT NULL,   -- t_sso_users.UserId is bigint (verified)
        ApproverUserId      bigint            NULL,       -- currently assigned approver

        -- Event timestamps: UTC datetime2, never date (decision 2.28).
        SubmittedOn         datetime2         NOT NULL CONSTRAINT DF_t_mdm_approval_requests_SubmittedOn DEFAULT (SYSUTCDATETIME()),
        CompletedOn         datetime2         NULL,

        Is_Active           tinyint           NOT NULL CONSTRAINT DF_t_mdm_approval_requests_Is_Active  DEFAULT (1),
        Is_Deleted          tinyint           NOT NULL CONSTRAINT DF_t_mdm_approval_requests_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2         NOT NULL CONSTRAINT DF_t_mdm_approval_requests_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint            NULL,
        ModifiedOn          datetime2         NULL,
        ModifiedBy          bigint            NULL,
        -- Optimistic concurrency. A plain int the update proc increments and
        -- checks — NOT the SQL Server rowversion/timestamp type.
        RowVersion          int               NOT NULL CONSTRAINT DF_t_mdm_approval_requests_RowVersion DEFAULT (1),

        CONSTRAINT PK_t_mdm_approval_requests PRIMARY KEY CLUSTERED (RequestId),
        CONSTRAINT FK_t_mdm_approval_requests_m_mdm_request_types
            FOREIGN KEY (RequestTypeId) REFERENCES dbo.m_mdm_request_types (RequestTypeId),
        CONSTRAINT FK_t_mdm_approval_requests_m_mdm_approval_status
            FOREIGN KEY (StatusId) REFERENCES dbo.m_mdm_approval_status (ApprovalStatusId),
        CONSTRAINT CK_t_mdm_approval_requests_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_mdm_approval_requests_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_mdm_approval_requests] already exists — skipped.';
END
GO
/*------------------------------------------------------------------------------
  The public identifier. UNFILTERED on purpose: a Uid must never be reused,
  even after a soft delete, or an old URL resolves to a different request.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_mdm_approval_requests_RequestUid' AND object_id = OBJECT_ID('dbo.t_mdm_approval_requests'))
BEGIN
    PRINT '    Creating index [UQ_t_mdm_approval_requests_RequestUid] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_mdm_approval_requests_RequestUid
        ON dbo.t_mdm_approval_requests (RequestUid);
END
GO
/*------------------------------------------------------------------------------
  RequestNo is quoted in emails and read out on the phone. Two requests
  sharing one is a support call nobody can resolve.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_mdm_approval_requests_RequestNo' AND object_id = OBJECT_ID('dbo.t_mdm_approval_requests'))
BEGIN
    PRINT '    Creating index [UQ_t_mdm_approval_requests_RequestNo] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_mdm_approval_requests_RequestNo
        ON dbo.t_mdm_approval_requests (RequestNo)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  🔴 ONE PENDING REQUEST PER ENTITY — the guarantee, not the check.

  A school can submit twice: two tabs, a double click, a retry after a timeout.
  Two Pending rows for one EntityUid is a broken state that only surfaces when
  an admin sees the same school twice in the queue.

  USP_SubmitApprovalRequest also checks and returns the existing request, but a
  check without this index is a race, not a guarantee — two concurrent sessions
  both pass the check before either inserts.

  ⚠️ StatusId = 1 is Pending, written as a literal because a filtered index
  cannot contain a subquery. If m_mdm_approval_status is ever renumbered this
  index must be rebuilt — which is one more reason master IDs are contract.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_mdm_approval_requests_OnePendingPerEntity' AND object_id = OBJECT_ID('dbo.t_mdm_approval_requests'))
BEGIN
    PRINT '    Creating index [UQ_t_mdm_approval_requests_OnePendingPerEntity] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_mdm_approval_requests_OnePendingPerEntity
        ON dbo.t_mdm_approval_requests (RequestTypeId, EntityUid)
        WHERE StatusId = 1 AND Is_Deleted = 0;
END
GO
