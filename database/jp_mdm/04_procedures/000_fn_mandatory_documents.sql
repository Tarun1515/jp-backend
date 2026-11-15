/*==============================================================================
  jp_mdm — 04_procedures / 000_fn_mandatory_documents.sql

  fn_MandatoryDocumentTypes   — WHICH documents a request type cannot go in without
  fn_FirstMissingRequestDocument — the first one missing from a jp_mdm request

  ----------------------------------------------------------------------------
  🔴 WHY THIS FILE EXISTS — IsMandatory WAS DECORATION
  ----------------------------------------------------------------------------
  m_mdm_document_types.IsMandatory shipped in Phase 1A and was never enforced
  anywhere. Measured 15 Nov 2026, both submit paths, live, inside a rollback:

      USP_SubmitApprovalRequest   RequestTypeId 2, ZERO documents
          -> 1 | NULL | Your request has been submitted for review.

      USP_SubmitRegistrationDraft draft 1518, BOTH mandatory school documents
                                  missing, six mandatory fields completed first
                                  so nothing else could refuse it
          -> 1 | NULL | Your registration has been submitted for review.

  The column appeared only in the table, one index INCLUDE, the seed, two READ
  procedures, and five C# members that ship it to the browser. The browser was
  the only thing that ever acted on it: the school wizard disables its submit
  button (registration.component.ts:451), and the teacher profile renders a
  "needed" chip that nothing reads back.

  A disabled button is not a rule. Six requests already in the live database
  are missing a document the master calls mandatory.

  ----------------------------------------------------------------------------
  🔴 ONE DEFINITION OF "MANDATORY", TWO DOCUMENT STORES
  ----------------------------------------------------------------------------
  The two kinds of request keep their documents in different tables, in
  different databases:

      school registration   jp_mdm.t_mdm_request_documents   (attached to the request)
      teacher verification  jp_app.t_app_teacher_documents   (attached to the profile)

  And the coupling between the databases runs ONE WAY. jp_app reads jp_mdm
  masters in 22 places; `grep "jp_app\.dbo\." database/jp_mdm/` returns ZERO.
  Breaking that to put both checks in one function here would make the master
  database depend on the application database — a far worse trade than two
  callers.

  So what is shared is the DEFINITION, and it lives here:

      fn_MandatoryDocumentTypes(@RequestTypeId)
          |
          +-- jp_mdm  USP_SubmitRegistrationDraft    -> t_mdm_request_documents
          +-- jp_app  USP_RequestTeacherVerification -> t_app_teacher_documents

  Add a mandatory document to the master and both paths start refusing without
  it. That is the property worth having; a single shared SELECT over two
  databases is not.

  ----------------------------------------------------------------------------
  ⚠️ USP_SubmitApprovalRequest IS DELIBERATELY NOT GIVEN THIS RULE
  ----------------------------------------------------------------------------
  It CREATES the request. At the moment its validation runs there is no
  RequestId, so no document can be attached to it yet and every submission
  would be refused for ever. The rule belongs where documents already exist:
  on the promotion of a draft, and on a verification request raised from a
  profile that has been filled in.

  ⚠️ Is_Active = 0 means NOT REQUIRED. Switching a document type off is how the
  client retires one (the seed's own reconciliation note says never DELETE), so
  an inactive row must stop being demanded the moment it is switched off.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  fn_MandatoryDocumentTypes

  An INLINE table-valued function, so a caller's NOT EXISTS is expanded into
  its own plan rather than executed row by row. A multi-statement TVF or a
  scalar UDF here would be a per-submission RBAR cost for a list of at most a
  handful of rows.

  DisplayOrder is returned so a caller can name the FIRST missing document in
  the order the person sees them on screen — "your Aadhaar card" is a sentence
  somebody can act on; "one or more required documents" is not (2.21).
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_MandatoryDocumentTypes (@RequestTypeId int)
RETURNS TABLE
AS
RETURN
(
    SELECT dt.DocumentTypeId,
           dt.Code,
           dt.Name,
           dt.DisplayOrder
    FROM dbo.m_mdm_document_types AS dt
    WHERE dt.RequestTypeId = @RequestTypeId
      AND dt.IsMandatory   = 1
      AND dt.Is_Active     = 1
      AND dt.Is_Deleted    = 0
);
GO


/*==============================================================================
  fn_FirstMissingRequestDocument

  The Name of the first mandatory document that has NOT been uploaded against
  this request, or NULL when the request is complete.

  Returns a NAME rather than a bit or an id because the caller's job is to say
  which document is missing, and a name that came from the master cannot drift
  out of step with the label the person was shown on the upload screen.

  ⚠️ The request's own type is read here rather than taken as a parameter. A
  caller passing a type that is not the request's own would check the wrong
  list, and the request already knows what it is.
==============================================================================*/
CREATE OR ALTER FUNCTION dbo.fn_FirstMissingRequestDocument (@RequestId bigint)
RETURNS nvarchar(150)
AS
BEGIN
    DECLARE @RequestTypeId int;

    SELECT @RequestTypeId = r.RequestTypeId
    FROM dbo.t_mdm_approval_requests AS r
    WHERE r.RequestId = @RequestId
      AND r.Is_Deleted = 0;

    IF @RequestTypeId IS NULL
        RETURN NULL;           -- not this function's refusal to make

    RETURN (
        SELECT TOP (1) m.Name
        FROM dbo.fn_MandatoryDocumentTypes(@RequestTypeId) AS m
        WHERE NOT EXISTS (
            SELECT 1
            FROM dbo.t_mdm_request_documents AS d
            WHERE d.RequestId      = @RequestId
              AND d.DocumentTypeId = m.DocumentTypeId
              AND d.Is_Deleted     = 0
        )
        ORDER BY m.DisplayOrder, m.DocumentTypeId
    );
END
GO

PRINT '    Mandatory document functions ready.';
GO
