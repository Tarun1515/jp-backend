/*==============================================================================
  jp_app — 04_procedures / 029_teacher_verification_request.sql

  USP_GetTeacherVerificationReadiness

  ----------------------------------------------------------------------------
  🔴 WHY THIS EXISTS — A TEACHER COULD NOT ASK TO BE VERIFIED
  ----------------------------------------------------------------------------
  Measured 15 Nov 2026. Calls to `approvals/submit` across all three
  authenticated apps: ZERO. Nothing in the product created a TEACHER_VERIFY
  approval request. The type-2 rows sitting in the admin queue are seed rows.

  The teacher uploads documents from their profile to t_app_teacher_documents
  (POST /api/teacher/documents) and that is where it ended: the documents
  arrived, a "needed" chip was drawn beside the mandatory ones, and nothing ever
  turned them into a request an admin could act on. The approval side was fully
  built — USP_SetTeacherVerified stamps the badge — with no way to reach it.

  ----------------------------------------------------------------------------
  🔴 WHY THE CHECK IS HERE AND THE SUBMISSION IS NOT
  ----------------------------------------------------------------------------
  The two halves of this rule live in different databases:

      which documents are mandatory   jp_mdm.m_mdm_document_types
      which documents a teacher has   jp_app.t_app_teacher_documents
      the request being created       jp_mdm.t_mdm_approval_requests

  The coupling runs one way. jp_app reads jp_mdm masters in five procedures;
  `grep "jp_app\.dbo\." database/jp_mdm/` returns ZERO, and jp_app writes into
  jp_mdm in ZERO places. Both numbers are load-bearing: the master database does
  not know the application database exists, and this file does not change that.

  So this procedure answers ONE question — is this teacher ready, and if not
  which document is missing — by reading the master's own definition through
  jp_mdm.dbo.fn_MandatoryDocumentTypes. It creates nothing. The API layer takes
  the answer and either refuses or calls jp_mdm's USP_SubmitApprovalRequest,
  which is exactly where 2.2 and 2.48 put cross-database orchestration: three
  commits in three databases, ordered and idempotent, never MSDTC.

  ⚠️ THE MANDATORY LIST IS NOT REPEATED HERE. fn_MandatoryDocumentTypes is the
  single definition, shared with the school side's USP_SubmitRegistrationDraft.
  When the client corrects IsMandatory (CLIENT_ASKS 1.4) both paths change and
  neither procedure is edited.

  ----------------------------------------------------------------------------
  🔒 NO IDENTITY NUMBER IS READ, RETURNED OR STORED (2.50)
  ----------------------------------------------------------------------------
  This procedure answers whether a DOCUMENT exists, by DocumentTypeId. It does
  not read, parse, derive or return an Aadhaar or PAN number, and there is no
  column anywhere in t_app_teacher_documents that could hold one. The document
  is the record; an admin's eyes are the verification.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_GetTeacherVerificationReadiness

  Returns exactly one row, or no rows when the user is not a teacher.

      TeacherUid        what the approval request carries as its EntityUid
      IsVerified        already has the badge?
      DocumentCount     how many verification documents are on the profile
      MissingDocument   the FIRST mandatory one not uploaded, else NULL

  ⚠️ ONE ROW, NOT A STATUS/CODE/MESSAGE SHAPE. 2.21 governs procedures that
  WRITE; this one reads. The caller composes the refusal because the caller is
  the layer that owns the wording for both halves of this decision.

  ⚠️ MissingDocument IS A NAME, FROM THE MASTER. Not a bit and not an id: the
  message has to name the document, and a name read from the same master row the
  upload screen labelled itself with cannot drift out of step with it.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetTeacherVerificationReadiness
    @UserUid uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @TeacherId bigint;

    SELECT @TeacherId = t.TeacherId
    FROM dbo.t_app_teachers AS t
    WHERE t.UserUid    = @UserUid
      AND t.Is_Deleted = 0;

    IF @TeacherId IS NULL
        RETURN;                 -- no rows. The caller's 404 to make, not ours.

    SELECT t.TeacherUid,
           t.IsVerified,

           /*
             ⚠️ RETURNED BECAUSE THE SUBMIT PROCEDURE DEMANDS IT.
             USP_SubmitApprovalRequest refuses RequestTypeId 2 with
             'Your full name is required.' and writes FullName into
             t_mdm_teacher_registration_details. Reading it here costs nothing
             — the row is already being read — and saves the API layer a second
             round trip to the profile just to copy one column across.
           */
           t.FullName,

           (SELECT COUNT(*)
            FROM dbo.t_app_teacher_documents AS d
            WHERE d.TeacherId  = @TeacherId
              AND d.Is_Deleted = 0) AS DocumentCount,

           /*
             The first mandatory TEACHER_VERIFY document with nothing uploaded
             against it, in the order the teacher sees them on their profile.

             ⚠️ RequestTypeId 2 is TEACHER_VERIFY (2.47). It is passed as a
             literal because this procedure is about exactly one kind of
             request; a parameter would imply it could check a school.

             ⚠️ Is_Active = 0 on a document type means NOT REQUIRED. Switching
             a type off is how the client retires one — the seed's own
             reconciliation note says never DELETE — and fn_MandatoryDocumentTypes
             filters on it, so a retired document stops being demanded the
             moment it is switched off.
           */
           (SELECT TOP (1) m.Name
            FROM jp_mdm.dbo.fn_MandatoryDocumentTypes(2) AS m
            WHERE NOT EXISTS (
                SELECT 1
                FROM dbo.t_app_teacher_documents AS d
                WHERE d.TeacherId      = @TeacherId
                  AND d.DocumentTypeId = m.DocumentTypeId
                  AND d.Is_Deleted     = 0
            )
            ORDER BY m.DisplayOrder, m.DocumentTypeId) AS MissingDocument

    FROM dbo.t_app_teachers AS t
    WHERE t.TeacherId = @TeacherId;
END
GO

PRINT '    Teacher verification request procedures ready.';
GO
