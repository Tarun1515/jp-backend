/*==============================================================================
  jp_mdm — 04_procedures / 000_USP_LogError.sql

  Writes one row to t_mdm_error_log.

  jp_mdm's OWN copy. Not a call into jp_sso: each database stays independently
  deployable (decision 2.1), and a cross-database call from inside a CATCH is
  the last thing that should be able to fail.

  Created BEFORE every other procedure, because they all call it.

  ---------------------------------------------------------------------------
  CALL THIS **AFTER** THE ROLLBACK, NEVER BEFORE
  ---------------------------------------------------------------------------
  Called while the failed transaction is still open, this INSERT is rolled back
  with everything else and the error is lost — silently, and precisely when it
  mattered. The mandatory CATCH ordering is in decision 2.31 and in
  database/_TEMPLATE_procedure.sql:

      1. capture the ERROR_* values into locals
      2. ROLLBACK
      3. call USP_LogError
      4. THROW, or return the Status/Code/Message/Id result set

  ---------------------------------------------------------------------------
  THIS PROCEDURE MUST NEVER THROW
  ---------------------------------------------------------------------------
  It runs inside somebody else's CATCH block. If logging raised its own error
  it would replace the real one, and the caller would report a logging failure
  instead of the fault that actually happened. Its INSERT is therefore wrapped
  in its own TRY/CATCH which swallows everything.

  Failing to log is bad. Losing the original error is worse.
==============================================================================*/

USE jp_mdm;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

CREATE OR ALTER PROCEDURE dbo.USP_LogError
    /*
      The ERROR_* values are passed IN rather than read here, because they are
      only readable inside the CATCH block that caught them — and by the time
      this procedure runs, the caller has already performed its ROLLBACK.
      Reading them here would return nothing.
    */
    @ErrorNumber        int             = NULL,
    @ErrorSeverity      int             = NULL,
    @ErrorState         int             = NULL,
    @ErrorProcedure     sysname         = NULL,
    @ErrorLine          int             = NULL,
    @ErrorMessage       nvarchar(4000)  = NULL,

    -- Masked input parameters. NEVER a hash, salt, token or OTP.
    @ParametersJson     nvarchar(max)   = NULL,
    @ContextInfo        nvarchar(500)   = NULL,

    @CreatedBy          bigint          = NULL,
    @ErrorLogId         bigint          = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;

    -- Deliberately NOT XACT_ABORT ON: this runs inside a CATCH, and an
    -- unexpected abort here would take the caller's error handling with it.

    BEGIN TRY
        -- The session facts are read here because they are session-scoped and
        -- survive any rollback, so there is no reason to make callers pass them.
        INSERT INTO dbo.t_mdm_error_log
            (ErrorNumber, ErrorSeverity, ErrorState, ErrorProcedure, ErrorLine, ErrorMessage,
             UserName, HostName, AppName, ParametersJson, ContextInfo, OccurredOn, CreatedBy)
        VALUES
            (ISNULL(@ErrorNumber, -1),
             @ErrorSeverity,
             @ErrorState,
             @ErrorProcedure,
             @ErrorLine,
             ISNULL(@ErrorMessage, N'(no message captured)'),
             SUSER_SNAME(),
             HOST_NAME(),
             APP_NAME(),
             @ParametersJson,
             @ContextInfo,
             SYSUTCDATETIME(),
             @CreatedBy);

        SET @ErrorLogId = SCOPE_IDENTITY();
    END TRY
    BEGIN CATCH
        /*
          Swallowed on purpose. Nothing is rethrown and nothing is returned as
          a failure, because this procedure's own problems must never surface
          in place of the caller's.

          The one thing worth doing is leaving a trace somewhere that is not
          this table — the SQL Server error log, which no transaction can roll
          back. Severity 10 is informational, so it does not become an error in
          its own right.
        */
        DECLARE @Fallback nvarchar(2048) =
            N'USP_LogError failed to record an error. Original error '
            + ISNULL(CAST(@ErrorNumber AS nvarchar(12)), N'?')
            + N' in ' + ISNULL(@ErrorProcedure, N'(ad-hoc)')
            + N': ' + ISNULL(@ErrorMessage, N'(none)')
            + N' -- logging failure: ' + ERROR_MESSAGE();

        RAISERROR(@Fallback, 10, 1) WITH LOG;

        SET @ErrorLogId = NULL;
    END CATCH
END
GO

PRINT '    USP_LogError ready.';
GO
