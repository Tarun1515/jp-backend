/*==============================================================================
  jp_sso — 04_procedures / 009_users_by_uid.sql

  USP_GetUsersByUids     the accounts behind a list of Uids
  USP_GetUserByEmail     one account, by exact address

  ---------------------------------------------------------------------------
  🔴 WHY THESE EXIST: THE CROSS-DATABASE JOIN NOBODY IS ALLOWED TO WRITE
  ---------------------------------------------------------------------------
  A school's team screen shows a person's email beside their role. The role is
  in jp_app.t_app_school_users; the email is in jp_sso.t_sso_users; and no query
  may join across the two (decision 2.2).

  So the join happens in the API, in memory, and it needs a way to ask jp_sso
  "give me these fifteen accounts". Without that, the caller's options are a
  query per member — fifteen round trips for one screen — or reusing
  USP_GetUserList, which is a paged scan with a LIKE and would answer a
  different question by accident.

  ---------------------------------------------------------------------------
  ⚠️ BOTH ARE ORGANISATION-SCOPED, AND THAT IS NOT DECORATION
  ---------------------------------------------------------------------------
  @OrganizationUid is required and filtered on. The caller already resolved the
  Uids from its own school's membership rows, so the filter should never exclude
  anything — which is exactly why it belongs here. A future caller that gets the
  list from somewhere less trustworthy inherits the check instead of having to
  remember it, and an account from another organisation simply does not come
  back.

  ---------------------------------------------------------------------------
  ⚠️ IDENTITY ONLY. NEVER A CREDENTIAL.
  ---------------------------------------------------------------------------
  No hash, no salt, no token, no failed-attempt count. These feed a team list
  and an invitation retry; nothing about how somebody signs in belongs in
  either.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_sso;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*------------------------------------------------------------------------------
  A list of Uids, for the API to hand over in one call.

  ⚠️ Guarded: a table type cannot be altered, only dropped and recreated, and
  the drop fails while any procedure references it.
------------------------------------------------------------------------------*/
IF TYPE_ID(N'dbo.GuidIdList') IS NULL
BEGIN
    PRINT '    Creating table type [GuidIdList] ...';

    CREATE TYPE dbo.GuidIdList AS TABLE
    (
        Id uniqueidentifier NOT NULL PRIMARY KEY
    );
END
GO


/*==============================================================================
  USP_GetUsersByUids
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetUsersByUids
    @UserUids        dbo.GuidIdList READONLY,
    @OrganizationUid uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        u.UserUid,
        u.Email,
        u.Mobile,
        u.StatusId,
        us.Code             AS StatusCode,
        us.Name             AS StatusName,
        u.IsEmailVerified,
        u.LastLoginOn,
        u.CreatedOn
    FROM dbo.t_sso_users u
        INNER JOIN @UserUids i           ON i.Id           = u.UserUid
        INNER JOIN dbo.m_sso_user_status us ON us.StatusId = u.StatusId
    WHERE u.Is_Deleted = 0
      AND u.OrganizationUid = @OrganizationUid;
END
GO


/*==============================================================================
  USP_GetUserByEmail

  ---------------------------------------------------------------------------
  🔴 THIS IS THE RETRY PATH FOR A HALF-COMPLETED INVITATION
  ---------------------------------------------------------------------------
  Inviting a colleague writes to two databases with no distributed transaction:
  the account in jp_sso, then the membership in jp_app. When the second write
  fails, the account exists and the person has nothing.

  Retrying the invite then hits DUPLICATE_EMAIL from USP_InviteSchoolUser and,
  without this, would be stuck forever — the fix would be a manual INSERT. With
  it, the API looks the existing account up, confirms it belongs to this
  organisation, and finishes the half that failed.

  ⚠️ Scoped to the organisation for the same reason as above: this must not
  become a way to ask whether an arbitrary address has an account. A caller
  outside the organisation gets nothing back, which is the same answer they get
  for an address that does not exist at all.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetUserByEmail
    @Email           nvarchar(150),
    @OrganizationUid uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    -- Stored lowercase, so compared lowercase. The collation is case-insensitive
    -- anyway; this keeps the comparison honest if that ever changes.
    SET @Email = LOWER(LTRIM(RTRIM(ISNULL(@Email, N''))));

    SELECT
        u.UserId,
        u.UserUid,
        u.UserTypeId,
        u.StatusId,
        u.Email,
        u.OrganizationUid,
        u.[RowVersion]
    FROM dbo.t_sso_users u
    WHERE u.Is_Deleted      = 0
      AND u.Email           = @Email
      AND u.OrganizationUid = @OrganizationUid;
END
GO

PRINT '    User lookup procedures ready.';
GO
