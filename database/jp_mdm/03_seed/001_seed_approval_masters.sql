/*==============================================================================
  jp_mdm — 03_seed / 001_seed_approval_masters.sql

  The FIVE masters that are OURS to define, not the client's.

  ---------------------------------------------------------------------------
  WHY ONLY FIVE
  ---------------------------------------------------------------------------
  Phase 2B seeds the rest — geography, education, profile — and is blocked on
  the client's lists. Seeding a guess now and correcting it later means a data
  migration on rows that by then have foreign keys pointing at them: requests,
  documents and school records all referencing IDs we invented.

  These five are different. They are engine values, not reference data. The
  approval engine cannot be written without knowing that Pending is 1, and no
  client supplies that list — we do.

  ---------------------------------------------------------------------------
  🔴 IDs ARE CONTRACT
  ---------------------------------------------------------------------------
  These IDs are referenced by enums in JP.Core, by the filtered unique index
  UQ_t_mdm_approval_requests_OnePendingPerEntity (which hardcodes StatusId = 1
  because a filtered index cannot contain a subquery), and by every CASE in the
  approval procedures.

  NEVER renumber a row once seeded. Add new ones at the end.

  ---------------------------------------------------------------------------
  Re-runnable. MERGE corrects a changed Name on re-run while never touching
  rows an admin has deliberately deactivated, and never deletes — soft delete
  only (decision 2.5).

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

PRINT '    Seeding approval and payment masters ...';
GO

/*------------------------------------------------------------------------------
  m_mdm_request_types — what can be submitted for approval.
------------------------------------------------------------------------------*/
MERGE dbo.m_mdm_request_types AS tgt
USING (VALUES
        (1, 'SCHOOL_REG',     N'School registration',   1),
        (2, 'TEACHER_VERIFY', N'Teacher verification',  2),
        (3, 'BRANCH_ADD',     N'Add branch',            3),
        (4, 'OFFER_APPROVAL', N'Offer approval',        4)
      ) AS src (RequestTypeId, Code, Name, DisplayOrder)
    ON tgt.RequestTypeId = src.RequestTypeId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (RequestTypeId, Code, Name, DisplayOrder)
         VALUES (src.RequestTypeId, src.Code, src.Name, src.DisplayOrder);
GO

/*------------------------------------------------------------------------------
  m_mdm_approval_status — the request lifecycle.

  🔴 1 = Pending is load-bearing: UQ_t_mdm_approval_requests_OnePendingPerEntity
  filters on the literal 1. Changing this number silently breaks the guarantee
  that a school cannot have two open registrations.

  8 = Draft is deliberately out of sequence, matching the spec. It is not part
  of the approve/reject flow — a draft has never been submitted.
------------------------------------------------------------------------------*/
MERGE dbo.m_mdm_approval_status AS tgt
USING (VALUES
        (1, 'PENDING',            N'Pending',            1),
        (2, 'REJECTED',           N'Rejected',           2),
        (3, 'APPROVED',           N'Approved',           3),
        (4, 'RESUBMIT_REQUIRED',  N'Resubmit required',  4),
        (8, 'DRAFT',              N'Draft',              8)
      ) AS src (ApprovalStatusId, Code, Name, DisplayOrder)
    ON tgt.ApprovalStatusId = src.ApprovalStatusId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (ApprovalStatusId, Code, Name, DisplayOrder)
         VALUES (src.ApprovalStatusId, src.Code, src.Name, src.DisplayOrder);
GO

/*------------------------------------------------------------------------------
  m_mdm_action_types — what appears in the append-only action trail.

  Submit and Resubmit are actions too, not just approve/reject: the trail has to
  answer "when was this sent in" without a join to another table.
------------------------------------------------------------------------------*/
MERGE dbo.m_mdm_action_types AS tgt
USING (VALUES
        (1, 'APPROVE',          N'Approve',           1),
        (2, 'REJECT',           N'Reject',            2),
        (3, 'REQUEST_RESUBMIT', N'Request resubmit',  3),
        (4, 'SUBMIT',           N'Submit',            4),
        (5, 'RESUBMIT',         N'Resubmit',          5)
      ) AS src (ActionTypeId, Code, Name, DisplayOrder)
    ON tgt.ActionTypeId = src.ActionTypeId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (ActionTypeId, Code, Name, DisplayOrder)
         VALUES (src.ActionTypeId, src.Code, src.Name, src.DisplayOrder);
GO

/*------------------------------------------------------------------------------
  m_mdm_payment_modes — not used in MVP, seeded so the table is not empty when
  the payment work starts and so the IDs are fixed before anything references
  them.
------------------------------------------------------------------------------*/
MERGE dbo.m_mdm_payment_modes AS tgt
USING (VALUES
        (1, 'ONLINE', N'Online',  1),
        (2, 'NEFT',   N'NEFT',    2),
        (3, 'CHEQUE', N'Cheque',  3),
        (4, 'CASH',   N'Cash',    4)
      ) AS src (PaymentModeId, Code, Name, DisplayOrder)
    ON tgt.PaymentModeId = src.PaymentModeId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (PaymentModeId, Code, Name, DisplayOrder)
         VALUES (src.PaymentModeId, src.Code, src.Name, src.DisplayOrder);
GO

/*------------------------------------------------------------------------------
  m_mdm_payment_status
------------------------------------------------------------------------------*/
MERGE dbo.m_mdm_payment_status AS tgt
USING (VALUES
        (1, 'PENDING',  N'Pending',   1),
        (2, 'SUCCESS',  N'Success',   2),
        (3, 'FAILED',   N'Failed',    3),
        (4, 'REFUNDED', N'Refunded',  4)
      ) AS src (PaymentStatusId, Code, Name, DisplayOrder)
    ON tgt.PaymentStatusId = src.PaymentStatusId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (PaymentStatusId, Code, Name, DisplayOrder)
         VALUES (src.PaymentStatusId, src.Code, src.Name, src.DisplayOrder);
GO

/*==============================================================================
  ⚠️ NOT SEEDED HERE — PHASE 2B, blocked on the client's lists:

      geography   m_mdm_country · m_mdm_state · m_mdm_district · m_mdm_city
      education   m_mdm_board · m_mdm_school_type · m_mdm_qualification ·
                  m_mdm_subject · m_mdm_designation · m_mdm_class_level ·
                  m_mdm_stream
      profile     m_mdm_gender · m_mdm_skill · m_mdm_language · m_mdm_facility ·
                  m_mdm_experience_range
      approval    m_mdm_document_types · m_mdm_rejection_reasons
                  (these two are RequestTypeId-scoped and the client decides
                   which documents are mandatory)

  Do not "temporarily" seed any of them. A guess corrected later is a data
  migration on rows that already have foreign keys pointing at them.
==============================================================================*/

PRINT '    Approval and payment masters seeded (5 of 23 — rest is Phase 2B).';
GO
