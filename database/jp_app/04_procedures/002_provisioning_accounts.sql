/*==============================================================================
  jp_app — 04_procedures / 002_provisioning_accounts.sql

  USP_ProvisionTeacherProfile   the row a teacher signup must create
  USP_ProvisionSchoolOwner      the membership an approved school must create

  ---------------------------------------------------------------------------
  🔴 WHY BOTH OF THESE EXIST
  ---------------------------------------------------------------------------
  G21: teacher signup creates an account in jp_sso and nothing in jp_app. Phase
  3B backfilled the accounts that already existed; every teacher registering
  after it fell straight back into the same hole, one at a time. A backfill that
  has to be re-run is not a fix, it is a schedule.

  And the school side turned out to be worse, in a way nobody had looked at:
  NOTHING has ever written t_app_school_users. Zero rows. Provisioning creates
  the school, its head office and its subscription, and never records that the
  person who registered it works there.

  That matters more than it sounds. Every school-scoped query from Phase 4
  onward resolves visibility through t_app_school_users — so with that table
  empty, the scope resolver returns nothing for everybody, and every branch
  list, job list and applicant list would have been empty for every user. It
  would have looked like a broken query rather than a missing row.

  ---------------------------------------------------------------------------
  🔴 IDEMPOTENT, KEYED ON THE Uid, 2601 IS "ALREADY DONE"
  ---------------------------------------------------------------------------
  Both are cross-database steps with no distributed transaction (2.2), so both
  follow the shape 2.48 settled on: run again freely, treat a duplicate-key
  violation as success rather than as an error, and never pre-check-then-insert.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_ProvisionTeacherProfile

  Called by JP.Sso.Api immediately after a teacher account is created, and safe
  to call at any later point — a repair job, a first sign-in, a support action.

  ⚠️ Takes @PlanId rather than looking the plan up. Plans live in jp_mdm and
  this procedure is in jp_app; the API reads the default plan and passes the id,
  exactly as USP_ProvisionSchoolFromApproval does (2.50).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ProvisionTeacherProfile
    @UserUid    uniqueidentifier,
    @FullName   nvarchar(150) = NULL,
    @PlanId     int
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = NULL,
            @TeacherUid uniqueidentifier = NULL,
            @Now datetime2 = SYSUTCDATETIME();

    IF @UserUid IS NULL
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The account is required.';
    ELSE IF @PlanId IS NULL
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'A plan is required. Every account starts on one.';

    -- Already provisioned? Return it. This is the retry path, and it succeeds.
    IF @Code IS NULL
    BEGIN
        SELECT @Id = TeacherId, @TeacherUid = TeacherUid
        FROM dbo.t_app_teachers
        WHERE UserUid = @UserUid AND Is_Deleted = 0;

        IF @Id IS NOT NULL
            SELECT @Status = 1, @Code = 'ALREADY_PROVISIONED',
                   @Message = N'This account already has a profile.';
    END

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            /*
              Two inserts, one transaction — the same rule as the school side
              (2.50). A teacher with a profile and no plan is the "no
              subscription" state the whole design exists to avoid, and it would
              be reachable by this transaction being split.

              ⚠️ FullName may be NULL here. The SSO account carries an email and
              a mobile, not a display name, so a signup has nothing better to
              offer until the teacher fills their profile in. An empty name is
              honest; inventing one from the email address would put a value on
              a screen that the person never typed.
            */
            INSERT INTO dbo.t_app_teachers (UserUid, FullName, CreatedBy)
            VALUES (@UserUid, ISNULL(@FullName, N''), NULL);

            SET @Id = SCOPE_IDENTITY();
            SELECT @TeacherUid = TeacherUid FROM dbo.t_app_teachers WHERE TeacherId = @Id;

            INSERT INTO dbo.t_app_subscriptions
                (OwnerUid, PlanId, StartsOn, EndsOn, StatusId, AutoRenew)
            VALUES (@UserUid, @PlanId, @Now, NULL, 1, 0);

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'Profile created.';
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @UserUid AS userUid, @PlanId AS planId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_ProvisionTeacherProfile';

            /*
              🔴 A concurrent call won the race. The caller wanted the profile to
              exist, and it does — same reading as 2.48.
            */
            IF @ErrNumber IN (2601, 2627)
            BEGIN
                SELECT @Id = TeacherId, @TeacherUid = TeacherUid
                FROM dbo.t_app_teachers
                WHERE UserUid = @UserUid AND Is_Deleted = 0;

                SELECT @Status = 1, @Code = 'ALREADY_PROVISIONED',
                       @Message = N'This account already has a profile.';
            END
            ELSE
                THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id,
           @TeacherUid AS TeacherUid;
END
GO


/*==============================================================================
  USP_ProvisionSchoolOwner

  🔴 THE ROW NOTHING HAS EVER WRITTEN.

  A school is provisioned from an approved registration, and the person who
  submitted it is its owner. That was true from Phase 2D onward and was never
  recorded anywhere — t_app_school_users has been empty since it was created.

  RoleInSchool = 1 (Owner), and deliberately NO rows in
  t_app_school_user_branches: an owner sees every campus, and the absence of
  link rows is what says so (2.51). Enumerating an owner against each branch
  would mean a backfill on every new campus, and the day one is missed an owner
  quietly loses a campus.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ProvisionSchoolOwner
    @SchoolId           bigint,
    @UserUid            uniqueidentifier,
    @DesignationText    nvarchar(150) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = NULL;

    DECLARE @ROLE_OWNER tinyint = 1;

    IF @SchoolId IS NULL OR @UserUid IS NULL
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The school and the account are both required.';
    ELSE IF NOT EXISTS (SELECT 1 FROM dbo.t_app_schools WHERE SchoolId = @SchoolId AND Is_Deleted = 0)
        SELECT @Code = 'NOT_FOUND', @Message = N'That school was not found.';

    IF @Code IS NULL
    BEGIN
        SELECT @Id = SchoolUserId
        FROM dbo.t_app_school_users
        WHERE SchoolId = @SchoolId AND UserUid = @UserUid AND Is_Deleted = 0;

        IF @Id IS NOT NULL
            SELECT @Status = 1, @Code = 'ALREADY_PROVISIONED',
                   @Message = N'That person is already on this school.';
    END

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.t_app_school_users (SchoolId, UserUid, RoleInSchool, DesignationText)
            VALUES (@SchoolId, @UserUid, @ROLE_OWNER, @DesignationText);

            SET @Id = SCOPE_IDENTITY();

            SELECT @Status = 1, @Message = N'Owner recorded.';
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params2 nvarchar(max) = (
                SELECT @SchoolId AS schoolId, @UserUid AS userUid
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params2,
                 @ContextInfo = N'USP_ProvisionSchoolOwner';

            IF @ErrNumber IN (2601, 2627)
            BEGIN
                SELECT @Id = SchoolUserId
                FROM dbo.t_app_school_users
                WHERE SchoolId = @SchoolId AND UserUid = @UserUid AND Is_Deleted = 0;

                SELECT @Status = 1, @Code = 'ALREADY_PROVISIONED',
                       @Message = N'That person is already on this school.';
            END
            ELSE
                THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO

PRINT '    Account provisioning procedures ready.';
GO
