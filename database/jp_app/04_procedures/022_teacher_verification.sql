/*
================================================================================
  PHASE 6C-2-0 — USP_SetTeacherVerified                    (G37)

  The badge, its stamp, and the notification that tells the teacher — in one
  transaction, because all three live in jp_app.

--------------------------------------------------------------------------------
  🔴 WHAT THIS REPLACES
--------------------------------------------------------------------------------
  ApprovalOrchestrationService.RunTeacherVerification was a stub that returned
  a FAILED outcome saying the work "requires t_app_teachers, which is Phase 3".
  Phase 3 shipped four phases ago. Nothing set t_app_teachers.IsVerified, the
  four verified teachers in the database were seed rows, and no error was ever
  raised because that branch was written to report a failure in the first place.

--------------------------------------------------------------------------------
  🔴 A DECLINE DOES NOT REVOKE A BADGE, AND THAT IS A DECISION
--------------------------------------------------------------------------------
  @Approved = 0 writes the notification and leaves IsVerified exactly as it was.

  The alternative — treating @Approved as the value to store — is one character
  shorter and wrong: a teacher who is already verified, submits again, and is
  declined would silently lose a badge they earned on a different submission.
  Revoking verification is a real action with its own consequences (they vanish
  from every VerifiedOnly search), and it should be something an admin DOES,
  not a side effect of declining a form.

  ⚠️ So the parameter is named @Approved, not @IsVerified. A boolean that
  doubles as a badge value is how that bug gets written.

--------------------------------------------------------------------------------
  ⚠️ IDEMPOTENT, BECAUSE THE RETRY PATH IS REAL
--------------------------------------------------------------------------------
  USP_RetryOrchestration exists precisely so a failed cross-database handoff can
  be run again (2.48). So approving twice must not stamp twice or notify twice:
  the UPDATE is guarded on IsVerified = 0, and the notification only follows a
  row that actually changed.

  🔴 Which means the second call reports success with Changed = 0. "Already
  verified" is the state the caller wanted; reporting a failure would send an
  admin chasing a badge that is already there.

--------------------------------------------------------------------------------
  🔒 THE NOTIFICATION IS IN THIS TRANSACTION, AND THAT IS NOT A 2.48 BREACH
--------------------------------------------------------------------------------
  The approval decision is in jp_mdm and is already committed before this runs —
  that handoff is the API layer's problem and ApprovalService reports it through
  `orchestrationCompleted` (2.48). But the badge and the notification are both
  jp_app rows, so there is no reason for them to be able to disagree. Same
  argument as 2.76's: where an atomic guarantee is free, taking it is the
  difference between "the teacher was told" and "the teacher was probably told".
================================================================================
*/
USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE dbo.USP_SetTeacherVerified
    /*
      🔒 The TeacherUid, because that is what the approval request carries as
      its EntityUid — "the thing being approved" (025) — and because a bigint
      TeacherId has no business on this boundary (2.39).
    */
    @TeacherUid       uniqueidentifier,
    @Approved         bit,
    @ActionByUserId   bigint = NULL,
    @Remarks          nvarchar(1000) = NULL
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Now datetime2(3) = SYSUTCDATETIME(),
            @TeacherId bigint, @UserUid uniqueidentifier, @WasVerified tinyint,
            @Changed int = 0;

    SELECT @TeacherId   = t.TeacherId,
           @UserUid     = t.UserUid,
           @WasVerified = t.IsVerified
    FROM dbo.t_app_teachers t
    WHERE t.TeacherUid = @TeacherUid
      AND t.Is_Deleted = 0;

    /*
      🔴 NOT_FOUND RATHER THAN A SILENT RETURN.

      The stub this replaces reported a failure every time, and nobody noticed
      for four phases. A teacher uid that resolves to nothing is a real problem
      — a deleted profile, or an approval request carrying an EntityUid that was
      never a teacher — and the caller has to be able to say so on a screen.
    */
    IF @TeacherId IS NULL
    BEGIN
        SELECT 0 AS [Status], 'NOT_FOUND' AS Code,
               N'That teacher profile was not found.' AS [Message], NULL AS Id,
               0 AS Changed;

        RETURN;
    END

    BEGIN TRY
        BEGIN TRANSACTION;

        IF @Approved = 1
        BEGIN
            UPDATE dbo.t_app_teachers
               SET IsVerified       = 1,
                   VerifiedOn       = @Now,
                   VerifiedByUserId = @ActionByUserId,
                   RowVersion       = RowVersion + 1,
                   ModifiedOn       = @Now,
                   ModifiedBy       = @ActionByUserId
            WHERE TeacherId  = @TeacherId
              AND IsVerified = 0          -- the idempotent half
              AND Is_Deleted = 0;

            SET @Changed = @@ROWCOUNT;
        END

        /*
          ⚠️ THE NOTIFICATION FOLLOWS THE DECISION, NOT THE ROW CHANGE.

          A decline changes nothing and still has to be said — it is the only
          thing the teacher will ever see about it. An approval that changed
          nothing (already verified) is the one case that stays silent, because
          telling somebody twice that they were verified is noise about an event
          that happened once.
        */
        IF @Approved = 0 OR @Changed = 1
        BEGIN
            DECLARE @TypeId int = CASE WHEN @Approved = 1 THEN 13 ELSE 14 END;

            DECLARE @Title nvarchar(200) =
                (SELECT Name FROM dbo.m_app_notification_type WHERE NotificationTypeId = @TypeId);

            /*
              🔒 @Remarks IS NOT IN THE BODY, and this is the same rule the
              offer and the rejection follow (021): an admin's note on a
              verification is written for the audit trail and for other admins.
              "Document is illegible, looks edited" is not a sentence the
              product chose to say to the person it is about.

              ⚠️ The body is therefore fixed text from the TYPE, not composed
              here — so there is no parameter through which a note could ever
              reach it.
            */
            DECLARE @Body nvarchar(1000) =
                (SELECT Description FROM dbo.m_app_notification_type WHERE NotificationTypeId = @TypeId);

            EXEC dbo.USP_CreateNotification
                 @RecipientUserUid   = @UserUid,
                 @NotificationTypeId = @TypeId,
                 @Title              = @Title,
                 @Body               = @Body,
                 @ActionUrl          = N'/profile',
                 @RefEntityTypeId    = NULL,
                 @RefEntityUid       = NULL;
        END

        COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        DECLARE @E int = ERROR_NUMBER(), @S int = ERROR_SEVERITY(), @T int = ERROR_STATE(),
                @P sysname = ERROR_PROCEDURE(), @L int = ERROR_LINE(),
                @M nvarchar(4000) = ERROR_MESSAGE();

        IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

        DECLARE @Params nvarchar(max) = (
            SELECT @TeacherUid AS teacherUid, @Approved AS approved
            FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

        EXEC dbo.USP_LogError @ErrorNumber = @E, @ErrorSeverity = @S, @ErrorState = @T,
             @ErrorProcedure = @P, @ErrorLine = @L, @ErrorMessage = @M,
             @ParametersJson = @Params, @ContextInfo = N'USP_SetTeacherVerified',
             @CreatedBy = @ActionByUserId;

        THROW;
    END CATCH

    /*
      ⚠️ Changed is returned so the caller can tell "I verified them" from
      "they were already verified" — the retry path needs that distinction and
      a bare success hides it.
    */
    SELECT 1 AS [Status], NULL AS Code,
           CASE WHEN @Approved = 0 THEN N'The teacher has been told the decision.'
                WHEN @Changed = 1  THEN N'The teacher is now verified.'
                ELSE N'That teacher was already verified.' END AS [Message],
           @TeacherId AS Id,
           @Changed AS Changed;
END
GO

PRINT '  teacher verification procedure ready';
GO
