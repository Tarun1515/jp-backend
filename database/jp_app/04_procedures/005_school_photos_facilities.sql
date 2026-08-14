/*==============================================================================
  jp_app — 04_procedures / 005_school_photos_facilities.sql

  USP_SaveSchoolPhotos      add, reorder, soft-delete
  USP_SaveSchoolFacilities  🔴 THE BRIDGE-SYNC PATTERN — 3D follows this exactly

  ---------------------------------------------------------------------------
  🔴 THE BRIDGE-SYNC PATTERN, DECIDED ONCE
  ---------------------------------------------------------------------------
  Used here for facilities and, in Phase 3D, for all five teacher bridges:
  subjects, class levels, skills, languages, preferred locations.

  THE CALLER SENDS THE WHOLE DESIRED SET. The procedure diffs it against what
  is stored, INSERTS what is new and SOFT-DELETES what has gone. It does not
  delete everything and re-insert.

  Why that matters, concretely:

  1. IDENTITIES CHURN. Delete-and-reinsert gives every row a new Id on every
     save. Anything that ever points at a bridge row — a moderation note, an
     audit entry, a future FK — breaks silently, and it breaks on a save where
     nothing actually changed.

  2. A NO-OP SAVE BECOMES A FULL REWRITE. Opening a form and pressing Save
     without touching anything would delete eleven rows and insert eleven rows.
     Every one carries a new CreatedOn, so "when did this school add a library"
     becomes "the last time anybody pressed Save".

  3. THE SOFT-DELETE RULE. Nothing in this database issues a DELETE; Is_Deleted
     is the tombstone. A pattern that hard-deletes to rebuild is a pattern that
     has to make an exception to the one rule that has no exceptions.

  The diff also makes the reverse operation free: re-adding something that was
  removed UPDATES its tombstone back rather than inserting a second row, which
  is exactly what the filtered unique index expects (2.51).

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/*------------------------------------------------------------------------------
  The table type the bridge-sync procedures take.

  ⚠️ Guarded: a table type cannot be altered, only dropped and recreated, and
  dropping it fails while any procedure references it. If a column is ever
  needed here, that is a new type with a new name — not an edit to this one.
------------------------------------------------------------------------------*/
IF TYPE_ID(N'dbo.IntIdList') IS NULL
BEGIN
    PRINT '    Creating table type [IntIdList] ...';

    CREATE TYPE dbo.IntIdList AS TABLE
    (
        Id int NOT NULL PRIMARY KEY
    );
END
GO


/*==============================================================================
  USP_SaveSchoolFacilities — the reference implementation of the pattern.

  @BranchId NULL means the facilities of the school as a whole; a value means
  that campus's. The two are different claims and are synced independently
  (2.51), so a save for one campus never touches another's.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveSchoolFacilities
    @SchoolId       bigint,
    @UserUid        uniqueidentifier,
    @BranchId       bigint = NULL,
    @FacilityIds    dbo.IntIdList READONLY,
    @ActionByUserId bigint = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = @SchoolId,
            @Now datetime2 = SYSUTCDATETIME();

    DECLARE @added int = 0, @removed int = 0, @restored int = 0;

    IF NOT EXISTS (SELECT 1 FROM dbo.t_app_schools WHERE SchoolId = @SchoolId AND Is_Deleted = 0)
        SELECT @Code = 'NOT_FOUND', @Message = N'That school was not found.';
    ELSE IF dbo.fn_IsSchoolMember(@SchoolId, @UserUid) = 0
        SELECT @Code = 'NOT_FOUND', @Message = N'That school was not found.';

    -- A branch was named: it must belong to this school AND be one the caller
    -- can see. Both, because either alone leaves a hole.
    ELSE IF @BranchId IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM dbo.fn_VisibleBranches(@SchoolId, @UserUid) v
                        WHERE v.BranchId = @BranchId)
        SELECT @Code = 'NOT_FOUND', @Message = N'That branch was not found.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            BEGIN TRANSACTION;

            /*
              1. GONE — in the table, not in the incoming set. Soft-deleted.

              Only rows that are currently live are touched, so a second
              identical save updates nothing at all.
            */
            UPDATE f
               SET f.Is_Deleted = 1,
                   f.ModifiedOn = @Now,
                   f.ModifiedBy = @ActionByUserId
            FROM dbo.t_app_school_facilities f
            WHERE f.SchoolId = @SchoolId
              AND ((@BranchId IS NULL AND f.BranchId IS NULL) OR f.BranchId = @BranchId)
              AND f.Is_Deleted = 0
              AND NOT EXISTS (SELECT 1 FROM @FacilityIds i WHERE i.Id = f.FacilityId);

            SET @removed = @@ROWCOUNT;

            /*
              2. BACK — in the incoming set, present but tombstoned. Restored in
              place, which keeps the original Id and CreatedOn.

              This is the half that delete-and-reinsert cannot do, and the half
              the filtered unique index requires: inserting instead would
              collide with the tombstoned row the moment it is un-deleted.
            */
            UPDATE f
               SET f.Is_Deleted = 0,
                   f.Is_Active  = 1,
                   f.ModifiedOn = @Now,
                   f.ModifiedBy = @ActionByUserId
            FROM dbo.t_app_school_facilities f
                INNER JOIN @FacilityIds i ON i.Id = f.FacilityId
            WHERE f.SchoolId = @SchoolId
              AND ((@BranchId IS NULL AND f.BranchId IS NULL) OR f.BranchId = @BranchId)
              AND f.Is_Deleted = 1;

            SET @restored = @@ROWCOUNT;

            /*
              3. NEW — in the incoming set, no row at all. Inserted.

              NOT EXISTS against every row regardless of Is_Deleted: step 2 has
              already revived any tombstone, so anything still absent here has
              genuinely never existed.
            */
            INSERT INTO dbo.t_app_school_facilities (SchoolId, BranchId, FacilityId, CreatedBy)
            SELECT @SchoolId, @BranchId, i.Id, @ActionByUserId
            FROM @FacilityIds i
            WHERE NOT EXISTS (
                SELECT 1 FROM dbo.t_app_school_facilities f
                WHERE f.SchoolId = @SchoolId
                  AND ((@BranchId IS NULL AND f.BranchId IS NULL) OR f.BranchId = @BranchId)
                  AND f.FacilityId = i.Id);

            SET @added = @@ROWCOUNT;

            COMMIT TRANSACTION;

            SELECT @Status = 1,
                   @Message = N'Facilities saved. Added ' + CAST(@added AS nvarchar(10))
                            + N', restored ' + CAST(@restored AS nvarchar(10))
                            + N', removed ' + CAST(@removed AS nvarchar(10)) + N'.';
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params nvarchar(max) = (
                SELECT @SchoolId AS schoolId, @BranchId AS branchId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params,
                 @ContextInfo = N'USP_SaveSchoolFacilities', @CreatedBy = @ActionByUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id,
           @added AS Added, @restored AS Restored, @removed AS Removed;
END
GO


/*==============================================================================
  USP_SaveSchoolPhotos

  ⚠️ NOT the bridge-sync pattern, and the difference is worth stating: a photo
  carries a FILE. Soft-deleting a bridge row costs nothing; removing a photo
  leaves an orphaned file on disk, and re-adding it later is a new upload rather
  than a revived row.

  So this is three explicit operations rather than a diff:
      @Action = 'ADD'      one new photo
      @Action = 'REORDER'  DisplayOrder from the supplied list's order
      @Action = 'DELETE'   soft-delete one photo

  The caller says what it means. A diff would have had to infer "this file is
  gone" from its absence, which is the same shape as inferring a deletion from a
  failed upload.
==============================================================================*/
CREATE OR ALTER PROCEDURE dbo.USP_SaveSchoolPhotos
    @SchoolId       bigint,
    @UserUid        uniqueidentifier,
    @Action         varchar(20),
    @PhotoId        bigint         = NULL,
    @BranchId       bigint         = NULL,
    @FilePath       nvarchar(500)  = NULL,
    @Caption        nvarchar(250)  = NULL,
    @PhotoOrder     dbo.IntIdList  READONLY,
    @ActionByUserId bigint         = NULL
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Status int = 0, @Code varchar(50) = NULL,
            @Message nvarchar(400) = NULL, @Id bigint = NULL,
            @Now datetime2 = SYSUTCDATETIME();

    SET @Action = UPPER(LTRIM(RTRIM(ISNULL(@Action, ''))));

    IF NOT EXISTS (SELECT 1 FROM dbo.t_app_schools WHERE SchoolId = @SchoolId AND Is_Deleted = 0)
        SELECT @Code = 'NOT_FOUND', @Message = N'That school was not found.';
    ELSE IF dbo.fn_IsSchoolMember(@SchoolId, @UserUid) = 0
        SELECT @Code = 'NOT_FOUND', @Message = N'That school was not found.';
    ELSE IF @Action NOT IN ('ADD', 'REORDER', 'DELETE')
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'That action is not recognised.';
    ELSE IF @Action = 'ADD' AND ISNULL(@FilePath, N'') = N''
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'The photo file is required.';
    ELSE IF @Action IN ('DELETE') AND @PhotoId IS NULL
        SELECT @Code = 'VALIDATION_FAILED', @Message = N'Which photo?';
    ELSE IF @Action = 'ADD' AND @BranchId IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM dbo.fn_VisibleBranches(@SchoolId, @UserUid) v
                        WHERE v.BranchId = @BranchId)
        SELECT @Code = 'NOT_FOUND', @Message = N'That branch was not found.';

    -- The photo must belong to THIS school. Without this, a photo id from
    -- another school could be deleted by anybody who could guess it.
    ELSE IF @PhotoId IS NOT NULL
        AND NOT EXISTS (SELECT 1 FROM dbo.t_app_school_photos
                        WHERE PhotoId = @PhotoId AND SchoolId = @SchoolId AND Is_Deleted = 0)
        SELECT @Code = 'NOT_FOUND', @Message = N'That photo was not found.';

    IF @Code IS NULL
    BEGIN
        BEGIN TRY
            IF @Action = 'ADD'
            BEGIN
                DECLARE @NextOrder int =
                    ISNULL((SELECT MAX(DisplayOrder) FROM dbo.t_app_school_photos
                            WHERE SchoolId = @SchoolId AND Is_Deleted = 0), 0) + 1;

                INSERT INTO dbo.t_app_school_photos
                    (SchoolId, BranchId, FilePath, Caption, DisplayOrder, CreatedBy)
                VALUES (@SchoolId, @BranchId, @FilePath, @Caption, @NextOrder, @ActionByUserId);

                SET @Id = SCOPE_IDENTITY();
                SELECT @Status = 1, @Message = N'Photo added.';
            END
            ELSE IF @Action = 'DELETE'
            BEGIN
                UPDATE dbo.t_app_school_photos
                   SET Is_Deleted = 1, ModifiedOn = @Now, ModifiedBy = @ActionByUserId
                 WHERE PhotoId = @PhotoId AND SchoolId = @SchoolId AND Is_Deleted = 0;

                SET @Id = @PhotoId;
                SELECT @Status = 1, @Message = N'Photo removed.';
            END
            ELSE  -- REORDER
            BEGIN
                /*
                  DisplayOrder comes from the ORDER OF THE SUPPLIED LIST, and a
                  table type has no inherent order — so the position is taken
                  from the Id values themselves via ROW_NUMBER over the caller's
                  sequence, which for a reorder IS the photo id list in the new
                  order.

                  ⚠️ Only photos of THIS school are touched; an id from another
                  school in the list is ignored rather than reordered.
                */
                WITH ordered AS (
                    SELECT i.Id AS PhotoId, ROW_NUMBER() OVER (ORDER BY i.Id) AS Position
                    FROM @PhotoOrder i
                )
                UPDATE p
                   SET p.DisplayOrder = o.Position,
                       p.ModifiedOn   = @Now,
                       p.ModifiedBy   = @ActionByUserId
                FROM dbo.t_app_school_photos p
                    INNER JOIN ordered o ON o.PhotoId = p.PhotoId
                WHERE p.SchoolId = @SchoolId AND p.Is_Deleted = 0;

                SELECT @Status = 1, @Message = N'Photos reordered.';
            END
        END TRY
        BEGIN CATCH
            DECLARE @ErrNumber int = ERROR_NUMBER(), @ErrSeverity int = ERROR_SEVERITY(),
                    @ErrState int = ERROR_STATE(), @ErrProcedure sysname = ERROR_PROCEDURE(),
                    @ErrLine int = ERROR_LINE(), @ErrMessage nvarchar(4000) = ERROR_MESSAGE();

            IF XACT_STATE() <> 0 ROLLBACK TRANSACTION;

            DECLARE @Params2 nvarchar(max) = (
                SELECT @SchoolId AS schoolId, @Action AS action, @PhotoId AS photoId
                FOR JSON PATH, WITHOUT_ARRAY_WRAPPER);

            EXEC dbo.USP_LogError @ErrorNumber = @ErrNumber, @ErrorSeverity = @ErrSeverity,
                 @ErrorState = @ErrState, @ErrorProcedure = @ErrProcedure, @ErrorLine = @ErrLine,
                 @ErrorMessage = @ErrMessage, @ParametersJson = @Params2,
                 @ContextInfo = N'USP_SaveSchoolPhotos', @CreatedBy = @ActionByUserId;

            THROW;
        END CATCH
    END

    SELECT @Status AS Status, @Code AS Code, @Message AS Message, @Id AS Id;
END
GO

PRINT '    School photo and facility procedures ready.';
GO
