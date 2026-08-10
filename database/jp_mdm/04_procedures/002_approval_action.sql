/*==============================================================================
  jp_mdm — 04_procedures / 002_approval_action.sql

  USP_ProcessApprovalAction — the core of the engine.

  Approve / Reject / RequestResubmit, with level advancement, permission
  validation, optimistic concurrency and an append-only trail.

  ---------------------------------------------------------------------------
  🔴 WHAT THIS PROCEDURE DOES NOT DO
  ---------------------------------------------------------------------------
  It does NOT write to jp_sso or jp_app. When a request completes, the school
  still has to be created in jp_app and its user activated in jp_sso — and both
  are cross-database writes, which decision 2.2 puts in the API layer.

  So it returns IsCompleted alongside the new status. That flag is the API's
  signal that it now owns the rest of the work. Doing it here would need a
  distributed transaction across three databases, which is exactly the coupling
  decision 2.2 exists to prevent.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE dbo.USP_ProcessApprovalAction
    @RequestId          bigint,
    @ActionTypeId       int,            -- 1 Approve · 2 Reject · 3 RequestResubmit
    @ActionByUserId     bigint,
    @RowVersion         int,            -- required: this is the concurrency check
    @Remarks            nvarchar(1000) = NULL,

    /*
      Why, as data. Required by the API for a reject, and deliberately dropped
      for an approve — nothing was rejected, so there is no reason to record.

      The remarks say it in words for the school to read; this says it in a way
      somebody can count.
    */
    @RejectionReasonId  int            = NULL,

    @IpAddress          varchar(45)    = NULL,

    /*
      The caller's roles, comma-separated, resolved from the JWT by the API.
      Passed in rather than read here: roles live in jp_sso and this database
      cannot join to them (decision 2.2).

      NULL means "skip the level-permission check" — used by the API only where
      it has already authorised the action itself.
    */
    @ActorRoleIds       varchar(200)   = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = @RequestId,
            @Now datetime2 = SYSUTCDATETIME();

    -- m_mdm_approval_status
    DECLARE @ST_PENDING int = 1, @ST_REJECTED int = 2,
            @ST_APPROVED int = 3, @ST_RESUBMIT int = 4;
    -- m_mdm_action_types
    DECLARE @AC_APPROVE int = 1, @AC_REJECT int = 2, @AC_REQUEST_RESUBMIT int = 3;

    DECLARE @CurrentStatus  int = NULL,
            @CurrentLevel   tinyint = NULL,
            @CurrentRV      int = NULL,
            @RequestTypeId  int = NULL,
            @OrganizationUid uniqueidentifier = NULL;

    SELECT @CurrentStatus = StatusId, @CurrentLevel = CurrentApprovalLevel,
           @CurrentRV = RowVersion, @RequestTypeId = RequestTypeId,
           @OrganizationUid = OrganizationUid
    FROM dbo.t_mdm_approval_requests
    WHERE RequestId = @RequestId AND Is_Deleted = 0;

    /*--------------------------------------------------------------------------
      1. VALIDATE.
    --------------------------------------------------------------------------*/
    IF @CurrentStatus IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That request was not found.';

    ELSE IF @ActionTypeId NOT IN (1, 2, 3)
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'That is not an action this request accepts.';

    /*
      Legal transitions, as a CASE (decision 2.7). Only a Pending request can be
      acted on: an Approved or Rejected one is finished, and a
      ResubmitRequired one is waiting on the applicant, not on an admin.
    */
    ELSE IF @CurrentStatus <> @ST_PENDING
        SELECT @Code = 'INVALID_STATUS',
               @Message = CASE @CurrentStatus
                            WHEN @ST_APPROVED THEN N'This request has already been approved.'
                            WHEN @ST_REJECTED THEN N'This request has already been rejected.'
                            WHEN @ST_RESUBMIT THEN N'This request is waiting for the applicant to resubmit.'
                            ELSE N'This request cannot be actioned in its current state.'
                          END;

    /*
      🔴 OPTIMISTIC CONCURRENCY.

      Two admins open the same request and both press Approve. Without this the
      second silently overwrites the first, and the trail shows two approvals
      for one level. The second must be TOLD someone else acted.
    */
    ELSE IF @RowVersion IS NULL OR @RowVersion <> @CurrentRV
        SELECT @Code = 'CONCURRENCY_CONFLICT',
               @Message = N'Someone else has already actioned this request. Reload to see the current state.';

    /*
      The actor must hold the role configured for THIS level. Checked against
      the organisation-specific row if one exists, otherwise the platform
      default (OrganizationUid IS NULL).
    */
    ELSE IF @ActorRoleIds IS NOT NULL
        AND NOT EXISTS (
            SELECT 1
            FROM dbo.t_mdm_request_levels l
            WHERE l.RequestTypeId = @RequestTypeId
              AND l.LevelNumber   = @CurrentLevel
              AND l.Is_Deleted    = 0
              AND l.Is_Active     = 1
              AND (l.OrganizationUid = @OrganizationUid OR l.OrganizationUid IS NULL)
              AND EXISTS (SELECT 1 FROM STRING_SPLIT(@ActorRoleIds, ',') r
                          WHERE TRY_CAST(LTRIM(RTRIM(r.value)) AS int) = l.RoleId))
        SELECT @Code = 'FORBIDDEN',
               @Message = N'You do not have permission to action this request at this level.';

    /*--------------------------------------------------------------------------
      2. ACT.
    --------------------------------------------------------------------------*/
    DECLARE @NewStatus int = NULL, @NewLevel tinyint = NULL, @IsCompleted bit = 0;

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            IF @ActionTypeId = @AC_REJECT
            BEGIN
                SELECT @NewStatus = @ST_REJECTED, @NewLevel = @CurrentLevel, @IsCompleted = 1;
            END
            ELSE IF @ActionTypeId = @AC_REQUEST_RESUBMIT
            BEGIN
                -- Back to the applicant. Not completed — the request lives on.
                SELECT @NewStatus = @ST_RESUBMIT, @NewLevel = @CurrentLevel, @IsCompleted = 0;
            END
            ELSE  -- approve
            BEGIN
                /*
                  Is this the final level? Read from configuration, never
                  assumed. MVP seeds one level per type, so level 1 is usually
                  final — but the engine must not encode that, or Phase 6's
                  two-level offer approval becomes a rewrite instead of a row.
                */
                DECLARE @IsFinal tinyint = NULL;

                SELECT TOP (1) @IsFinal = l.IsFinalLevel
                FROM dbo.t_mdm_request_levels l
                WHERE l.RequestTypeId = @RequestTypeId
                  AND l.LevelNumber   = @CurrentLevel
                  AND l.Is_Deleted    = 0
                  AND l.Is_Active     = 1
                  AND (l.OrganizationUid = @OrganizationUid OR l.OrganizationUid IS NULL)
                ORDER BY CASE WHEN l.OrganizationUid IS NULL THEN 1 ELSE 0 END;  -- org override wins

                -- No configured level at all: treat this one as final rather
                -- than advancing into a level nobody can approve.
                IF @IsFinal IS NULL SET @IsFinal = 1;

                IF @IsFinal = 1
                    SELECT @NewStatus = @ST_APPROVED, @NewLevel = @CurrentLevel, @IsCompleted = 1;
                ELSE
                    SELECT @NewStatus = @ST_PENDING, @NewLevel = @CurrentLevel + 1, @IsCompleted = 0;
            END

            /*
              The RowVersion is re-checked in the WHERE clause, not just in the
              validation above. Between the two, another session could have
              committed — the read was outside this transaction. This makes the
              check and the write atomic.
            */
            UPDATE dbo.t_mdm_approval_requests
               SET StatusId             = @NewStatus,
                   CurrentApprovalLevel = @NewLevel,
                   ApproverUserId       = @ActionByUserId,
                   CompletedOn          = CASE WHEN @IsCompleted = 1 THEN @Now ELSE NULL END,
                   ModifiedOn           = @Now,
                   ModifiedBy           = @ActionByUserId,
                   RowVersion           = RowVersion + 1
            WHERE RequestId  = @RequestId
              AND RowVersion = @RowVersion      -- <- the atomic half of the check
              AND StatusId   = @ST_PENDING
              AND Is_Deleted = 0;

            IF @@ROWCOUNT = 0
                THROW 50023, 'The request was actioned by someone else a moment ago.', 1;

            -- Append to the trail. Never an UPDATE — this is the evidence.
            INSERT INTO dbo.t_mdm_request_approvals
                (RequestId, LevelNumber, ActionTypeId, ActionByUserId, RejectionReasonId,
                 Remarks, ActionOn, IpAddress, CreatedBy)
            VALUES
                (@RequestId, @CurrentLevel, @ActionTypeId, @ActionByUserId,
                 -- Only a rejection carries a reason. An approve that arrived with
                 -- one, stored anyway, would read later as a rejection.
                 CASE WHEN @ActionTypeId = @AC_APPROVE THEN NULL ELSE @RejectionReasonId END,
                 @Remarks, @Now, @IpAddress, @ActionByUserId);

            COMMIT TRANSACTION;

            SELECT @Status = 1,
                   @Message = CASE @NewStatus
                                WHEN @ST_APPROVED THEN N'Request approved.'
                                WHEN @ST_REJECTED THEN N'Request rejected.'
                                WHEN @ST_RESUBMIT THEN N'Resubmission requested.'
                                ELSE N'Approved at this level and sent to the next.'
                              END;
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @RequestId AS requestId, @ActionTypeId AS actionTypeId,
                       @ActionByUserId AS actionByUserId, @RowVersion AS rowVersion
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_ProcessApprovalAction', @CreatedBy = @ActionByUserId;

            -- 50023 is the lost race, not a fault: answer it as a conflict so
            -- the caller can reload, rather than as a 500.
            IF @ErrNumber = 50023
                SELECT @Status = 0, @Code = 'CONCURRENCY_CONFLICT',
                       @Message = N'Someone else has already actioned this request. Reload to see the current state.';
            ELSE
                THROW;
        END CATCH
    END

    /*--------------------------------------------------------------------------
      3. SINGLE EXIT.

      IsCompleted is the API's cue that the cross-database work is now its job:
      create the school in jp_app, activate the user in jp_sso.
    --------------------------------------------------------------------------*/
    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id,
           @NewStatus AS NewStatusId, ISNULL(@IsCompleted, 0) AS IsCompleted,
           @NewLevel AS CurrentApprovalLevel;
END
GO

PRINT '    USP_ProcessApprovalAction ready.';
GO
