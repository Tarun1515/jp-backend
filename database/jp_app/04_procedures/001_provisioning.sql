/*==============================================================================
  jp_app — 04_procedures / 001_provisioning.sql

  USP_ProvisionSchoolFromApproval
  USP_FindOrphanedApprovals   (the reconciliation query)

  ⚠️ Pulled forward from Phase 3 by Phase 2D, for the same reason as
  t_app_schools: the cross-database step after an approval needs somewhere real
  to write.

  ---------------------------------------------------------------------------
  🔴 WHY THESE MUST BE IDEMPOTENT
  ---------------------------------------------------------------------------
  There is no distributed transaction across jp_sso, jp_mdm and jp_app, and
  there deliberately never will be (decision 2.2). The API orchestrates three
  separate commits, so any one of them can fail after an earlier one succeeded,
  and the operator's only recovery is to run it again.

  A retry that created a second school would turn a recoverable failure into a
  data problem. So provisioning keys on SourceRequestUid: called twice, the
  second call returns the row the first created.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*==============================================================================
  USP_ProvisionSchoolFromApproval

  Creates the school that an approved registration earned. Called by the API
  AFTER USP_ProcessApprovalAction reported IsCompleted, and after the user has
  been activated in jp_sso.

  Returns the standard envelope plus SchoolUid, and Code = 'ALREADY_PROVISIONED'
  when the row already existed — which is a SUCCESS, because the caller wanted
  the school to exist and it does.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ProvisionSchoolFromApproval
    @SourceRequestUid   uniqueidentifier,
    @OrganizationUid    uniqueidentifier,
    @SchoolName         nvarchar(200),
    @SchoolTypeId       int            = NULL,
    @BoardId            int            = NULL,
    @AffiliationNumber  varchar(50)    = NULL,
    @RegistrationNo     varchar(50)    = NULL,
    @LogoPath           nvarchar(500)  = NULL,
    @GroupType          tinyint        = NULL,
    @EstablishedYear    smallint       = NULL,
    @AboutSchool        nvarchar(max)  = NULL,
    @Website            nvarchar(255)  = NULL,
    @ContactEmail       nvarchar(150)  = NULL,
    @ContactMobile      varchar(15)    = NULL,
    @PrincipalName      nvarchar(150)  = NULL,
    @HrContactName      nvarchar(150)  = NULL,
    @HrContactMobile    varchar(15)    = NULL,
    @AddressLine1       nvarchar(250)  = NULL,
    @AddressLine2       nvarchar(250)  = NULL,
    @CityId             int            = NULL,
    @DistrictId         int            = NULL,
    @StateId            int            = NULL,
    @Pincode            varchar(10)    = NULL,
    @PanNumber          varchar(10)    = NULL,

    /*
      🔴 The account that registered this school. It becomes the school's
      OWNER, and without that row the scope resolver gives them nothing —
      every branch, job and applicant list would be empty with no error.

      Optional so an approval that predates this parameter still provisions;
      the owner row is simply skipped and USP_ProvisionSchoolOwner can add it
      afterwards.
    */
    @OwnerUserUid       uniqueidentifier = NULL,

    /*
      🔴 The plan the new school starts on, resolved by the API.

      Plans live in m_mdm_plans, in jp_mdm. This procedure is in jp_app and
      cannot read across (decision 2.2), so the caller looks up the default
      plan for a school and passes the id — exactly the shape the rest of the
      orchestration takes.

      Required. A school provisioned without a plan is the "no subscription"
      state the whole design exists to avoid, and accepting NULL here would
      make it reachable by forgetting one argument.
    */
    @PlanId             int            = NULL,

    @VerifiedByUserId   bigint         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = NULL,
            @SchoolUid uniqueidentifier = NULL,
            @Now datetime2 = SYSUTCDATETIME();

    IF @SourceRequestUid IS NULL
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The source request is required.';
    ELSE IF @OrganizationUid IS NULL
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The organisation is required.';
    ELSE IF ISNULL(@SchoolName, N'') = N''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The school name is required.';
    ELSE IF @PlanId IS NULL
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'A plan is required. Every account starts on one.';

    -- Already provisioned? Return it. This is the retry path, and it succeeds.
    IF @Code IS NULL
    BEGIN
        SELECT @Id = SchoolId, @SchoolUid = SchoolUid
        FROM dbo.t_app_schools
        WHERE SourceRequestUid = @SourceRequestUid AND Is_Deleted = 0;

        IF @Id IS NOT NULL
            SELECT @Status = 1, @Code = 'ALREADY_PROVISIONED',
                   @Message = N'This school was already created for that approval.';
    END

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            /*
              🔴 FOUR INSERTS, ONE GUARD, ONE TRANSACTION.

              The school, its head-office branch, its subscription and its
              owner membership are all created here — INSIDE the
              SourceRequestUid guard above, not alongside it.

              Outside the guard, a retry after a partial failure would find the
              school already there, skip it, and then insert a SECOND head
              office and a SECOND subscription. Nothing would complain at the
              time; the school would simply have two addresses and two plans,
              and the person who eventually noticed would have no way to tell
              which was meant.

              Inside it, and inside one transaction, the set is atomic: either
              a school with a branch and a plan, or nothing at all.
            */
            INSERT INTO dbo.t_app_schools
                (OrganizationUid, SourceRequestUid, SchoolName, SchoolTypeId, BoardId,
                 AffiliationNumber, RegistrationNo, PanNumber, LogoPath, GroupType, EstablishedYear,
                 AboutSchool, Website, ContactEmail, ContactMobile,
                 PrincipalName, HrContactName, HrContactMobile,
                 AddressLine1, AddressLine2, CityId, DistrictId, StateId, Pincode,
                 IsVerified, VerifiedOn, VerifiedByUserId, CreatedBy)
            VALUES
                (@OrganizationUid, @SourceRequestUid, @SchoolName, @SchoolTypeId, @BoardId,
                 @AffiliationNumber, @RegistrationNo, @PanNumber, @LogoPath, @GroupType, @EstablishedYear,
                 @AboutSchool, @Website, @ContactEmail, @ContactMobile,
                 @PrincipalName, @HrContactName, @HrContactMobile,
                 @AddressLine1, @AddressLine2, @CityId, @DistrictId, @StateId, @Pincode,
                 1, @Now, @VerifiedByUserId, @VerifiedByUserId);

            SET @Id = SCOPE_IDENTITY();
            SELECT @SchoolUid = SchoolUid FROM dbo.t_app_schools WHERE SchoolId = @Id;

            /*
              The head office. Named after the school rather than asked for:
              registration deliberately does not collect a branch list, and a
              school that has not yet decided to use the product should not be
              enumerating campuses. Phase 3 lets them rename it.
            */
            INSERT INTO dbo.t_app_school_branches
                (SchoolId, BranchName, IsHeadOffice,
                 AddressLine1, AddressLine2, CityId, DistrictId, StateId, Pincode,
                 ContactEmail, ContactMobile, CreatedBy)
            VALUES
                (@Id, @SchoolName, 1,
                 @AddressLine1, @AddressLine2, @CityId, @DistrictId, @StateId, @Pincode,
                 @ContactEmail, @ContactMobile, @VerifiedByUserId);

            /*
              The subscription. EndsOn NULL because the free plan does not
              expire; StatusId 1 is Active.

              Keyed on the ORGANISATION, not the school: a group with several
              schools under one organisation is on one plan, which is what
              UQ_t_app_subscriptions_OneActivePerOwner already asserts.

              🔴 WHICH IS WHY THIS IS CONDITIONAL, AND WHY IT HAS ITS OWN CATCH.

              A group registering its SECOND school reaches here with the
              organisation already on a plan. An unconditional insert raises
              2601 and — because the outer CATCH rolls back the whole
              transaction — destroys the school and branch created moments
              earlier. The registration form asks "one campus or several"
              (2.50), so this is an ordinary path, not an edge case.

              The nested TRY/CATCH covers the remaining race: two approvals for
              one organisation committing at the same instant. The loser
              swallows its own 2601 and keeps its school, because the
              organisation ends up on exactly one plan either way — which is all
              the index was ever asserting.
            */
            IF NOT EXISTS (SELECT 1 FROM dbo.t_app_subscriptions
                           WHERE OwnerUid = @OrganizationUid AND StatusId = 1 AND Is_Deleted = 0)
            BEGIN
                BEGIN TRY
                    INSERT INTO dbo.t_app_subscriptions
                        (OwnerUid, PlanId, StartsOn, EndsOn, StatusId, AutoRenew, CreatedBy)
                    VALUES
                        (@OrganizationUid, @PlanId, @Now, NULL, 1, 0, @VerifiedByUserId);
                END TRY
                BEGIN CATCH
                    -- Somebody else gave this organisation its plan first. That
                    -- is the outcome we wanted; it is not a reason to lose a
                    -- school.
                    IF ERROR_NUMBER() NOT IN (2601, 2627) THROW;
                END CATCH
            END

            /*
              🔴 THE OWNER. The row nothing wrote until Phase 3C.

              The person who registered the school works there, and is its
              owner (RoleInSchool = 1). Every school-scoped query resolves
              visibility through this table — with it empty, the resolver
              returned nothing for everybody, which would have looked like a
              broken query rather than a missing row.

              ⚠️ No rows in t_app_school_user_branches, deliberately: an owner
              sees every campus and the ABSENCE of link rows is what says so
              (2.51). Enumerating them per branch would need a backfill on
              every new campus.
            */
            IF @OwnerUserUid IS NOT NULL
                INSERT INTO dbo.t_app_school_users
                    (SchoolId, UserUid, RoleInSchool, DesignationText, CreatedBy)
                VALUES (@Id, @OwnerUserUid, 1, NULL, @VerifiedByUserId);

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'School created.';
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @SourceRequestUid AS sourceRequestUid, @OrganizationUid AS organizationUid,
                       @SchoolName AS schoolName
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_ProvisionSchoolFromApproval', @CreatedBy = @VerifiedByUserId;

            /*
              🔴 A DUPLICATE KEY IS ONLY "ALREADY PROVISIONED" IF THE SCHOOL IS
              ACTUALLY THERE.

              This block used to assume it. Any 2601 in the transaction was read
              as "a concurrent retry won the race" — but the duplicate can come
              from the subscription or the head-office index instead, and the
              rollback then removes the school this procedure had just created.
              It returned Status = 1 anyway, so the orchestration logged
              "school provisioned" for a school that did not exist.

              That is the exact failure 2.48 exists to prevent, reached from
              inside the procedure the decision is about. It was found by putting
              a real registration through the real flow and then looking for the
              row, which is the only reason it was found at all.

              So: look first, and only claim success if the row answers.
            */
            IF @ErrNumber IN (2601, 2627)
            BEGIN
                SELECT @Id = SchoolId, @SchoolUid = SchoolUid
                FROM dbo.t_app_schools
                WHERE SourceRequestUid = @SourceRequestUid AND Is_Deleted = 0;

                IF @Id IS NOT NULL
                    SELECT @Status = 1, @Code = 'ALREADY_PROVISIONED',
                           @Message = N'This school was already created for that approval.';
                ELSE
                    -- The duplicate was somewhere else and the school is gone
                    -- with the rollback. Say so.
                    SELECT @Status = 0, @Code = 'DUPLICATE_RECORD',
                           @Message = N'The school could not be created: a duplicate key was rejected '
                                    + N'and nothing was saved. This has been logged.';
            END
            ELSE
                THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id,
           @SchoolUid AS SchoolUid;
END
GO


/*==============================================================================
  USP_FindOrphanedApprovals — 🔴 THE RECONCILIATION QUERY

  Finds approvals that COMPLETED in jp_mdm but whose school never appeared
  here. That is the exact shape of a partial cross-database failure: the
  approval committed, the user may even have been activated, and then
  provisioning failed — leaving someone who can sign in to an empty shell.

  Without this the failure is invisible. The approval looks done, the admin has
  moved on, and the only person who finds out is the school owner staring at a
  blank screen.

  ---------------------------------------------------------------------------
  WHY IT LIVES IN jp_app AND TAKES A TABLE PARAMETER
  ---------------------------------------------------------------------------
  It cannot join jp_mdm to jp_app — that is the cross-database join decision
  2.2 forbids. So the API reads the completed approvals from jp_mdm, passes
  them in, and this procedure answers which of them have no school.

  Phase 8 turns this into a scheduled check. For now it exists, is documented,
  and can be run by hand the moment something looks wrong.

  Usage from the API: see ApprovalOrchestrationService.FindOrphanedAsync.
==============================================================================*/
IF TYPE_ID(N'dbo.CompletedApprovalList') IS NULL
BEGIN
    PRINT '    Creating table type [CompletedApprovalList] ...';
END
GO

IF TYPE_ID(N'dbo.CompletedApprovalList') IS NULL
    CREATE TYPE dbo.CompletedApprovalList AS TABLE
    (
        RequestUid       uniqueidentifier NOT NULL PRIMARY KEY,
        RequestNo        varchar(30)      NOT NULL,
        OrganizationUid  uniqueidentifier NULL,
        CompletedOn      datetime2        NOT NULL
    );
GO

CREATE OR ALTER PROCEDURE dbo.USP_FindOrphanedApprovals
    @Completed dbo.CompletedApprovalList READONLY
AS
BEGIN
    SET NOCOUNT ON;

    SELECT
        c.RequestUid,
        c.RequestNo,
        c.OrganizationUid,
        c.CompletedOn,
        DATEDIFF(HOUR, c.CompletedOn, SYSUTCDATETIME()) AS HoursSinceCompleted
    FROM @Completed c
    WHERE NOT EXISTS (
        SELECT 1 FROM dbo.t_app_schools s
        WHERE s.SourceRequestUid = c.RequestUid AND s.Is_Deleted = 0)
    ORDER BY c.CompletedOn;
END
GO

PRINT '    Provisioning and reconciliation procedures ready.';
GO
