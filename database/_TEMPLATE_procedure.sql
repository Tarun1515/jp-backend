/*==============================================================================
  _TEMPLATE_procedure.sql — CANONICAL STORED PROCEDURE TEMPLATE

  Every write procedure is cut from this. Do not invent a different shape, and
  do not leave older procedures on an older one — a codebase with two error
  conventions is worse than either convention on its own.

  Reference only. NOT included by run_all.sql; never executes.

  Target: SQL Server 2019 (15.0). See _TEMPLATE_table.sql for the 2022+ syntax
  that must not appear anywhere in this project.

  ============================================================================
  THE CATCH ORDERING RULE — the reason this template exists
  ============================================================================

  An INSERT into the error log from INSIDE the failed transaction is rolled
  back along with everything else. The error record disappears at exactly the
  moment it was needed, and nobody notices, because the code that was supposed
  to tell you is the code that vanished.

  So every CATCH block does these four things, in this order, always:

    1. CAPTURE   the ERROR_* values into local variables.
                 They are readable ONLY inside the CATCH block that caught
                 them, and the rollback in step 2 ends that context for
                 practical purposes. Capture before you do anything else.

    2. ROLLBACK  if XACT_STATE() <> 0.
                 XACT_STATE() = -1 means the transaction is UNCOMMITTABLE:
                 rollback is the only legal action and COMMIT will fail. With
                 XACT_ABORT ON, -1 is the normal state after most errors.
                 XACT_STATE() =  1 means committable — still roll back, the
                 operation failed.
                 XACT_STATE() =  0 means there is no transaction; rolling back
                 would raise "no corresponding BEGIN TRANSACTION".

    3. LOG       call USP_LogError. The transaction is over by now, so this
                 INSERT is not inside anything that can undo it. Mask every
                 secret before it goes into @ParametersJson.

    4. RESPOND   per decision 2.21:
                   integrity failure -> THROW;  (re-raises the original error)
                   expected failure  -> fall through to the single-exit SELECT
                 An unexpected error reaching a CATCH is by definition not an
                 expected failure, so in practice step 4 is THROW.

  Get the order wrong and you get silence. That is the whole point.
==============================================================================*/

USE jp_sso;   -- <-- the owning database
GO

-- Required on every script. sqlcmd defaults QUOTED_IDENTIFIER OFF, and these
-- settings are captured into the procedure at CREATE time — a procedure
-- created with the wrong ones fails later on any filtered index.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  BLOCK A — WRITE PROCEDURE (the standard shape)
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ExampleWrite
    @SomeId         bigint,
    @SomeText       nvarchar(150),
    @PasswordHash   varbinary(64) = NULL,   -- a secret: masked before logging
    @ActionByUserId bigint        = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    /*
      Single exit. Every path sets these and falls through to one SELECT at the
      bottom. No procedure returns from the middle — a caller must be able to
      rely on exactly one result set of exactly one shape.
    */
    DECLARE @Status  int            = 0,      -- 1 success, 0 expected failure
            @Code    varchar(50)    = NULL,   -- JP.Core.Constants.ErrorCodes, NULL on success
            @Message nvarchar(400)  = NULL,   -- user-facing
            @Id      bigint         = NULL,
            @Now     datetime2      = SYSUTCDATETIME();

    /*--------------------------------------------------------------------------
      1. VALIDATE FIRST, ACT SECOND.

      Everything a caller could reasonably trigger is caught here and reported
      as Status = 0. Nothing below throws. This block opens no transaction, so
      a rejected call costs nothing.
    --------------------------------------------------------------------------*/
    IF ISNULL(@SomeText, N'') = N''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'That value is required.';
    ELSE IF NOT EXISTS (SELECT 1 FROM dbo.t_sso_users WHERE UserId = @SomeId AND Is_Deleted = 0)
        SELECT @Code = 'NOT_FOUND', @Message = N'That record was not found.';

    /*--------------------------------------------------------------------------
      2. ACT.
    --------------------------------------------------------------------------*/
    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            -- ... the actual work ...

            COMMIT TRANSACTION;

            SELECT @Status = 1, @Message = N'Done.';
        END TRY
        BEGIN CATCH
            /*==================================================================
              CAPTURE -> ROLLBACK -> LOG -> RESPOND.  In that order. Always.
            ==================================================================*/

            -- 1. CAPTURE. Readable only in here.
            DECLARE @ErrNumber    int            = ERROR_NUMBER(),
                    @ErrSeverity  int            = ERROR_SEVERITY(),
                    @ErrState     int            = ERROR_STATE(),
                    @ErrProcedure sysname        = ERROR_PROCEDURE(),
                    @ErrLine      int            = ERROR_LINE(),
                    @ErrMessage   nvarchar(4000) = ERROR_MESSAGE();

            -- 2. ROLLBACK. -1 = uncommittable, the usual state under
            --    XACT_ABORT ON; rollback is the only legal move.
            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            -- 3. LOG. Now outside any transaction, so this INSERT survives.
            --    Secrets are masked, never passed through.
            DECLARE @Params nvarchar(max) = (
                SELECT @SomeId   AS someId,
                       @SomeText AS someText,
                       CASE WHEN @PasswordHash IS NULL THEN NULL ELSE '***masked***' END AS passwordHash
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError
                 @ErrorNumber    = @ErrNumber,
                 @ErrorSeverity  = @ErrSeverity,
                 @ErrorState     = @ErrState,
                 @ErrorProcedure = @ErrProcedure,
                 @ErrorLine      = @ErrLine,
                 @ErrorMessage   = @ErrMessage,
                 @ParametersJson = @Params,
                 @ContextInfo    = N'USP_ExampleWrite',
                 @CreatedBy      = @ActionByUserId;

            -- 4. RESPOND. THROW re-raises the ORIGINAL error even though other
            --    statements have run since — number, message and severity are
            --    preserved, which a RAISERROR rewrite would lose.
            THROW;
        END CATCH
    END

    /*--------------------------------------------------------------------------
      3. SINGLE EXIT.
    --------------------------------------------------------------------------*/
    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO


/*==============================================================================
  BLOCK B — READ PROCEDURE

  No transaction, so no CATCH: there is nothing to roll back and nothing a
  caller could do about a failure here anyway. Let it propagate; BaseRepository
  wraps it with the procedure name.

  Returns rows directly. An empty result set is the "not found" answer — the
  repository turns that into NotFoundException where that is the right response
  (decision 2.21).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ExampleGet
    @UserUid uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    SELECT u.UserId, u.UserUid, u.Email
    FROM dbo.t_sso_users u
    WHERE u.UserUid = @UserUid
      AND u.Is_Deleted = 0;
END
GO


/*==============================================================================
  BLOCK C — LIST PROCEDURE

  Two result sets: the page, then the total before paging.

  Optional filters use (@Param IS NULL OR Col = @Param) with OPTION (RECOMPILE)
  so the optimiser can discard the unused branches and pick a real index.
  RECOMPILE belongs on list procedures ONLY — never on the login path, where
  the cost is paid on every single sign-in.

  Date filters take IST calendar dates and convert to a UTC half-open range
  ONCE, into variables (decision 2.28). Never CAST(col AS date) on a stored
  UTC column: it gives the wrong day AND kills the index seek.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_ExampleList
    @StatusId   int  = NULL,
    @FromDate   date = NULL,          -- IST calendar date
    @ToDate     date = NULL,          -- IST calendar date, inclusive
    @PageNumber int  = 1,
    @PageSize   int  = 20
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

    SELECT u.UserUid, u.Email, u.StatusId, u.CreatedOn
    FROM dbo.t_sso_users u
    WHERE u.Is_Deleted = 0
      AND (@StatusId IS NULL OR u.StatusId = @StatusId)
      AND (@FromUtc  IS NULL OR u.CreatedOn >= @FromUtc)
      AND (@ToUtc    IS NULL OR u.CreatedOn <  @ToUtc)
    ORDER BY u.CreatedOn DESC, u.UserId DESC
    OFFSET (@PageNumber - 1) * @PageSize ROWS
    FETCH NEXT @PageSize ROWS ONLY
    OPTION (RECOMPILE);

    SELECT COUNT_BIG(*) AS TotalRecords
    FROM dbo.t_sso_users u
    WHERE u.Is_Deleted = 0
      AND (@StatusId IS NULL OR u.StatusId = @StatusId)
      AND (@FromUtc  IS NULL OR u.CreatedOn >= @FromUtc)
      AND (@ToUtc    IS NULL OR u.CreatedOn <  @ToUtc)
    OPTION (RECOMPILE);
END
GO


/*==============================================================================
  WHAT NEVER GOES IN ParametersJson
==============================================================================

  PasswordHash · PasswordSalt · TokenHash · OtpHash · any plaintext secret

  Mask with a literal:

      CASE WHEN @TokenHash IS NULL THEN NULL ELSE '***masked***' END AS tokenHash

  Recording that the parameter was PRESENT is useful; recording its VALUE turns
  the error log into the longest-lived, most widely-read copy of the secret in
  the system. Reproduction needs the shape of the call, not the credentials.
==============================================================================*/
