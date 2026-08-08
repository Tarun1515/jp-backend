/*==============================================================================
  jp_mdm — 027_t_mdm_request_documents.sql

  Uploaded documents for a request.

  🔴 Version is bumped, never overwritten. A rejected document is the evidence
  of why it was rejected — if a resubmit replaced the file in place, the reason
  on the rejection would point at a document that no longer exists.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

-- Filtered indexes REQUIRE these, both to CREATE them and for any later
-- INSERT/UPDATE on the table (decision 2.29).
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_mdm_request_documents' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_mdm_request_documents] ...';

    CREATE TABLE dbo.t_mdm_request_documents
    (
        DocumentId          bigint            IDENTITY(1,1) NOT NULL,
        RequestId           bigint            NOT NULL,
        DocumentTypeId      int               NOT NULL,

        FilePath            nvarchar(500)     NOT NULL,
        FileName            nvarchar(255)     NOT NULL,
        FileSizeKb          int               NOT NULL,
        MimeType            varchar(100)      NOT NULL,

        -- Starts at 1 and increments per resubmit of the same document type.
        Version             int               NOT NULL CONSTRAINT DF_t_mdm_request_documents_Version DEFAULT (1),

        IsVerified          tinyint           NOT NULL CONSTRAINT DF_t_mdm_request_documents_IsVerified DEFAULT (0),

        /*
          ⚠️ CROSS-DATABASE REFERENCE — jp_sso.t_sso_users.UserId. NO foreign key here, and
          there must never be one (decision 2.2): SQL Server cannot enforce a FK
          across databases. Validated in the procedure and the API instead.
          t_sso_users.UserId is bigint — verified against the live column.
        */
        VerifiedByUserId    bigint            NULL,
        -- Event timestamp: UTC datetime2 (decision 2.28).
        VerifiedOn          datetime2         NULL,

        RejectionReasonId   int               NULL,
        Remarks             nvarchar(1000)    NULL,

        Is_Active           tinyint           NOT NULL CONSTRAINT DF_t_mdm_request_documents_Is_Active  DEFAULT (1),
        Is_Deleted          tinyint           NOT NULL CONSTRAINT DF_t_mdm_request_documents_Is_Deleted DEFAULT (0),
        CreatedOn           datetime2         NOT NULL CONSTRAINT DF_t_mdm_request_documents_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy           bigint            NULL,
        ModifiedOn          datetime2         NULL,
        ModifiedBy          bigint            NULL,

        CONSTRAINT PK_t_mdm_request_documents PRIMARY KEY CLUSTERED (DocumentId),
        CONSTRAINT FK_t_mdm_request_documents_t_mdm_approval_requests
            FOREIGN KEY (RequestId) REFERENCES dbo.t_mdm_approval_requests (RequestId),
        CONSTRAINT FK_t_mdm_request_documents_m_mdm_document_types
            FOREIGN KEY (DocumentTypeId) REFERENCES dbo.m_mdm_document_types (DocumentTypeId),
        CONSTRAINT FK_t_mdm_request_documents_m_mdm_rejection_reasons
            FOREIGN KEY (RejectionReasonId) REFERENCES dbo.m_mdm_rejection_reasons (RejectionReasonId),
        CONSTRAINT CK_t_mdm_request_documents_IsVerified CHECK (IsVerified IN (0, 1)),
        CONSTRAINT CK_t_mdm_request_documents_Version    CHECK (Version >= 1),
        CONSTRAINT CK_t_mdm_request_documents_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_mdm_request_documents_Is_Deleted CHECK (Is_Deleted IN (0, 1))
    );
END
ELSE
BEGIN
    PRINT '    Table [t_mdm_request_documents] already exists — skipped.';
END
GO
/*------------------------------------------------------------------------------
  One row per (request, document type, version).

  This is what makes the version bump safe: a retried upload cannot quietly
  create a second row claiming to be the same version of the same document.

  🔴 Guarded separately from the table (decision 2.29).
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_mdm_request_documents_Request_Type_Version' AND object_id = OBJECT_ID('dbo.t_mdm_request_documents'))
BEGIN
    PRINT '    Creating index [UQ_t_mdm_request_documents_Request_Type_Version] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_mdm_request_documents_Request_Type_Version
        ON dbo.t_mdm_request_documents (RequestId, DocumentTypeId, Version)
        WHERE Is_Deleted = 0;
END
GO
