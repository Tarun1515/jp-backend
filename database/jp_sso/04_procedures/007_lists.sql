/*==============================================================================
  jp_sso — 04_procedures / 007_lists.sql

  Read-only list procedures.

  ---------------------------------------------------------------------------
  OPTIONAL FILTERS WITHOUT DYNAMIC SQL
  ---------------------------------------------------------------------------
  Every optional filter uses (@Param IS NULL OR Col = @Param). On its own that
  produces one cached plan reused for every combination of filters, which is
  usually wrong for most of them. OPTION (RECOMPILE) makes the optimiser build
  a plan for the actual arguments each time — it can then discard the unused
  branches entirely and pick the right index.

  RECOMPILE is confined to these list procedures, exactly as the conventions
  require. It must never appear on the login path, where the cost would be
  paid on every single sign-in.

  Sorting is resolved through a CASE whitelist rather than concatenated SQL, so
  a sortBy value from the query string can never become executable text.

  ---------------------------------------------------------------------------
  DATE FILTERS (decision 2.28)
  ---------------------------------------------------------------------------
  @FromDate and @ToDate are IST CALENDAR dates. They are converted to a UTC
  half-open range ONCE, into variables, and the filter is then a plain column
  comparison that can still seek the index. Never CAST(CreatedOn AS date).
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_GetUserList

  Two result sets: the page, then the total row count.

  Two rather than a windowed COUNT(*) OVER() on every row, because the count
  query can be answered from a narrower index than the page query needs.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetUserList
    @UserTypeId         int              = NULL,
    @StatusId           int              = NULL,
    @OrganizationUid    uniqueidentifier = NULL,
    @Search             nvarchar(150)    = NULL,
    @FromDate           date             = NULL,   -- IST calendar date
    @ToDate             date             = NULL,   -- IST calendar date, inclusive
    @SortBy             varchar(30)      = 'CreatedOn',
    @SortDirection      varchar(4)       = 'DESC',
    @PageNumber         int              = 1,
    @PageSize           int              = 20
AS
BEGIN
    SET NOCOUNT ON;

    -- Clamp, matching JP.Domain.Common.PagedRequest.
    SET @PageNumber = CASE WHEN ISNULL(@PageNumber, 1) < 1 THEN 1 ELSE @PageNumber END;
    SET @PageSize   = CASE WHEN ISNULL(@PageSize, 20) < 1 THEN 20
                           WHEN @PageSize > 200 THEN 200
                           ELSE @PageSize END;

    SET @SortDirection = CASE WHEN UPPER(ISNULL(@SortDirection, 'ASC')) = 'DESC' THEN 'DESC' ELSE 'ASC' END;
    SET @Search = NULLIF(LTRIM(RTRIM(ISNULL(@Search, N''))), N'');

    DECLARE @SearchPattern nvarchar(160) = CASE WHEN @Search IS NULL THEN NULL ELSE N'%' + @Search + N'%' END;

    -- IST day boundaries -> UTC half-open range. @ToDate is inclusive, so the
    -- upper bound is the START of the following IST day and the comparison is
    -- strictly less-than.
    DECLARE @FromUtc datetime2 = CASE WHEN @FromDate IS NULL THEN NULL
                                      ELSE dbo.fn_IstDateToUtc(@FromDate) END;
    DECLARE @ToUtc   datetime2 = CASE WHEN @ToDate IS NULL THEN NULL
                                      ELSE dbo.fn_IstDateToUtc(DATEADD(DAY, 1, @ToDate)) END;

    -- ---- result set 1: the page -----------------------------------------
    SELECT
        u.UserUid,
        u.UserTypeId,
        ut.Name         AS UserTypeName,
        u.StatusId,
        us.Code         AS StatusCode,
        us.Name         AS StatusName,
        u.Email,
        u.Mobile,
        u.IsEmailVerified,
        u.IsMobileVerified,
        u.OrganizationUid,
        u.LastLoginOn,
        u.FailedAttemptCount,
        u.CreatedOn,
        u.[RowVersion]
    FROM dbo.t_sso_users u
    INNER JOIN dbo.m_sso_user_types  ut ON ut.UserTypeId = u.UserTypeId
    INNER JOIN dbo.m_sso_user_status us ON us.StatusId   = u.StatusId
    WHERE u.Is_Deleted = 0
      AND (@UserTypeId      IS NULL OR u.UserTypeId      = @UserTypeId)
      AND (@StatusId        IS NULL OR u.StatusId        = @StatusId)
      AND (@OrganizationUid IS NULL OR u.OrganizationUid = @OrganizationUid)
      AND (@SearchPattern   IS NULL OR u.Email LIKE @SearchPattern
                                    OR u.Mobile LIKE @SearchPattern)
      AND (@FromUtc IS NULL OR u.CreatedOn >= @FromUtc)
      AND (@ToUtc   IS NULL OR u.CreatedOn <  @ToUtc)
    ORDER BY
        -- Whitelist. An unrecognised @SortBy falls through to CreatedOn.
        CASE WHEN @SortDirection = 'ASC' THEN
            CASE @SortBy
                WHEN 'Email'       THEN u.Email
                WHEN 'Mobile'      THEN CAST(u.Mobile AS nvarchar(150))
                WHEN 'LastLoginOn' THEN CONVERT(nvarchar(30), u.LastLoginOn, 126)
                WHEN 'StatusId'    THEN RIGHT(N'0000000000' + CAST(u.StatusId AS nvarchar(10)), 10)
                ELSE CONVERT(nvarchar(30), u.CreatedOn, 126)
            END
        END ASC,
        CASE WHEN @SortDirection = 'DESC' THEN
            CASE @SortBy
                WHEN 'Email'       THEN u.Email
                WHEN 'Mobile'      THEN CAST(u.Mobile AS nvarchar(150))
                WHEN 'LastLoginOn' THEN CONVERT(nvarchar(30), u.LastLoginOn, 126)
                WHEN 'StatusId'    THEN RIGHT(N'0000000000' + CAST(u.StatusId AS nvarchar(10)), 10)
                ELSE CONVERT(nvarchar(30), u.CreatedOn, 126)
            END
        END DESC,
        -- Tie-break, so paging is stable when the sort column has duplicates.
        u.UserId DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);

    -- ---- result set 2: total before paging -------------------------------
    SELECT COUNT_BIG(*) AS TotalRecords
    FROM dbo.t_sso_users u
    WHERE u.Is_Deleted = 0
      AND (@UserTypeId      IS NULL OR u.UserTypeId      = @UserTypeId)
      AND (@StatusId        IS NULL OR u.StatusId        = @StatusId)
      AND (@OrganizationUid IS NULL OR u.OrganizationUid = @OrganizationUid)
      AND (@SearchPattern   IS NULL OR u.Email LIKE @SearchPattern
                                    OR u.Mobile LIKE @SearchPattern)
      AND (@FromUtc IS NULL OR u.CreatedOn >= @FromUtc)
      AND (@ToUtc   IS NULL OR u.CreatedOn <  @ToUtc)
    OPTION (RECOMPILE);
END
GO


/*==============================================================================
  USP_GetRoleList

  Roles available to an organisation: the global system roles plus that
  organisation's own custom ones.

  @OrganizationUid comes from the caller's JWT. Passing another organisation's
  Uid returns only the global roles — never that organisation's private ones.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetRoleList
    @OrganizationUid    uniqueidentifier = NULL,
    @UserTypeId         int              = NULL,
    @IncludeSystemRoles bit              = 1
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        r.RoleId,
        r.RoleCode,
        r.RoleName,
        r.UserTypeId,
        ut.Name AS UserTypeName,
        r.IsSystemRole,
        r.OrganizationUid,
        r.Is_Active,
        (SELECT COUNT(*) FROM dbo.t_sso_role_permissions rp
         WHERE rp.RoleId = r.RoleId AND rp.Is_Deleted = 0) AS PermissionCount
    FROM dbo.t_sso_roles r
    INNER JOIN dbo.m_sso_user_types ut ON ut.UserTypeId = r.UserTypeId
    WHERE r.Is_Deleted = 0
      AND (@UserTypeId IS NULL OR r.UserTypeId = @UserTypeId)
      AND (
            (r.OrganizationUid IS NULL AND @IncludeSystemRoles = 1)
         OR (@OrganizationUid IS NOT NULL AND r.OrganizationUid = @OrganizationUid)
          )
    ORDER BY r.IsSystemRole DESC, r.UserTypeId, r.RoleName
    OPTION (RECOMPILE);
END
GO


/*==============================================================================
  USP_GetPermissionList

  The full permission catalogue, grouped by module. Backs the permission matrix
  in the role editor.

  Small and static, so it is a straight read with no paging.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetPermissionList
    @ModuleId int = NULL
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.PermissionId,
        p.PermissionCode,
        p.PermissionName,
        p.ModuleId,
        m.Code AS ModuleCode,
        m.Name AS ModuleName,
        m.DisplayOrder AS ModuleDisplayOrder,
        p.DisplayOrder
    FROM dbo.t_sso_permissions p
    INNER JOIN dbo.m_sso_modules m ON m.ModuleId = p.ModuleId
    WHERE p.Is_Deleted = 0 AND p.Is_Active = 1
      AND m.Is_Deleted = 0 AND m.Is_Active = 1
      AND (@ModuleId IS NULL OR p.ModuleId = @ModuleId)
    ORDER BY m.DisplayOrder, p.DisplayOrder, p.PermissionCode
    OPTION (RECOMPILE);
END
GO


/*==============================================================================
  USP_GetRolePermissions

  Which permissions a single role grants.

  Returns the WHOLE catalogue with an IsGranted flag rather than only the
  granted rows, because the role editor renders a checkbox per permission and
  would otherwise need a second call plus a client-side join to know what to
  leave unticked.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetRolePermissions
    @RoleId int
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        p.PermissionId,
        p.PermissionCode,
        p.PermissionName,
        p.ModuleId,
        m.Code AS ModuleCode,
        m.Name AS ModuleName,
        CAST(CASE WHEN rp.RolePermissionId IS NULL THEN 0 ELSE 1 END AS bit) AS IsGranted
    FROM dbo.t_sso_permissions p
    INNER JOIN dbo.m_sso_modules m ON m.ModuleId = p.ModuleId
    LEFT JOIN dbo.t_sso_role_permissions rp
           ON rp.PermissionId = p.PermissionId
          AND rp.RoleId = @RoleId
          AND rp.Is_Deleted = 0
          AND rp.Is_Active = 1
    WHERE p.Is_Deleted = 0 AND p.Is_Active = 1
    ORDER BY m.DisplayOrder, p.DisplayOrder, p.PermissionCode
    OPTION (RECOMPILE);
END
GO

PRINT '    List procedures ready.';
GO
