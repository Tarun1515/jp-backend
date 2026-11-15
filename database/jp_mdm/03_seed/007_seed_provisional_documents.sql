/*==============================================================================
  jp_mdm — 03_seed / 007_seed_provisional_documents.sql

  Document types · Rejection reasons — both scoped by request type.

  ============================================================================
  ⚠️⚠️  PROVISIONAL — ESPECIALLY IsMandatory  ⚠️⚠️
  ============================================================================

  WHAT WE GUESSED, AND WHY IT MATTERS MORE HERE THAN ELSEWHERE:

  ⚠️ TWO ROWS IN HERE ARE NO LONGER PROVISIONAL — DocumentTypeId 12
  ('Aadhaar card') and 15 ('PAN card'), both TEACHER_VERIFY. They are the
  client's own instruction of 15 Nov 2026, confirmed in writing, and they are
  the only rows in this file that already have an owner. See the block comment
  beside them.

  m_mdm_document_types  (10 rows: 5 school, 5 teacher)
      The DOCUMENT LIST is a reasonable guess. The `IsMandatory` FLAG IS THE
      RISKY PART: it decides whether a school can complete registration at all.
      Marking something mandatory that the client considers optional blocks
      real registrations; the reverse lets unverifiable schools through.

      We marked mandatory only what verification genuinely cannot proceed
      without:
          school   Registration Certificate, Authorization Letter
          teacher  Degree Certificate, Aadhaar card
      Everything else is optional — PAN card included, on the client's
      instruction.

      🔴 AND AS OF 15 Nov 2026 THE FLAG IS ACTUALLY ENFORCED. Until today it
      was decoration: the column appeared in this seed, two read procedures and
      five C# members that ship it to the browser, and in no refusal anywhere.
      Both submit paths accepted a request with every mandatory document
      missing — measured, live, inside a rollback. It is now enforced by
      fn_MandatoryDocumentTypes, read by USP_SubmitRegistrationDraft (school)
      and USP_GetTeacherVerificationReadiness (teacher).

      ⚠️ WHICH RAISES THE STAKES ON THIS COLUMN. Marking something mandatory
      that the client considers optional now BLOCKS submissions rather than
      merely disabling a button. That is the right way round — but it is why
      CLIENT_ASKS 1.4 asks for this list back, and why the MERGE below no
      longer overwrites the answer.

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
    --
    -- 🔴 AADHAAR AND PAN — CLIENT INSTRUCTION, 15 Nov 2026, CONFIRMED IN WRITING.
    --
    -- These two rows are NOT provisional. Everything else in this file is our
    -- guess awaiting the client's correction; these are the client's own
    -- decision and the only rows here that already have an owner.
    --
    -- ⚠️ ID_PROOF KEEPS ITS CODE. Only the Name changes, from the generic
    -- 'Identity Proof' to the document the client actually wants. The Code is
    -- contract (this file's own header: never change a live Code) and the row
    -- has uploaded documents against it. The rename of an EXISTING row is a
    -- guarded migration below, not this MERGE — see the note there.
    --
    -- ⚠️ 'PAN' IS A LEGAL CODE HERE even though DocumentTypeId 4 is also 'PAN'.
    -- The business key is UQ_m_mdm_document_types_RequestTypeId_Code — the
    -- PAIR, not the Code — exactly so the same document can be named the same
    -- thing under a different parent. Inventing 'PAN_TEACHER' to dodge a
    -- collision that does not exist would make the two rows look like different
    -- documents.
    --
    -- 🔒 NO AADHAAR OR PAN NUMBER IS STORED, ANYWHERE (2.50). These rows add
    -- two DOCUMENT slots. There is no column on any table that holds either
    -- number, nothing extracts or parses one from the upload, and the suite
    -- asserts that no new column or DTO field carries one. The document is the
    -- record; an admin's eyes are the verification.
    --
    -- DisplayOrder puts PAN beside Aadhaar because they are the two identity
    -- documents and the profile's helper line speaks about them together.
    (11, 'TEACHER_VERIFY', 'DEGREE',       N'Degree Certificate',         1, 1, 5120, 'pdf,jpg,jpeg,png'),
    (12, 'TEACHER_VERIFY', 'ID_PROOF',     N'Aadhaar card',               2, 1, 5120, 'pdf,jpg,jpeg,png'),
    (15, 'TEACHER_VERIFY', 'PAN',          N'PAN card',                   3, 0, 5120, 'pdf,jpg,jpeg,png'),
    (13, 'TEACHER_VERIFY', 'EXPERIENCE',   N'Experience Letter',          4, 0, 5120, 'pdf,jpg,jpeg,png'),
    (14, 'TEACHER_VERIFY', 'TET_CERT',     N'TET / CTET Certificate',     5, 0, 5120, 'pdf,jpg,jpeg,png');

-- Abort on an unknown request type code rather than inserting an orphan.
IF EXISTS (SELECT 1 FROM @Docs d
           WHERE NOT EXISTS (SELECT 1 FROM dbo.m_mdm_request_types rt
                             WHERE rt.Code = d.RequestTypeCode AND rt.Is_Deleted = 0))
    THROW 50032, 'Unknown RequestTypeCode in the document type seed. Aborted — no rows inserted.', 1;

/*------------------------------------------------------------------------------
  🔴 THE RENAME OF AN EXISTING ROW IS A MIGRATION, NOT A MERGE.

  DocumentTypeId 12 shipped as 'Identity Proof'. The client's instruction makes
  it 'Aadhaar card'. On a database built from scratch the MERGE below inserts
  the new Name directly; on a database that already has row 12 — every
  environment that exists today — this is what changes it.

  ⚠️ GUARDED ON THE OLD VALUE. If the Name is anything else, somebody has
  already renamed it on purpose and this leaves it alone. So the statement is
  idempotent and it is also safe to run after the client has had their say,
  which is the whole point: a seed that re-runs must never be the reason a
  client's decision disappears.

  ⚠️ ONLY the Name moves. The Code stays ID_PROOF (contract, and the row has
  uploaded documents against it) and IsMandatory stays 1.
------------------------------------------------------------------------------*/
UPDATE dbo.m_mdm_document_types
   SET Name       = N'Aadhaar card',
       ModifiedOn = SYSUTCDATETIME()
WHERE DocumentTypeId = 12
  AND Name           = N'Identity Proof';

/*------------------------------------------------------------------------------
  ⚠️ NO `GO` ABOVE. @Docs is a table VARIABLE declared at the top of this batch,
  and a batch separator would put it out of scope — the MERGE below would fail
  with "Must declare the scalar variable @Docs". The rename sits inside the same
  batch deliberately.
------------------------------------------------------------------------------*/

/*------------------------------------------------------------------------------
  🔴 THIS MERGE NO LONGER TOUCHES `Name` OR `IsMandatory` ON AN EXISTING ROW.

  It used to. Both columns were in the MATCHED comparison and in the UPDATE SET,
  which meant a re-run of this seed silently put our guesses back — over the two
  columns this file's own header asks the client to correct:

      "Match on (RequestTypeCode, Code). RENAME NAMES FREELY."
      "The `IsMandatory` FLAG IS THE RISKY PART"

  CLIENT_ASKS 1.4 asks the client to go through this list and tell us which
  documents are compulsory. Had they done that and had anyone then re-run the
  seed — which `run_all.sql` does on every rebuild — their answer would have
  been overwritten by the guesses they were correcting, with no error and no
  trace. The list they were asked to fix was the list the script was fixing back.

  ⚠️ SO THESE TWO COLUMNS ARE NOW INSERT-ONLY. A new row gets our starting
  value; an existing row keeps whatever it has. The rename above is the one
  deliberate exception, and it is guarded on the old value.

  ⚠️ The rest still reconciles. Code, RequestTypeId, DisplayOrder, MaxSizeKb and
  AllowedExtensions are ours to keep in step — nobody is being asked to edit
  them, and a wrong MaxSizeKb is a bug rather than an opinion.
------------------------------------------------------------------------------*/
MERGE dbo.m_mdm_document_types AS tgt
USING (
    SELECT d.DocumentTypeId, rt.RequestTypeId, d.Code, d.Name, d.DisplayOrder,
           d.IsMandatory, d.MaxSizeKb, d.AllowedExtensions
    FROM @Docs d
        INNER JOIN dbo.m_mdm_request_types rt ON rt.Code = d.RequestTypeCode AND rt.Is_Deleted = 0
) AS src
    ON tgt.DocumentTypeId = src.DocumentTypeId
WHEN MATCHED AND (tgt.Code <> src.Code
                  OR tgt.DisplayOrder <> src.DisplayOrder
                  OR tgt.RequestTypeId <> src.RequestTypeId
                  OR tgt.MaxSizeKb <> src.MaxSizeKb
                  OR tgt.AllowedExtensions <> src.AllowedExtensions)
    THEN UPDATE SET tgt.Code = src.Code,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.RequestTypeId = src.RequestTypeId,
                    tgt.MaxSizeKb = src.MaxSizeKb,
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
