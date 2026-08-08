/*==============================================================================
  jp_sso — 002_indexes / 001_ix_t_sso_users.sql

  Non-clustered indexes for t_sso_users.

  The UNIQUE business-key indexes (Email, Mobile, UserUid) are NOT here — they
  live in 01_tables/008_t_sso_users.sql, alongside the CHECK and FOREIGN KEY
  constraints, because they are integrity rules rather than tuning. This file
  holds only indexes that exist to make queries fast.

  Every filtered index repeats `WHERE Is_Deleted = 0`. That is not decoration:
  SQL Server can only use a filtered index when the query's own predicate
  implies the filter, so a query that forgets `Is_Deleted = 0` silently gets a
  scan. Every list procedure must carry that predicate.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*------------------------------------------------------------------------------
  Admin user listing: USP_GetUserList, filtered by user type and status.

  Leading column is UserTypeId because the admin screens are always scoped to
  one type ("all schools", "all teachers") and only then narrowed by status.

  The INCLUDE list covers the grid columns, so the paged query is answered
  entirely from this index without touching the clustered index for every row.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_users_UserTypeId_StatusId' AND object_id = OBJECT_ID('dbo.t_sso_users'))
BEGIN
    PRINT '    Creating index [IX_t_sso_users_UserTypeId_StatusId] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_users_UserTypeId_StatusId
        ON dbo.t_sso_users (UserTypeId, StatusId)
        INCLUDE (UserUid, Email, Mobile, OrganizationUid, CreatedOn, LastLoginOn)
        WHERE Is_Deleted = 0;
END
GO

/*------------------------------------------------------------------------------
  The verification queue: every account sitting at StatusId = 1 (Pending),
  regardless of type. This is the admin's landing screen, so it is worth its
  own index rather than making it scan the composite above.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_users_StatusId' AND object_id = OBJECT_ID('dbo.t_sso_users'))
BEGIN
    PRINT '    Creating index [IX_t_sso_users_StatusId] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_users_StatusId
        ON dbo.t_sso_users (StatusId)
        INCLUDE (UserUid, UserTypeId, Email, CreatedOn)
        WHERE Is_Deleted = 0;
END
GO

/*------------------------------------------------------------------------------
  Tenant scoping — "every user in my school".

  This is the index behind the IDOR rule: the OrganizationUid comes from the
  JWT and is applied to every org-scoped query, so it is on the hot path of
  effectively every school-side list.

  Excludes NULLs, which would otherwise be most of the table (admins and
  teachers belong to no organisation) and are never searched for.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_users_OrganizationUid' AND object_id = OBJECT_ID('dbo.t_sso_users'))
BEGIN
    PRINT '    Creating index [IX_t_sso_users_OrganizationUid] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_users_OrganizationUid
        ON dbo.t_sso_users (OrganizationUid)
        INCLUDE (UserUid, UserTypeId, StatusId, Email, Mobile)
        WHERE Is_Deleted = 0 AND OrganizationUid IS NOT NULL;
END
GO

/*------------------------------------------------------------------------------
  Self-referencing FK. Without an index here, deleting or updating a user
  forces a scan to check for dependent rows — and "who did this admin create"
  is a real audit question.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_sso_users_CreatedByUserId' AND object_id = OBJECT_ID('dbo.t_sso_users'))
BEGIN
    PRINT '    Creating index [IX_t_sso_users_CreatedByUserId] ...';

    CREATE NONCLUSTERED INDEX IX_t_sso_users_CreatedByUserId
        ON dbo.t_sso_users (CreatedByUserId)
        WHERE CreatedByUserId IS NOT NULL;
END
GO
