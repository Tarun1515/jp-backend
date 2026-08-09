/*==============================================================================
  jp_mdm — 04_procedures / 005_document_lookup.sql

  USP_GetDocumentRequestId — which request does this document belong to?

  ---------------------------------------------------------------------------
  WHY THIS IS THE ONLY DOCUMENT LOOKUP
  ---------------------------------------------------------------------------
  There is deliberately no "get document by id" that returns a file path on its
  own. A path without the owning request is a footgun: the caller has something
  it can open and nothing to check it against, and the access rule lives on the
  request.

  So this returns the RequestId only. The service then loads the request through
  the normal path, applies the ownership rule, and finds the document in the
  result it already has.

  Read procedure: no transaction, so no CATCH.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE dbo.USP_GetDocumentRequestId
    @DocumentId bigint
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.RequestId
    FROM dbo.t_mdm_request_documents d
    WHERE d.DocumentId = @DocumentId
      AND d.Is_Deleted = 0;
END
GO

PRINT '    USP_GetDocumentRequestId ready.';
GO
