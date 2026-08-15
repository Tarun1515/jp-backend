/*==============================================================================
  jp_app — 04_procedures / 009_teacher_experiences_documents.sql

  USP_SaveTeacherExperience     insert, or update by id — NOT a set sync
  USP_DeleteTeacherExperience   soft delete
  USP_SaveTeacherDocument       add
  USP_DeleteTeacherDocument     soft delete

  ---------------------------------------------------------------------------
  🔴 EXPERIENCES ARE ENTITIES, NOT A BRIDGE
  ---------------------------------------------------------------------------
  Each row is a thing a teacher writes, edits and deletes on its own. Phase 3A
  deliberately gave the table NO unique index, because a part-time subject
  teacher who also ran the sports programme is two legitimate overlapping rows
  at one school starting the same month (2.51).

  So there is nothing to diff against. A set sync would have to decide what
  "the same experience" means, and the honest answer is that only the teacher
  knows — which is what an Id is for.

  ⚠️ Every one of these recalculates the profile afterwards, because
  TotalExperienceMonths is DERIVED from these rows (2.53). Phase 3B found
  hand-written totals disagreeing with their own evidence by up to thirteen
  months; a total that contradicts what it is computed from surfaces in a search
  filter and cannot be explained to the person it belongs to.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO


/*==============================================================================
  USP_SaveTeacherExperience

  @Id NULL inserts; a value updates that row after checking it belongs to the
  caller.

  🔴 THE OWNERSHIP CHECK IS ON THE ROW, NOT ON THE REQUEST. The teacher is
  resolved from the token and the row's TeacherId must match it — so an id
  belonging to somebody else resolves to "not found", exactly as a nonexistent
  one does.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveTeacherExperience
    @UserUid        uniqueidentifier,
    @Id             bigint         = NULL,     -- NULL = insert
    @SchoolName     nvarchar(200),
    @DesignationId  int            = NULL,
    @SubjectId      int            = NULL,
    @FromDate       date,
    @ToDate         date           = NULL,
    @IsCurrent      tinyint        = 0
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Now datetime2 = SYSUTCDATETIME();

    DECLARE @TeacherId bigint = dbo.fn_TeacherIdForUser(@UserUid);
    DECLARE @Today date = CAST(@Now AS date);

    SET @IsCurrent = ISNULL(@IsCurrent, 0);

    -- A current role has no end date; a finished one has to have one. Checked
    -- here as well as by CK_..._CurrentHasNoToDate so the caller gets a sentence
    -- rather than a constraint name.
    IF @IsCurrent = 1 SET @ToDate = NULL;

    IF @TeacherId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That profile was not found.';
    ELSE IF ISNULL(@SchoolName, N'') = N''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'Which school was this?';
    ELSE IF @FromDate IS NULL
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'When did you start?';
    ELSE IF @FromDate > @Today
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'That start date is in the future.';
    ELSE IF @IsCurrent = 0 AND @ToDate IS NULL
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'When did you leave? Tick "I work here now" if you have not.';
    ELSE IF @ToDate IS NOT NULL AND @ToDate < @FromDate
        SELECT @Code = 'VALIDATION_FAILED',
               @Message = N'That role ended before it started — check the dates.';
    ELSE IF @ToDate IS NOT NULL AND @ToDate > @Today
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'That end date is in the future.';

    /*
      🔴 The row must be the caller's own.

      Not "does this id exist" — does it belong to the teacher the TOKEN
      resolved to. An id from another teacher's profile answers NOT_FOUND, the
      same as one that never existed, because confirming it exists is itself a
      small disclosure.
    */
    ELSE IF @Id IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM dbo.t_app_teacher_experiences
                        WHERE Id = @Id AND TeacherId = @TeacherId AND Is_Deleted = 0)
        SELECT @Code = 'NOT_FOUND', @Message = N'That entry was not found.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            IF @Id IS NULL
            BEGIN
                INSERT INTO dbo.t_app_teacher_experiences
                    (TeacherId, SchoolName, DesignationId, SubjectId, FromDate, ToDate, IsCurrent)
                VALUES
                    (@TeacherId, @SchoolName, @DesignationId, @SubjectId, @FromDate, @ToDate, @IsCurrent);

                SET @Id = SCOPE_IDENTITY();
                SELECT @Status = 1, @Message = N'Experience added.';
            END
            ELSE
            BEGIN
                UPDATE dbo.t_app_teacher_experiences
                   SET SchoolName    = @SchoolName,
                       DesignationId = @DesignationId,
                       SubjectId     = @SubjectId,
                       FromDate      = @FromDate,
                       ToDate        = @ToDate,
                       IsCurrent     = @IsCurrent,
                       ModifiedOn    = @Now
                 WHERE Id = @Id AND TeacherId = @TeacherId AND Is_Deleted = 0;

                SELECT @Status = 1, @Message = N'Experience updated.';
            END

            -- 🔴 The total is derived from these rows, so it moves whenever
            -- they do — including on an edit that only changed a date.
            EXEC dbo.USP_RecalculateTeacherProfile @TeacherId = @TeacherId;
        END TRY
        BEGIN CATCH
            DECLARE @E int = ERROR_NUMBER(), @S int = ERROR_SEVERITY(), @T int = ERROR_STATE(),
                    @P sysname = ERROR_PROCEDURE(), @L int = ERROR_LINE(), @M nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @TeacherId AS teacherId, @Id AS id, @SchoolName AS schoolName
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @E, @ErrorSeverity = @S, @ErrorState = @T,
                 @ErrorProcedure = @P, @ErrorLine = @L, @ErrorMessage = @M,
                 @ParametersJson = @Params, @ContextInfo = N'USP_SaveTeacherExperience';

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO


CREATE OR ALTER PROCEDURE dbo.USP_DeleteTeacherExperience
    @UserUid uniqueidentifier,
    @Id      bigint
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL;
    DECLARE @TeacherId bigint = dbo.fn_TeacherIdForUser(@UserUid);

    IF @TeacherId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That profile was not found.';
    ELSE IF NOT EXISTS (SELECT 1 FROM dbo.t_app_teacher_experiences
                        WHERE Id = @Id AND TeacherId = @TeacherId AND Is_Deleted = 0)
        SELECT @Code = 'NOT_FOUND', @Message = N'That entry was not found.';

    IF @Code IS NULL
    BEGIN
        UPDATE dbo.t_app_teacher_experiences
           SET Is_Deleted = 1, ModifiedOn = SYSUTCDATETIME()
         WHERE Id = @Id AND TeacherId = @TeacherId AND Is_Deleted = 0;

        EXEC dbo.USP_RecalculateTeacherProfile @TeacherId = @TeacherId;

        SELECT @Status = 1, @Message = N'Experience removed.';
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO


/*==============================================================================
  USP_SaveTeacherDocument

  ⚠️ 3A deliberately put NO unique index on (TeacherId, DocumentTypeId): two
  degree certificates or two experience letters are legitimate, and constraining
  the pair would force one to be soft-deleted to make room for the other — data
  loss dressed as a data rule (2.51).

  So this only ever ADDS. Replacing is delete-then-add, which the teacher does
  explicitly.

  🔴 NO IDENTITY NUMBER IS STORED, EVER (2.50). The teacher chooses which
  government photo ID they are uploading and uploads the DOCUMENT. There is no
  AadhaarNumber column and there must never be one.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveTeacherDocument
    @UserUid        uniqueidentifier,
    @DocumentTypeId int,
    @FilePath       nvarchar(500),
    @FileName       nvarchar(255),
    @FileSizeKb     int,
    @MimeType       varchar(100)
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = NULL;

    DECLARE @TeacherId bigint = dbo.fn_TeacherIdForUser(@UserUid);

    IF @TeacherId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That profile was not found.';
    ELSE IF ISNULL(@FilePath, N'') = N'' OR ISNULL(@FileName, N'') = N''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The file is required.';
    ELSE IF ISNULL(@FileSizeKb, 0) <= 0
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'That file appears to be empty.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            INSERT INTO dbo.t_app_teacher_documents
                (TeacherId, DocumentTypeId, FilePath, FileName, FileSizeKb, MimeType)
            VALUES
                (@TeacherId, @DocumentTypeId, @FilePath, @FileName, @FileSizeKb, @MimeType);

            SET @Id = SCOPE_IDENTITY();
            SELECT @Status = 1, @Message = N'Document uploaded.';
        END TRY
        BEGIN CATCH
            DECLARE @E int = ERROR_NUMBER(), @S int = ERROR_SEVERITY(), @T int = ERROR_STATE(),
                    @P sysname = ERROR_PROCEDURE(), @L int = ERROR_LINE(), @M nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            EXEC dbo.USP_LogError @ErrorNumber = @E, @ErrorSeverity = @S, @ErrorState = @T,
                 @ErrorProcedure = @P, @ErrorLine = @L, @ErrorMessage = @M,
                 @ContextInfo = N'USP_SaveTeacherDocument';

            /*
              ⚠️ The only unique index here is on FilePath, and storage names are
              generated GUIDs — so a duplicate means the same upload was recorded
              twice, which is the double-clicked-save case.

              🔴 It is verified before being claimed. Phase 3C found
              USP_ProvisionSchoolFromApproval asserting ALREADY_PROVISIONED for
              any 2601 without checking which constraint fired, and reporting
              success for a school that had been rolled back. Same shape, so the
              same discipline: look for the row, and only claim it if it answers.
            */
            IF @E IN (2601, 2627)
            BEGIN
                SELECT @Id = DocumentId FROM dbo.t_app_teacher_documents
                WHERE TeacherId = @TeacherId AND FilePath = @FilePath AND Is_Deleted = 0;

                IF @Id IS NOT NULL
                    SELECT @Status = 1, @Code = 'ALREADY_UPLOADED',
                           @Message = N'That file was already uploaded.';
                ELSE
                    SELECT @Status = 0, @Code = 'DUPLICATE_RECORD',
                           @Message = N'The document could not be saved. This has been logged.';
            END
            ELSE
                THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO


CREATE OR ALTER PROCEDURE dbo.USP_DeleteTeacherDocument
    @UserUid    uniqueidentifier,
    @DocumentId bigint
AS
BEGIN
    SET NOCOUNT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL, @Message nvarchar(400) = NULL;
    DECLARE @TeacherId bigint = dbo.fn_TeacherIdForUser(@UserUid);

    IF @TeacherId IS NULL
        SELECT @Code = 'NOT_FOUND', @Message = N'That profile was not found.';
    ELSE IF NOT EXISTS (SELECT 1 FROM dbo.t_app_teacher_documents
                        WHERE DocumentId = @DocumentId AND TeacherId = @TeacherId AND Is_Deleted = 0)
        SELECT @Code = 'NOT_FOUND', @Message = N'That document was not found.';

    IF @Code IS NULL
    BEGIN
        UPDATE dbo.t_app_teacher_documents
           SET Is_Deleted = 1, ModifiedOn = SYSUTCDATETIME()
         WHERE DocumentId = @DocumentId AND TeacherId = @TeacherId AND Is_Deleted = 0;

        SELECT @Status = 1, @Message = N'Document removed.';
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @DocumentId AS Id;
END
GO


/*==============================================================================
  USP_GetTeacherPhotoPath      the teacher's own photo
  USP_GetTeacherResumePath     the teacher's own resume
  USP_GetTeacherDocumentPath   one of the teacher's own documents

  ---------------------------------------------------------------------------
  🔴 THE TEACHER'S OWN, AND NOBODY ELSE'S. NOT EVEN A LITTLE.
  ---------------------------------------------------------------------------
  Every one of these resolves the teacher from @UserUid through
  fn_TeacherIdForUser and matches the row against THAT id. There is no parameter
  for whose file it is, so "somebody else's" cannot be expressed — the same shape
  3D gave every teacher write, verified against sys.parameters.

  ⚠️ THE RESUME ESPECIALLY. A resume carries an email and a mobile number in its
  first three lines, so it IS a contact detail (2.56, LOCKED). A school reaches a
  teacher's resume through GET /api/teachers/{uid}/contact after that teacher has
  applied or accepted an invite — never through here. A school user has no
  t_app_teachers row at all, so fn_TeacherIdForUser gives NULL and this returns
  nothing.

  ---------------------------------------------------------------------------
  WHY THEY EXIST — added in 3H, the same gap 3F found on the school side
  ---------------------------------------------------------------------------
  Uploads live under App_Data, which is not served statically and must never be:
  that root holds every resume and every registration document in the system. So
  the bytes are streamed by the API, and until something tried to RENDER a
  teacher's photo, nothing had noticed there was no way to fetch one.

  Target: SQL Server 2019 (15.0).
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_GetTeacherPhotoPath
    @UserUid uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    SELECT t.PhotoPath
    FROM dbo.t_app_teachers t
    WHERE t.TeacherId = dbo.fn_TeacherIdForUser(@UserUid)
      AND t.PhotoPath IS NOT NULL;
END
GO


CREATE OR ALTER PROCEDURE dbo.USP_GetTeacherResumePath
    @UserUid uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    SELECT t.ResumePath
    FROM dbo.t_app_teachers t
    WHERE t.TeacherId = dbo.fn_TeacherIdForUser(@UserUid)
      AND t.ResumePath IS NOT NULL;
END
GO


CREATE OR ALTER PROCEDURE dbo.USP_GetTeacherDocumentPath
    @DocumentId bigint,
    @UserUid    uniqueidentifier
AS
BEGIN
    SET NOCOUNT ON;

    SELECT d.FilePath
    FROM dbo.t_app_teacher_documents d
    WHERE d.DocumentId = @DocumentId
      AND d.Is_Deleted = 0
      -- 🔴 The gate. A document id from another teacher matches nothing.
      AND d.TeacherId = dbo.fn_TeacherIdForUser(@UserUid);
END
GO

PRINT '    Teacher experience and document procedures ready.';
GO
