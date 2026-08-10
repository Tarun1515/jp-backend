/*==============================================================================
  jp_app — 017_t_app_teacher_documents.sql

  A teacher's own documents: degree certificates, ID proof, experience letters.

  ---------------------------------------------------------------------------
  ⚠️ NOT THE SAME TABLE AS t_mdm_request_documents, AND NOT A DUPLICATE OF IT
  ---------------------------------------------------------------------------
  jp_mdm holds documents attached to an APPROVAL REQUEST — evidence for one
  decision, which is why that table versions rather than overwrites and never
  lets a rejected file be replaced in place.

  This holds documents attached to a PERSON. They outlive any single request,
  they are what a school looks at on a profile, and replacing an expired one
  with a current one is an ordinary thing to want.

  ---------------------------------------------------------------------------
  🔴 NO IDENTITY NUMBER IS STORED HERE. EVER.
  ---------------------------------------------------------------------------
  Decision 2.50: the teacher chooses which government photo ID they are
  uploading — Aadhaar, PAN, Voter ID, Passport, Driving Licence — and uploads
  the DOCUMENT. There is no AadhaarNumber column and there must never be one.

  Storing Aadhaar numbers is restricted under the Aadhaar Act and UIDAI rules;
  a private entity generally may not retain the full number without specific
  authorisation, and real verification needs a UIDAI-authorised KYC provider,
  which we are not. If the client asks for it, that goes in writing with their
  own legal advice — not on a verbal request.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_teacher_documents' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_teacher_documents] ...';

    CREATE TABLE dbo.t_app_teacher_documents
    (
        DocumentId      bigint          IDENTITY(1,1) NOT NULL,
        TeacherId       bigint          NOT NULL,

        /*
          ⚠️ CROSS-DATABASE — m_mdm_document_types in jp_mdm. No foreign key
          (decision 2.2); int, verified against the live column.

          That master also carries MaxSizeKb and AllowedExtensions, and the
          upload endpoint reads them from there rather than from a constant
          (2.47). Nothing about the limits is repeated here.
        */
        DocumentTypeId  int             NOT NULL,

        -- 🔴 A GENERATED storage name, never the client's filename (2.48).
        FilePath        nvarchar(500)   NOT NULL,

        -- What the teacher called it. Metadata only — it never becomes a path.
        FileName        nvarchar(255)   NOT NULL,

        FileSizeKb      int             NOT NULL,

        -- The SNIFFED type, not the Content-Type header, which is client input.
        MimeType        varchar(100)    NOT NULL,

        /*
          🔴 A badge on the document, not a gate (decision 2.9). An unverified
          document is shown as unverified; it does not stop the teacher using
          their account.
        */
        IsVerified      tinyint         NOT NULL CONSTRAINT DF_t_app_teacher_documents_IsVerified DEFAULT (0),

        -- An event, so UTC datetime2 (2.28) — "when was this checked", not
        -- "which day".
        VerifiedOn      datetime2       NULL,

        -- ---- standard columns -------------------------------------------------
        Is_Active       tinyint         NOT NULL CONSTRAINT DF_t_app_teacher_documents_Is_Active  DEFAULT (1),
        Is_Deleted      tinyint         NOT NULL CONSTRAINT DF_t_app_teacher_documents_Is_Deleted DEFAULT (0),
        CreatedOn       datetime2       NOT NULL CONSTRAINT DF_t_app_teacher_documents_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy       bigint          NULL,
        ModifiedOn      datetime2       NULL,
        ModifiedBy      bigint          NULL,

        CONSTRAINT PK_t_app_teacher_documents PRIMARY KEY CLUSTERED (DocumentId),
        CONSTRAINT FK_t_app_teacher_documents_t_app_teachers
            FOREIGN KEY (TeacherId) REFERENCES dbo.t_app_teachers (TeacherId),
        CONSTRAINT CK_t_app_teacher_documents_IsVerified CHECK (IsVerified IN (0, 1)),
        CONSTRAINT CK_t_app_teacher_documents_Is_Active  CHECK (Is_Active  IN (0, 1)),
        CONSTRAINT CK_t_app_teacher_documents_Is_Deleted CHECK (Is_Deleted IN (0, 1)),
        CONSTRAINT CK_t_app_teacher_documents_FileSizeKb CHECK (FileSizeKb > 0)
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_teacher_documents] already exists — skipped.';
END
GO
/*------------------------------------------------------------------------------
  🔴 THERE IS DELIBERATELY NO UNIQUE INDEX ON (TeacherId, DocumentTypeId).

  It is the obvious one to add, and it would be wrong today.

  A teacher can hold two legitimate documents of the same type: two degree
  certificates, two experience letters from two schools. Constraining the pair
  would force one of them to be soft-deleted to make room for the other, which
  is a data loss dressed up as a data rule.

  For the types where exactly one IS correct — ID proof — the constraint
  belongs in the procedure, where "one current ID proof" can also mean
  "superseding the old one", which an index cannot express.

  ⚠️ If Phase 3D wants replace-with-history instead, the answer is a Version
  column and the same unique index t_mdm_request_documents uses — not a unique
  index on this shape.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_teacher_documents_FilePath' AND object_id = OBJECT_ID('dbo.t_app_teacher_documents'))
BEGIN
    PRINT '    Creating index [UQ_t_app_teacher_documents_FilePath] ...';

    /*
      What IS unique is the stored file. Names are generated GUIDs, so two rows
      on one path cannot come from a teacher uploading similar documents — only
      from one upload being recorded twice, which is the double-clicked-save
      case. And it matters: deleting one of the two would delete the file the
      other still points at.
    */
    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_teacher_documents_FilePath
        ON dbo.t_app_teacher_documents (FilePath)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  A teacher's documents, newest first — how the profile screen reads them.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_teacher_documents_TeacherId' AND object_id = OBJECT_ID('dbo.t_app_teacher_documents'))
BEGIN
    PRINT '    Creating index [IX_t_app_teacher_documents_TeacherId] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_teacher_documents_TeacherId
        ON dbo.t_app_teacher_documents (TeacherId, DocumentTypeId, CreatedOn DESC)
        INCLUDE (FileName, FileSizeKb, MimeType, IsVerified, VerifiedOn)
        WHERE Is_Deleted = 0;
END
GO
/*------------------------------------------------------------------------------
  Everything still waiting to be checked, oldest first — the same queue shape as
  the admin verification list, and for the same reason: the oldest one has been
  waiting longest.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_teacher_documents_Unverified' AND object_id = OBJECT_ID('dbo.t_app_teacher_documents'))
BEGIN
    PRINT '    Creating index [IX_t_app_teacher_documents_Unverified] ...';

    CREATE NONCLUSTERED INDEX IX_t_app_teacher_documents_Unverified
        ON dbo.t_app_teacher_documents (CreatedOn)
        INCLUDE (TeacherId, DocumentTypeId, FileName)
        WHERE IsVerified = 0 AND Is_Deleted = 0;
END
GO
