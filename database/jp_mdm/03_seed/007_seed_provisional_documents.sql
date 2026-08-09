/*==============================================================================
  jp_mdm — 03_seed / 007_seed_provisional_documents.sql

  Document types · Rejection reasons — both scoped by request type.

  ============================================================================
  ⚠️⚠️  PROVISIONAL — ESPECIALLY IsMandatory  ⚠️⚠️
  ============================================================================

  WHAT WE GUESSED, AND WHY IT MATTERS MORE HERE THAN ELSEWHERE:

  m_mdm_document_types  (9 rows: 5 school, 4 teacher)
      The DOCUMENT LIST is a reasonable guess. The `IsMandatory` FLAG IS THE
      RISKY PART: it decides whether a school can complete registration at all.
      Marking something mandatory that the client considers optional blocks
      real registrations; the reverse lets unverifiable schools through.

      We marked mandatory only what verification genuinely cannot proceed
      without:
          school   Registration Certificate, Authorization Letter
          teacher  Degree Certificate, ID Proof
      Everything else is optional.

      MaxSizeKb = 5120 (5 MB) everywhere, and extensions pdf/jpg/jpeg/png.
      Both are our numbers. A school photographing a certificate on a phone can
      easily exceed 2 MB, which is why it is not lower.

  m_mdm_rejection_reasons  (10 rows)
      Our wording. These are shown to an applicant whose registration was
      refused, so the client will likely want to phrase them in their own voice
      — that is a Name change, not a Code change.

  HOW TO RECONCILE:
      Match on (RequestTypeCode, Code). Rename Names freely.
      Unwanted row: Is_Active = 0, never DELETE.
      🔴 Never change a live Code.

  Tracked in PROJECT_MEMORY open question #5.

  ---------------------------------------------------------------------------
  🔴 RequestTypeId IS RESOLVED BY CODE, NEVER HARDCODED
  ---------------------------------------------------------------------------
  A typo in a request type code aborts this script rather than silently
  inserting rows under the wrong parent — or worse, failing the NOT NULL and
  leaving a half-applied seed. Same pattern as the menu seed (decision 2.37).

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '    Seeding PROVISIONAL document types and rejection reasons ...';
GO

/*------------------------------------------------------------------------------
  m_mdm_document_types — PROVISIONAL.
------------------------------------------------------------------------------*/
DECLARE @Docs TABLE (
    DocumentTypeId    int,
    RequestTypeCode   varchar(30),
    Code              varchar(30),
    Name              nvarchar(150),
    DisplayOrder      int,
    IsMandatory       tinyint,
    MaxSizeKb         int,
    AllowedExtensions varchar(200)
);

INSERT INTO @Docs VALUES
    -- ---- school registration ------------------------------------------------
    ( 1, 'SCHOOL_REG', 'REG_CERTIFICATE',  N'Registration Certificate',   1, 1, 5120, 'pdf,jpg,jpeg,png'),
    ( 2, 'SCHOOL_REG', 'AFFILIATION',      N'Affiliation Letter',         2, 0, 5120, 'pdf,jpg,jpeg,png'),
    ( 3, 'SCHOOL_REG', 'AUTHORIZATION',    N'Authorization Letter',       3, 1, 5120, 'pdf,jpg,jpeg,png'),
    ( 4, 'SCHOOL_REG', 'PAN',              N'PAN Card',                   4, 0, 5120, 'pdf,jpg,jpeg,png'),
    ( 5, 'SCHOOL_REG', 'GST',              N'GST Certificate',            5, 0, 5120, 'pdf,jpg,jpeg,png'),
    -- ---- teacher verification -----------------------------------------------
    (11, 'TEACHER_VERIFY', 'DEGREE',       N'Degree Certificate',         1, 1, 5120, 'pdf,jpg,jpeg,png'),
    (12, 'TEACHER_VERIFY', 'ID_PROOF',     N'Identity Proof',             2, 1, 5120, 'pdf,jpg,jpeg,png'),
    (13, 'TEACHER_VERIFY', 'EXPERIENCE',   N'Experience Letter',          3, 0, 5120, 'pdf,jpg,jpeg,png'),
    (14, 'TEACHER_VERIFY', 'TET_CERT',     N'TET / CTET Certificate',     4, 0, 5120, 'pdf,jpg,jpeg,png');

-- Abort on an unknown request type code rather than inserting an orphan.
IF EXISTS (SELECT 1 FROM @Docs d
           WHERE NOT EXISTS (SELECT 1 FROM dbo.m_mdm_request_types rt
                             WHERE rt.Code = d.RequestTypeCode AND rt.Is_Deleted = 0))
    THROW 50032, 'Unknown RequestTypeCode in the document type seed. Aborted — no rows inserted.', 1;

MERGE dbo.m_mdm_document_types AS tgt
USING (
    SELECT d.DocumentTypeId, rt.RequestTypeId, d.Code, d.Name, d.DisplayOrder,
           d.IsMandatory, d.MaxSizeKb, d.AllowedExtensions
    FROM @Docs d
        INNER JOIN dbo.m_mdm_request_types rt ON rt.Code = d.RequestTypeCode AND rt.Is_Deleted = 0
) AS src
    ON tgt.DocumentTypeId = src.DocumentTypeId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name
                  OR tgt.DisplayOrder <> src.DisplayOrder
                  OR tgt.RequestTypeId <> src.RequestTypeId
                  OR tgt.IsMandatory <> src.IsMandatory
                  OR tgt.MaxSizeKb <> src.MaxSizeKb
                  OR tgt.AllowedExtensions <> src.AllowedExtensions)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.RequestTypeId = src.RequestTypeId,
                    tgt.IsMandatory = src.IsMandatory, tgt.MaxSizeKb = src.MaxSizeKb,
                    tgt.AllowedExtensions = src.AllowedExtensions,
                    tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (DocumentTypeId, RequestTypeId, Code, Name, DisplayOrder,
                 IsMandatory, MaxSizeKb, AllowedExtensions)
         VALUES (src.DocumentTypeId, src.RequestTypeId, src.Code, src.Name, src.DisplayOrder,
                 src.IsMandatory, src.MaxSizeKb, src.AllowedExtensions);
GO

/*------------------------------------------------------------------------------
  m_mdm_rejection_reasons — PROVISIONAL.

  Written as something an applicant can act on. "Invalid" tells them nothing;
  "the registration certificate is unreadable" tells them what to re-upload.
------------------------------------------------------------------------------*/
DECLARE @Reasons TABLE (
    RejectionReasonId int,
    RequestTypeCode   varchar(30),
    Code              varchar(30),
    Name              nvarchar(150),
    DisplayOrder      int
);

INSERT INTO @Reasons VALUES
    -- ---- school registration ------------------------------------------------
    ( 1, 'SCHOOL_REG', 'DOC_UNREADABLE',   N'Document is unreadable or incomplete',       1),
    ( 2, 'SCHOOL_REG', 'DOC_MISMATCH',     N'Document does not match the details provided', 2),
    ( 3, 'SCHOOL_REG', 'NOT_VERIFIABLE',   N'School could not be verified',               3),
    ( 4, 'SCHOOL_REG', 'DUPLICATE',        N'School is already registered',               4),
    ( 5, 'SCHOOL_REG', 'AUTH_INVALID',     N'Authorisation to register could not be confirmed', 5),
    ( 6, 'SCHOOL_REG', 'OTHER',            N'Other — see remarks',                        99),
    -- ---- teacher verification -----------------------------------------------
    (11, 'TEACHER_VERIFY', 'DOC_UNREADABLE', N'Document is unreadable or incomplete',     1),
    (12, 'TEACHER_VERIFY', 'QUAL_MISMATCH',  N'Qualification does not match the certificate', 2),
    (13, 'TEACHER_VERIFY', 'ID_INVALID',     N'Identity proof could not be verified',     3),
    (14, 'TEACHER_VERIFY', 'OTHER',          N'Other — see remarks',                     99);

IF EXISTS (SELECT 1 FROM @Reasons r
           WHERE NOT EXISTS (SELECT 1 FROM dbo.m_mdm_request_types rt
                             WHERE rt.Code = r.RequestTypeCode AND rt.Is_Deleted = 0))
    THROW 50033, 'Unknown RequestTypeCode in the rejection reason seed. Aborted — no rows inserted.', 1;

MERGE dbo.m_mdm_rejection_reasons AS tgt
USING (
    SELECT r.RejectionReasonId, rt.RequestTypeId, r.Code, r.Name, r.DisplayOrder
    FROM @Reasons r
        INNER JOIN dbo.m_mdm_request_types rt ON rt.Code = r.RequestTypeCode AND rt.Is_Deleted = 0
) AS src
    ON tgt.RejectionReasonId = src.RejectionReasonId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name
                  OR tgt.DisplayOrder <> src.DisplayOrder
                  OR tgt.RequestTypeId <> src.RequestTypeId)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.RequestTypeId = src.RequestTypeId,
                    tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (RejectionReasonId, RequestTypeId, Code, Name, DisplayOrder)
         VALUES (src.RejectionReasonId, src.RequestTypeId, src.Code, src.Name, src.DisplayOrder);
GO

PRINT '    PROVISIONAL document types and rejection reasons seeded.';
GO
