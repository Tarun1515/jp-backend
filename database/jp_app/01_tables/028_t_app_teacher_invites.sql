/*==============================================================================
  jp_app — 028_t_app_teacher_invites.sql

  t_app_teacher_invites — a school invites a teacher, with or without a job.

  Phase 6B.

  ---------------------------------------------------------------------------
  🔒 THIS TABLE IS CONSENT PATH 2 (2.56, LOCKED)
  ---------------------------------------------------------------------------
  `fn_TeacherContactUnlocked` reads exactly two tables: t_app_applications
  (path 1, Phase 5A) and this one. A row here with InviteStatusId = 3 ACCEPTED
  is the second and FINAL way a school ever sees a teacher's contact details.

  ⚠️ SENT IS NOT ACCEPTED, and that difference is the whole rule. A school that
  could reach contact details by SENDING an invite would make 2.56 decorative —
  it would mean paying for the ability to invite was paying for the number.

  ---------------------------------------------------------------------------
  🔴 ONE OPEN INVITE PER SCHOOL PER TEACHER
  ---------------------------------------------------------------------------
  UQ_t_app_teacher_invites_Open is a filtered unique index on
  (SchoolId, TeacherId) where the invite is still open — Sent or Viewed. Two
  things rest on it:

    · a double-click cannot send two invites, which matters more here than
      almost anywhere else because TEACHER_INVITE is METERED: two rows would be
      two charges for one intention;
    · the race resolves the 5A way — the 2601 is caught, the collision is
      verified to be on THIS index BY NAME (the 3C lesson), and the existing
      row is re-read before anything is reported as already done (2.48).

  ⚠️ The predicate NAMES the ids — `InviteStatusId IN (1, 2)` — because a
  filtered index cannot join to m_app_invite_status. 027's IsOpen column is the
  documentation of that coupling.

  ---------------------------------------------------------------------------
  ⚠️ JobId IS NULLABLE, AND THAT IS THE POINT OF THE FEATURE
  ---------------------------------------------------------------------------
  The client's spec starred this: a school may invite a teacher WITHOUT having
  posted a job. "We would like to talk to you" is a real thing to say, and
  forcing a posting first would make the invite a job advert.

  With a JobId, the teacher gets a third option — apply to that job instead of
  answering the invite. The invite then records APPLIED, and the unlock comes
  from the application (path 1), not from here.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_app_teacher_invites' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_app_teacher_invites] ...';

    CREATE TABLE dbo.t_app_teacher_invites
    (
        InviteId          bigint            IDENTITY(1,1) NOT NULL,

        /*
          🔴 THE ENTITLEMENT REFERENCE. TEACHER_INVITE is metered, and this is
          the id the ledger records as RefEntityUid — so a retry of the same
          invite resolves to ALREADY_CONSUMED instead of charging twice (2.5).

          ⚠️ Minted by the DEFAULT here, inside the same transaction as the row,
          so the id that is charged and the id that exists are the same id. A
          Uid minted in the API before the insert would charge for an invite
          that might then fail to write.
        */
        InviteUid         uniqueidentifier  NOT NULL CONSTRAINT DF_t_app_teacher_invites_InviteUid DEFAULT (NEWID()),

        SchoolId          bigint            NOT NULL,
        BranchId          bigint            NOT NULL,
        TeacherId         bigint            NOT NULL,

        /*
          NULL = "we would like to talk to you", with no posting behind it. See
          the header — this is the starred part of the feature.
        */
        JobId             bigint            NULL,

        InvitedByUserId   bigint            NULL,

        Message           nvarchar(2000)    NULL,

        InviteStatusId    int               NOT NULL CONSTRAINT DF_t_app_teacher_invites_InviteStatusId DEFAULT (1),

        SentOn            datetime2         NOT NULL CONSTRAINT DF_t_app_teacher_invites_SentOn DEFAULT (SYSUTCDATETIME()),

        /*
          ⚠️ A TIMESTAMP, NOT A SECOND SOURCE OF TRUTH. The status moves to
          Viewed on the first open; this records WHEN. Reading the status to
          find out whether it was seen would stop working the moment the
          teacher answers.
        */
        ViewedOn          datetime2         NULL,

        RespondedOn       datetime2         NULL,

        /*
          The teacher's own words when they answer. Shown to the school —
          unlike a school's rejection reason, which travels the other way and
          is never shown to the teacher (017 / 018).
        */
        TeacherRemarks    nvarchar(1000)    NULL,

        RowVersion        int               NOT NULL CONSTRAINT DF_t_app_teacher_invites_RowVersion DEFAULT (1),

        Is_Active         tinyint           NOT NULL CONSTRAINT DF_t_app_teacher_invites_Is_Active  DEFAULT (1),
        Is_Deleted        tinyint           NOT NULL CONSTRAINT DF_t_app_teacher_invites_Is_Deleted DEFAULT (0),
        CreatedOn         datetime2         NOT NULL CONSTRAINT DF_t_app_teacher_invites_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy         bigint            NULL,
        ModifiedOn        datetime2         NULL,
        ModifiedBy        bigint            NULL,

        CONSTRAINT PK_t_app_teacher_invites PRIMARY KEY CLUSTERED (InviteId),

        CONSTRAINT FK_t_app_teacher_invites_m_app_invite_status
            FOREIGN KEY (InviteStatusId) REFERENCES dbo.m_app_invite_status (InviteStatusId),
        CONSTRAINT FK_t_app_teacher_invites_t_app_school_branches
            FOREIGN KEY (BranchId) REFERENCES dbo.t_app_school_branches (BranchId),
        CONSTRAINT FK_t_app_teacher_invites_t_app_teachers
            FOREIGN KEY (TeacherId) REFERENCES dbo.t_app_teachers (TeacherId),
        CONSTRAINT FK_t_app_teacher_invites_t_app_jobs
            FOREIGN KEY (JobId) REFERENCES dbo.t_app_jobs (JobId)
    );
END
ELSE
BEGIN
    PRINT '    Table [t_app_teacher_invites] already exists — skipped.';
END
GO

/*------------------------------------------------------------------------------
  🔴 THE GUARD. One OPEN invite per school per teacher.

  ⚠️ QUOTED_IDENTIFIER must be ON or this fails with Msg 1934 — which is why
  every script here sets it and why `sqlcmd -I` is not optional.
------------------------------------------------------------------------------*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_teacher_invites_Open' AND object_id = OBJECT_ID('dbo.t_app_teacher_invites'))
BEGIN
    PRINT '    Creating filtered unique index [UQ_t_app_teacher_invites_Open] ...';

    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_teacher_invites_Open
        ON dbo.t_app_teacher_invites (SchoolId, TeacherId)
        WHERE InviteStatusId IN (1, 2) AND Is_Deleted = 0;
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_t_app_teacher_invites_InviteUid' AND object_id = OBJECT_ID('dbo.t_app_teacher_invites'))
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UQ_t_app_teacher_invites_InviteUid
        ON dbo.t_app_teacher_invites (InviteUid) WHERE Is_Deleted = 0;
END
GO

/*
  🔒 THE READ fn_TeacherContactUnlocked MAKES, every time contact is decided.
  Narrow and covering, because it is on the hottest path in the product that
  has a privacy rule attached to it.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_teacher_invites_Consent' AND object_id = OBJECT_ID('dbo.t_app_teacher_invites'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_t_app_teacher_invites_Consent
        ON dbo.t_app_teacher_invites (TeacherId, SchoolId, InviteStatusId)
        WHERE Is_Deleted = 0;
END
GO

-- The school's own outbox, and the teacher's inbox.
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_teacher_invites_School' AND object_id = OBJECT_ID('dbo.t_app_teacher_invites'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_t_app_teacher_invites_School
        ON dbo.t_app_teacher_invites (SchoolId, InviteStatusId)
        INCLUDE (TeacherId, BranchId, JobId, SentOn, ViewedOn, RespondedOn)
        WHERE Is_Deleted = 0;
END
GO

PRINT '    t_app_teacher_invites ready.';
GO
