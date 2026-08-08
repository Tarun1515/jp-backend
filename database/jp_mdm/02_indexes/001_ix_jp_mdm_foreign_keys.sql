/*==============================================================================
  jp_mdm — 02_indexes / 001_ix_jp_mdm_foreign_keys.sql

  One non-clustered index per foreign key column, plus the columns that get
  filtered on constantly.

  ---------------------------------------------------------------------------
  WHY FK COLUMNS NEED THEIR OWN INDEXES
  ---------------------------------------------------------------------------
  SQL Server indexes the PARENT side of a foreign key automatically (it is the
  primary key) and the CHILD side not at all. Without these, every "show me the
  documents for this request" is a scan, and — worse — every soft delete or
  update on a parent takes a scan of each child table to check the constraint.

  ---------------------------------------------------------------------------
  UNIQUE / BUSINESS-KEY INDEXES ARE **NOT** HERE
  ---------------------------------------------------------------------------
  They live beside their table in 01_tables/, because a business key is part of
  what the table means rather than a performance decision. This file is only
  the access-path indexes.

  Every guard is separate (decision 2.29): a single guard around the whole file
  would skip all remaining indexes the moment one already existed.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*------------------------------------------------------------------------------
  Helper pattern used below — repeated per index rather than factored into
  dynamic SQL, so each one is greppable by name when a plan looks wrong.
------------------------------------------------------------------------------*/

-- ============================ GEOGRAPHY =====================================
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_m_mdm_state_CountryId' AND object_id = OBJECT_ID('dbo.m_mdm_state'))
BEGIN
    PRINT '    IX_m_mdm_state_CountryId';
    CREATE NONCLUSTERED INDEX IX_m_mdm_state_CountryId
        ON dbo.m_mdm_state (CountryId) INCLUDE (Code, Name, DisplayOrder) WHERE Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_m_mdm_district_StateId' AND object_id = OBJECT_ID('dbo.m_mdm_district'))
BEGIN
    PRINT '    IX_m_mdm_district_StateId';
    CREATE NONCLUSTERED INDEX IX_m_mdm_district_StateId
        ON dbo.m_mdm_district (StateId) INCLUDE (Code, Name, DisplayOrder) WHERE Is_Deleted = 0;
END
GO

/*
  The cascade index. A city dropdown is always "cities in this district", and
  the INCLUDE covers the whole payload so the lookup never touches the table.
  Latitude/Longitude are carried for the later "jobs near me" search.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_m_mdm_city_DistrictId' AND object_id = OBJECT_ID('dbo.m_mdm_city'))
BEGIN
    PRINT '    IX_m_mdm_city_DistrictId';
    CREATE NONCLUSTERED INDEX IX_m_mdm_city_DistrictId
        ON dbo.m_mdm_city (DistrictId) INCLUDE (Code, Name, DisplayOrder, Latitude, Longitude) WHERE Is_Deleted = 0;
END
GO

-- ==================== APPROVAL MASTERS (scoped by request type) =============
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_m_mdm_document_types_RequestTypeId' AND object_id = OBJECT_ID('dbo.m_mdm_document_types'))
BEGIN
    PRINT '    IX_m_mdm_document_types_RequestTypeId';
    CREATE NONCLUSTERED INDEX IX_m_mdm_document_types_RequestTypeId
        ON dbo.m_mdm_document_types (RequestTypeId) INCLUDE (Code, Name, IsMandatory, MaxSizeKb, AllowedExtensions) WHERE Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_m_mdm_rejection_reasons_RequestTypeId' AND object_id = OBJECT_ID('dbo.m_mdm_rejection_reasons'))
BEGIN
    PRINT '    IX_m_mdm_rejection_reasons_RequestTypeId';
    CREATE NONCLUSTERED INDEX IX_m_mdm_rejection_reasons_RequestTypeId
        ON dbo.m_mdm_rejection_reasons (RequestTypeId) INCLUDE (Code, Name, DisplayOrder) WHERE Is_Deleted = 0;
END
GO

-- ============================ REQUEST LEVELS ================================
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_request_levels_RequestTypeId' AND object_id = OBJECT_ID('dbo.t_mdm_request_levels'))
BEGIN
    PRINT '    IX_t_mdm_request_levels_RequestTypeId';
    CREATE NONCLUSTERED INDEX IX_t_mdm_request_levels_RequestTypeId
        ON dbo.t_mdm_request_levels (RequestTypeId, LevelNumber) INCLUDE (RoleId, IsFinalLevel, OrganizationUid) WHERE Is_Deleted = 0;
END
GO

/*
  Cross-database column. Indexed even though it carries no FK — "which requests
  route to this role" is a real query, and the absence of a constraint does not
  make the column any less of an access path.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_request_levels_RoleId' AND object_id = OBJECT_ID('dbo.t_mdm_request_levels'))
BEGIN
    PRINT '    IX_t_mdm_request_levels_RoleId';
    CREATE NONCLUSTERED INDEX IX_t_mdm_request_levels_RoleId
        ON dbo.t_mdm_request_levels (RoleId) WHERE Is_Deleted = 0;
END
GO

-- ============================ APPROVAL REQUESTS =============================
/*
  🔴 THE ADMIN QUEUE INDEX.

  USP_GetApprovalRequestList sorts oldest-submitted-first within a status —
  it is a work queue, and the person using it is clearing a backlog. Leading
  with StatusId and then SubmittedOn lets the paged read seek and stay in
  order, so OFFSET-FETCH does not sort the whole table on every page.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_approval_requests_Status_Submitted' AND object_id = OBJECT_ID('dbo.t_mdm_approval_requests'))
BEGIN
    PRINT '    IX_t_mdm_approval_requests_Status_Submitted';
    CREATE NONCLUSTERED INDEX IX_t_mdm_approval_requests_Status_Submitted
        ON dbo.t_mdm_approval_requests (StatusId, SubmittedOn)
        INCLUDE (RequestNo, RequestTypeId, EntityUid, OrganizationUid, RequestorUserId, ApproverUserId, CurrentApprovalLevel, CompletedOn, RowVersion)
        WHERE Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_approval_requests_RequestTypeId' AND object_id = OBJECT_ID('dbo.t_mdm_approval_requests'))
BEGIN
    PRINT '    IX_t_mdm_approval_requests_RequestTypeId';
    CREATE NONCLUSTERED INDEX IX_t_mdm_approval_requests_RequestTypeId
        ON dbo.t_mdm_approval_requests (RequestTypeId, StatusId) INCLUDE (SubmittedOn) WHERE Is_Deleted = 0;
END
GO

/*
  "Everything for this entity" — including the completed history, which is why
  this is not filtered to Pending like the uniqueness index is.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_approval_requests_EntityUid' AND object_id = OBJECT_ID('dbo.t_mdm_approval_requests'))
BEGIN
    PRINT '    IX_t_mdm_approval_requests_EntityUid';
    CREATE NONCLUSTERED INDEX IX_t_mdm_approval_requests_EntityUid
        ON dbo.t_mdm_approval_requests (EntityUid, RequestTypeId) INCLUDE (StatusId, SubmittedOn) WHERE Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_approval_requests_OrganizationUid' AND object_id = OBJECT_ID('dbo.t_mdm_approval_requests'))
BEGIN
    PRINT '    IX_t_mdm_approval_requests_OrganizationUid';
    CREATE NONCLUSTERED INDEX IX_t_mdm_approval_requests_OrganizationUid
        ON dbo.t_mdm_approval_requests (OrganizationUid) INCLUDE (StatusId, SubmittedOn) WHERE Is_Deleted = 0 AND OrganizationUid IS NOT NULL;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_approval_requests_RequestorUserId' AND object_id = OBJECT_ID('dbo.t_mdm_approval_requests'))
BEGIN
    PRINT '    IX_t_mdm_approval_requests_RequestorUserId';
    CREATE NONCLUSTERED INDEX IX_t_mdm_approval_requests_RequestorUserId
        ON dbo.t_mdm_approval_requests (RequestorUserId) INCLUDE (StatusId, SubmittedOn) WHERE Is_Deleted = 0;
END
GO

/*
  "My queue" for an admin. Filtered to assigned rows only — most requests have
  no approver yet, and indexing those NULLs would double the size for nothing.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_approval_requests_ApproverUserId' AND object_id = OBJECT_ID('dbo.t_mdm_approval_requests'))
BEGIN
    PRINT '    IX_t_mdm_approval_requests_ApproverUserId';
    CREATE NONCLUSTERED INDEX IX_t_mdm_approval_requests_ApproverUserId
        ON dbo.t_mdm_approval_requests (ApproverUserId, StatusId) INCLUDE (SubmittedOn) WHERE Is_Deleted = 0 AND ApproverUserId IS NOT NULL;
END
GO

-- ============================ DOCUMENTS =====================================
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_request_documents_RequestId' AND object_id = OBJECT_ID('dbo.t_mdm_request_documents'))
BEGIN
    PRINT '    IX_t_mdm_request_documents_RequestId';
    CREATE NONCLUSTERED INDEX IX_t_mdm_request_documents_RequestId
        ON dbo.t_mdm_request_documents (RequestId, DocumentTypeId, Version DESC)
        INCLUDE (FilePath, FileName, FileSizeKb, MimeType, IsVerified, VerifiedOn, RejectionReasonId, Remarks)
        WHERE Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_request_documents_DocumentTypeId' AND object_id = OBJECT_ID('dbo.t_mdm_request_documents'))
BEGIN
    PRINT '    IX_t_mdm_request_documents_DocumentTypeId';
    CREATE NONCLUSTERED INDEX IX_t_mdm_request_documents_DocumentTypeId
        ON dbo.t_mdm_request_documents (DocumentTypeId) WHERE Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_request_documents_RejectionReasonId' AND object_id = OBJECT_ID('dbo.t_mdm_request_documents'))
BEGIN
    PRINT '    IX_t_mdm_request_documents_RejectionReasonId';
    CREATE NONCLUSTERED INDEX IX_t_mdm_request_documents_RejectionReasonId
        ON dbo.t_mdm_request_documents (RejectionReasonId) WHERE Is_Deleted = 0 AND RejectionReasonId IS NOT NULL;
END
GO

-- ============================ PAYMENTS ======================================
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_request_payments_RequestId' AND object_id = OBJECT_ID('dbo.t_mdm_request_payments'))
BEGIN
    PRINT '    IX_t_mdm_request_payments_RequestId';
    CREATE NONCLUSTERED INDEX IX_t_mdm_request_payments_RequestId
        ON dbo.t_mdm_request_payments (RequestId) INCLUDE (Amount, PaymentStatusId, PaidOn) WHERE Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_request_payments_PaymentModeId' AND object_id = OBJECT_ID('dbo.t_mdm_request_payments'))
BEGIN
    PRINT '    IX_t_mdm_request_payments_PaymentModeId';
    CREATE NONCLUSTERED INDEX IX_t_mdm_request_payments_PaymentModeId
        ON dbo.t_mdm_request_payments (PaymentModeId) WHERE Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_request_payments_PaymentStatusId' AND object_id = OBJECT_ID('dbo.t_mdm_request_payments'))
BEGIN
    PRINT '    IX_t_mdm_request_payments_PaymentStatusId';
    CREATE NONCLUSTERED INDEX IX_t_mdm_request_payments_PaymentStatusId
        ON dbo.t_mdm_request_payments (PaymentStatusId) WHERE Is_Deleted = 0;
END
GO

-- ==================== REGISTRATION DETAIL TABLES ============================
/*
  RequestId needs no index on these two: it IS the clustered primary key.
  Only the master lookups below need one.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_school_registration_details_Location' AND object_id = OBJECT_ID('dbo.t_mdm_school_registration_details'))
BEGIN
    PRINT '    IX_t_mdm_school_registration_details_Location';
    CREATE NONCLUSTERED INDEX IX_t_mdm_school_registration_details_Location
        ON dbo.t_mdm_school_registration_details (StateId, DistrictId, CityId) WHERE Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_school_registration_details_BoardId' AND object_id = OBJECT_ID('dbo.t_mdm_school_registration_details'))
BEGIN
    PRINT '    IX_t_mdm_school_registration_details_BoardId';
    CREATE NONCLUSTERED INDEX IX_t_mdm_school_registration_details_BoardId
        ON dbo.t_mdm_school_registration_details (BoardId) WHERE Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_school_registration_details_SchoolTypeId' AND object_id = OBJECT_ID('dbo.t_mdm_school_registration_details'))
BEGIN
    PRINT '    IX_t_mdm_school_registration_details_SchoolTypeId';
    CREATE NONCLUSTERED INDEX IX_t_mdm_school_registration_details_SchoolTypeId
        ON dbo.t_mdm_school_registration_details (SchoolTypeId) WHERE Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_teacher_registration_details_Location' AND object_id = OBJECT_ID('dbo.t_mdm_teacher_registration_details'))
BEGIN
    PRINT '    IX_t_mdm_teacher_registration_details_Location';
    CREATE NONCLUSTERED INDEX IX_t_mdm_teacher_registration_details_Location
        ON dbo.t_mdm_teacher_registration_details (CurrentStateId, CurrentCityId) WHERE Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_teacher_registration_details_QualificationId' AND object_id = OBJECT_ID('dbo.t_mdm_teacher_registration_details'))
BEGIN
    PRINT '    IX_t_mdm_teacher_registration_details_QualificationId';
    CREATE NONCLUSTERED INDEX IX_t_mdm_teacher_registration_details_QualificationId
        ON dbo.t_mdm_teacher_registration_details (QualificationId) WHERE Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_teacher_registration_details_GenderId' AND object_id = OBJECT_ID('dbo.t_mdm_teacher_registration_details'))
BEGIN
    PRINT '    IX_t_mdm_teacher_registration_details_GenderId';
    CREATE NONCLUSTERED INDEX IX_t_mdm_teacher_registration_details_GenderId
        ON dbo.t_mdm_teacher_registration_details (GenderId) WHERE Is_Deleted = 0;
END
GO

/*
  "Which teachers teach Physics" — the reverse of the bridge's unique key, and
  the reason the bridge exists instead of a comma-separated column.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes WHERE name = 'IX_t_mdm_teacher_registration_subjects_SubjectId' AND object_id = OBJECT_ID('dbo.t_mdm_teacher_registration_subjects'))
BEGIN
    PRINT '    IX_t_mdm_teacher_registration_subjects_SubjectId';
    CREATE NONCLUSTERED INDEX IX_t_mdm_teacher_registration_subjects_SubjectId
        ON dbo.t_mdm_teacher_registration_subjects (SubjectId) INCLUDE (RequestId) WHERE Is_Deleted = 0;
END
GO

PRINT '    jp_mdm indexes ready.';
GO
