/*==============================================================================
  jp_mdm — 04_procedures / 003_approval_reads.sql

  USP_GetApprovalRequestList     the admin queue, paged
  USP_GetApprovalRequestById     one request, five result sets
  USP_GetPendingCountsByType     dashboard badges

  Read procedures: no transaction, so no CATCH (Block B of the template).
  There is nothing to roll back and nothing a caller could do about a failure
  here; BaseRepository wraps it with the procedure name.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_GetApprovalRequestList

  Two result sets: the page, then the total before paging.

  ---------------------------------------------------------------------------
  DEFAULT SORT IS OLDEST FIRST — and that is deliberate
  ---------------------------------------------------------------------------
  This is a work queue. The person using it is clearing a backlog, not
  browsing, and the oldest waiting request is the one that has been failing
  someone the longest. Newest-first is right for a feed and wrong for a queue.

  WaitingDays is computed here rather than in the UI, so every surface that
  reads this — admin screen, dashboard, a future export — agrees on it.

  Optional filters use (@P IS NULL OR Col = @P) with OPTION (RECOMPILE), which
  belongs on list procedures only (decision 2.30).

  Date filters are IST calendar dates converted ONCE to a UTC half-open range
  (decision 2.28). Never CAST(SubmittedOn AS date): wrong day for 5.5 hours
  daily, and it kills the index seek.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetApprovalRequestList
    @RequestTypeId      int              = NULL,
    @StatusId           int              = NULL,
    @AssignedToUserId   bigint           = NULL,
    @OrganizationUid    uniqueidentifier = NULL,
    @Search             nvarchar(150)    = NULL,
    @FromDate           date             = NULL,   -- IST calendar date
    @ToDate             date             = NULL,   -- IST calendar date, inclusive
    @PageNumber         int              = 1,
    @PageSize           int              = 20
AS
BEGIN
    SET NOCOUNT ON;

    SET @PageNumber = CASE WHEN ISNULL(@PageNumber, 1) < 1 THEN 1 ELSE @PageNumber END;
    SET @PageSize   = CASE WHEN ISNULL(@PageSize, 20) < 1 THEN 20
                           WHEN @PageSize > 200 THEN 200 ELSE @PageSize END;

    DECLARE @FromUtc datetime2 = CASE WHEN @FromDate IS NULL THEN NULL
                                      ELSE dbo.fn_IstDateToUtc(@FromDate) END;
    DECLARE @ToUtc   datetime2 = CASE WHEN @ToDate IS NULL THEN NULL
                                      ELSE dbo.fn_IstDateToUtc(DATEADD(DAY, 1, @ToDate)) END;

    -- Escape the LIKE wildcards so a search for "50%" is a literal search and
    -- not a match against everything.
    DECLARE @SearchPattern nvarchar(160) = CASE
        WHEN NULLIF(LTRIM(RTRIM(@Search)), N'') IS NULL THEN NULL
        ELSE N'%' + REPLACE(REPLACE(REPLACE(LTRIM(RTRIM(@Search)), N'[', N'[[]'), N'%', N'[%]'), N'_', N'[_]') + N'%'
    END;

    DECLARE @Now datetime2 = SYSUTCDATETIME();

    -- ---- result set 1: the page ------------------------------------------
    SELECT
        r.RequestId,
        r.RequestUid,
        r.RequestNo,
        r.RequestTypeId,
        rt.Code                     AS RequestTypeCode,
        rt.Name                     AS RequestTypeName,
        r.StatusId,
        st.Code                     AS StatusCode,
        st.Name                     AS StatusName,
        r.CurrentApprovalLevel,
        r.EntityUid,
        r.OrganizationUid,
        r.RequestorUserId,
        r.ApproverUserId,
        r.SubmittedOn,
        r.CompletedOn,
        r.RowVersion,

        -- The name the queue actually shows, from whichever detail table this
        -- request type uses. COALESCE rather than a UNION so the shape stays
        -- one row per request.
        COALESCE(sd.SchoolName, td.FullName) AS EntityName,

        -- How long it has been waiting. Whole days, floored — "waiting 3 days"
        -- means at least three, which is what a person means by it.
        DATEDIFF(DAY, r.SubmittedOn, @Now)   AS WaitingDays
    FROM dbo.t_mdm_approval_requests r
        INNER JOIN dbo.m_mdm_request_types   rt ON rt.RequestTypeId    = r.RequestTypeId
        INNER JOIN dbo.m_mdm_approval_status st ON st.ApprovalStatusId = r.StatusId
        LEFT  JOIN dbo.t_mdm_school_registration_details  sd ON sd.RequestId = r.RequestId AND sd.Is_Deleted = 0
        LEFT  JOIN dbo.t_mdm_teacher_registration_details td ON td.RequestId = r.RequestId AND td.Is_Deleted = 0
    WHERE r.Is_Deleted = 0
      AND (@RequestTypeId    IS NULL OR r.RequestTypeId   = @RequestTypeId)
      AND (@StatusId         IS NULL OR r.StatusId        = @StatusId)
      AND (@AssignedToUserId IS NULL OR r.ApproverUserId  = @AssignedToUserId)
      AND (@OrganizationUid  IS NULL OR r.OrganizationUid = @OrganizationUid)
      AND (@FromUtc          IS NULL OR r.SubmittedOn    >= @FromUtc)
      AND (@ToUtc            IS NULL OR r.SubmittedOn     < @ToUtc)
      AND (@SearchPattern    IS NULL
           OR r.RequestNo LIKE @SearchPattern
           OR sd.SchoolName LIKE @SearchPattern
           OR td.FullName   LIKE @SearchPattern)
    ORDER BY r.SubmittedOn ASC, r.RequestId ASC   -- oldest first: it is a queue
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);

    -- ---- result set 2: total before paging --------------------------------
    SELECT COUNT_BIG(*) AS TotalRecords
    FROM dbo.t_mdm_approval_requests r
        LEFT JOIN dbo.t_mdm_school_registration_details  sd ON sd.RequestId = r.RequestId AND sd.Is_Deleted = 0
        LEFT JOIN dbo.t_mdm_teacher_registration_details td ON td.RequestId = r.RequestId AND td.Is_Deleted = 0
    WHERE r.Is_Deleted = 0
      AND (@RequestTypeId    IS NULL OR r.RequestTypeId   = @RequestTypeId)
      AND (@StatusId         IS NULL OR r.StatusId        = @StatusId)
      AND (@AssignedToUserId IS NULL OR r.ApproverUserId  = @AssignedToUserId)
      AND (@OrganizationUid  IS NULL OR r.OrganizationUid = @OrganizationUid)
      AND (@FromUtc          IS NULL OR r.SubmittedOn    >= @FromUtc)
      AND (@ToUtc            IS NULL OR r.SubmittedOn     < @ToUtc)
      AND (@SearchPattern    IS NULL
           OR r.RequestNo LIKE @SearchPattern
           OR sd.SchoolName LIKE @SearchPattern
           OR td.FullName   LIKE @SearchPattern)
    OPTION (RECOMPILE);
END
GO


/*==============================================================================
  USP_GetApprovalRequestById

  Five result sets, read with QueryMultipleAsync:
      1 header · 2 typed detail · 3 documents · 4 action trail · 5 payment

  Result set 2 is EMPTY for a request type with no detail row, and result set 3
  is empty before anything is uploaded. The reader must handle empty — an empty
  set is data, not a failure.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetApprovalRequestById
    @RequestId  bigint           = NULL,
    @RequestUid uniqueidentifier = NULL
AS
BEGIN
    SET NOCOUNT ON;

    -- Accept either key. The API uses the Uid; internal callers have the id.
    IF @RequestId IS NULL AND @RequestUid IS NOT NULL
        SELECT @RequestId = RequestId
        FROM dbo.t_mdm_approval_requests
        WHERE RequestUid = @RequestUid AND Is_Deleted = 0;

    -- ---- 1. header --------------------------------------------------------
    SELECT
        r.RequestId, r.RequestUid, r.RequestNo,
        r.RequestTypeId, rt.Code AS RequestTypeCode, rt.Name AS RequestTypeName,
        r.StatusId, st.Code AS StatusCode, st.Name AS StatusName,
        r.CurrentApprovalLevel, r.EntityUid, r.OrganizationUid,
        r.RequestorUserId, r.ApproverUserId,
        r.SubmittedOn, r.CompletedOn, r.RowVersion,
        DATEDIFF(DAY, r.SubmittedOn, SYSUTCDATETIME()) AS WaitingDays
    FROM dbo.t_mdm_approval_requests r
        INNER JOIN dbo.m_mdm_request_types   rt ON rt.RequestTypeId    = r.RequestTypeId
        INNER JOIN dbo.m_mdm_approval_status st ON st.ApprovalStatusId = r.StatusId
    WHERE r.RequestId = @RequestId AND r.Is_Deleted = 0;

    -- ---- 2. typed detail --------------------------------------------------
    SELECT sd.*
    FROM dbo.t_mdm_school_registration_details sd
    WHERE sd.RequestId = @RequestId AND sd.Is_Deleted = 0;

    SELECT
        td.*,
        -- The subjects as one string, so the caller does not need a sixth
        -- result set for what is always rendered as a list.
        (SELECT STRING_AGG(CAST(s.SubjectId AS varchar(10)), ',')
         FROM dbo.t_mdm_teacher_registration_subjects s
         WHERE s.RequestId = td.RequestId AND s.Is_Deleted = 0) AS SubjectIds
    FROM dbo.t_mdm_teacher_registration_details td
    WHERE td.RequestId = @RequestId AND td.Is_Deleted = 0;

    -- ---- 3. documents — current version of each type first ----------------
    SELECT
        d.DocumentId, d.RequestId, d.DocumentTypeId,
        dt.Code AS DocumentTypeCode, dt.Name AS DocumentTypeName, dt.IsMandatory,
        d.FilePath, d.FileName, d.FileSizeKb, d.MimeType, d.Version,
        d.IsVerified, d.VerifiedByUserId, d.VerifiedOn,
        d.RejectionReasonId, rr.Name AS RejectionReasonName, d.Remarks,
        d.CreatedOn
    FROM dbo.t_mdm_request_documents d
        INNER JOIN dbo.m_mdm_document_types dt ON dt.DocumentTypeId = d.DocumentTypeId
        LEFT  JOIN dbo.m_mdm_rejection_reasons rr ON rr.RejectionReasonId = d.RejectionReasonId
    WHERE d.RequestId = @RequestId AND d.Is_Deleted = 0
    ORDER BY d.DocumentTypeId, d.Version DESC;

    -- ---- 4. action trail — newest first -----------------------------------
    SELECT
        a.ApprovalId, a.RequestId, a.LevelNumber,
        a.ActionTypeId, at.Code AS ActionTypeCode, at.Name AS ActionTypeName,
        a.ActionByUserId, a.Remarks, a.ActionOn, a.IpAddress
    FROM dbo.t_mdm_request_approvals a
        INNER JOIN dbo.m_mdm_action_types at ON at.ActionTypeId = a.ActionTypeId
    WHERE a.RequestId = @RequestId AND a.Is_Deleted = 0
    ORDER BY a.ActionOn DESC, a.ApprovalId DESC;

    -- ---- 5. payment (empty in MVP) ----------------------------------------
    SELECT
        p.PaymentId, p.RequestId, p.PlanId, p.Amount,
        p.PaymentModeId, pm.Name AS PaymentModeName,
        p.GatewayRefNo, p.PaymentStatusId, ps.Name AS PaymentStatusName,
        p.PaidOn, p.VerifiedByUserId
    FROM dbo.t_mdm_request_payments p
        INNER JOIN dbo.m_mdm_payment_modes  pm ON pm.PaymentModeId   = p.PaymentModeId
        INNER JOIN dbo.m_mdm_payment_status ps ON ps.PaymentStatusId = p.PaymentStatusId
    WHERE p.RequestId = @RequestId AND p.Is_Deleted = 0;
END
GO


/*==============================================================================
  USP_GetPendingCountsByType — the admin dashboard badges.

  Every request type is returned, including the ones with nothing waiting: a
  badge that disappears at zero reads as a broken screen rather than an empty
  queue. LEFT JOIN, not a filtered aggregate.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetPendingCountsByType
    @OrganizationUid uniqueidentifier = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        rt.RequestTypeId,
        rt.Code AS RequestTypeCode,
        rt.Name AS RequestTypeName,
        COUNT(r.RequestId)                                        AS PendingCount,
        -- The oldest thing waiting, which is what tells an admin whether the
        -- queue is under control or quietly rotting.
        ISNULL(MAX(DATEDIFF(DAY, r.SubmittedOn, SYSUTCDATETIME())), 0) AS OldestWaitingDays
    FROM dbo.m_mdm_request_types rt
        LEFT JOIN dbo.t_mdm_approval_requests r
               ON r.RequestTypeId = rt.RequestTypeId
              AND r.StatusId      = 1              -- Pending
              AND r.Is_Deleted    = 0
              AND (@OrganizationUid IS NULL OR r.OrganizationUid = @OrganizationUid)
    WHERE rt.Is_Deleted = 0 AND rt.Is_Active = 1
    GROUP BY rt.RequestTypeId, rt.Code, rt.Name, rt.DisplayOrder
    ORDER BY rt.DisplayOrder
    OPTION (RECOMPILE);
END
GO

PRINT '    Approval read procedures ready.';
GO
