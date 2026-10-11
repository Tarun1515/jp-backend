/*==============================================================================
  jp_app — 027_invite_masters.sql

  m_app_invite_status — the five states a teacher invite can be in.

  Phase 6B.

  ---------------------------------------------------------------------------
  🔒 ONE OF THESE FIVE UNLOCKS CONTACT. EXACTLY ONE. (2.56, LOCKED)
  ---------------------------------------------------------------------------
  Decision 2.56 has two consent paths and no others: the teacher APPLIED, or
  the teacher ACCEPTED an invite. Path 1 became real in Phase 5A; path 2
  becomes real here, and `ACCEPTED` is the row it rests on.

  ⚠️ 🔴 THE SPEC DID NOT HAVE AN `ACCEPTED` VALUE, AND THAT WAS THE WHOLE RISK.

  DB_TABLE_STRUCTURE lists `InviteStatus (Sent/Viewed/Applied/Ignored)`. 2.56
  was locked in Phase 3B with a written warning attached to exactly this:
  "Phase 6 ko ACCEPTED status jodna hoga, warna path 2 chup-chaap path 1 mein
  dhal jaayega" — without it, the only way a school could ever reach a
  teacher's contact details would be an APPLICATION, and "accept an invite"
  would quietly mean "go and apply", which is a different product.

  So it is added, and it is the one row whose id `fn_TeacherContactUnlocked`
  names.

  ---------------------------------------------------------------------------
  🔴 WHAT EACH OF THE OTHER FOUR DOES *NOT* DO
  ---------------------------------------------------------------------------
      SENT      the school has asked. Nothing is unlocked — asking is not
                consent, and a school that could see contact details by
                asking for them would make 2.56 decorative.
      VIEWED    the teacher opened it. Still nothing: reading a message is not
                answering it.
      APPLIED   the teacher went and applied instead. Contact IS unlocked —
                but by the APPLICATION (path 1), not by this row. The invite
                records what happened to the invite; the application records
                the consent.
      IGNORED   an explicit no. Nothing, forever.

  ⚠️ And the school's PAYMENT STATUS appears nowhere in this file or in that
  function. A subscription buys the capability to search and to invite. It has
  never bought, and must never buy, a teacher's phone number.

  ---------------------------------------------------------------------------
  🔴 IsOpen IS WHAT THE UNIQUE INDEX MEANS
  ---------------------------------------------------------------------------
  One OPEN invite per school per teacher, enforced by a filtered unique index
  on t_app_teacher_invites. A filtered index cannot join to this table, so its
  predicate names the ids — `InviteStatusId IN (1, 2)`. This column is the
  documentation of that coupling, in the same spirit as 025's IsLive and 023's
  IsReachable.

  ⚠️ Sent AND Viewed are both open: a school gets one outstanding invite per
  teacher at a time whether or not it has been read. The alternative — letting
  a read-but-unanswered invite be followed up — would have meant a school could
  queue invites behind a teacher who simply had not replied yet.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 'm_app_invite_status' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [m_app_invite_status] ...';

    CREATE TABLE dbo.m_app_invite_status
    (
        InviteStatusId     int            NOT NULL,
        Code               varchar(30)    NOT NULL,
        Name               nvarchar(100)  NOT NULL,

        /*
          What the TEACHER is told, on the same reasoning as 023 and 025. The
          school says "Ignored"; the teacher's own list has no business
          shouting that back at them.
        */
        TeacherFacingName  nvarchar(100)  NOT NULL,

        /*
          🔴 1 = this invite is still outstanding. See the header — the
          filtered unique index names these ids.
        */
        IsOpen             tinyint        NOT NULL CONSTRAINT DF_m_app_invite_status_IsOpen DEFAULT (0),

        /*
          🔒 1 = reaching this state is CONSENT (2.56). Exactly one row has it,
          and `fn_TeacherContactUnlocked` names that id directly.

          ⚠️ Read by nothing at runtime — the function is the enforcement, not
          this flag — and here so that a person reading the seed can see which
          single row carries the rule without going to find the function.
        */
        IsConsent          tinyint        NOT NULL CONSTRAINT DF_m_app_invite_status_IsConsent DEFAULT (0),

        DisplayOrder       int            NOT NULL CONSTRAINT DF_m_app_invite_status_DisplayOrder DEFAULT (0),
        Is_Active          tinyint        NOT NULL CONSTRAINT DF_m_app_invite_status_Is_Active  DEFAULT (1),
        Is_Deleted         tinyint        NOT NULL CONSTRAINT DF_m_app_invite_status_Is_Deleted DEFAULT (0),
        CreatedOn          datetime2      NOT NULL CONSTRAINT DF_m_app_invite_status_CreatedOn  DEFAULT (SYSUTCDATETIME()),
        CreatedBy          bigint         NULL,
        ModifiedOn         datetime2      NULL,
        ModifiedBy         bigint         NULL,

        CONSTRAINT PK_m_app_invite_status PRIMARY KEY CLUSTERED (InviteStatusId)
    );

    INSERT INTO dbo.m_app_invite_status
        (InviteStatusId, Code, Name, TeacherFacingName, IsOpen, IsConsent, DisplayOrder)
    VALUES
        (1, 'SENT',     N'Sent',     N'Invitation received',    1, 0, 1),
        (2, 'VIEWED',   N'Viewed',   N'You opened this',        1, 0, 2),

        -- 🔒 THE ONE ROW THAT IS CONSENT. See the header.
        (3, 'ACCEPTED', N'Accepted', N'You accepted',           0, 1, 3),

        -- ⚠️ Contact IS unlocked for an applied invite — by the APPLICATION,
        -- never by this row. IsConsent stays 0 and that is not an oversight.
        (4, 'APPLIED',  N'Applied',  N'You applied instead',    0, 0, 4),

        (5, 'IGNORED',  N'Ignored',  N'You passed on this',     0, 0, 5);
END
ELSE
BEGIN
    PRINT '    Table [m_app_invite_status] already exists — skipped.';
END
GO

IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'UQ_m_app_invite_status_Code' AND object_id = OBJECT_ID('dbo.m_app_invite_status'))
BEGIN
    CREATE UNIQUE NONCLUSTERED INDEX UQ_m_app_invite_status_Code
        ON dbo.m_app_invite_status (Code) WHERE Is_Deleted = 0;
END
GO

/*------------------------------------------------------------------------------
  🔒 A STRUCTURAL GUARD ON 2.56's "EXACTLY ONE".

  If a later phase ever adds a second consent row — or flips IsConsent on an
  existing one — this build fails loudly rather than widening the rule by
  accident. 2.56 is LOCKED: two paths, and the second one is this table's row 3.

  ⚠️ 2.36's rule applied: enforcement by the compiler, not by a comment hoping
  somebody reads it.
------------------------------------------------------------------------------*/
IF (SELECT COUNT(*) FROM dbo.m_app_invite_status WHERE IsConsent = 1 AND Is_Deleted = 0) <> 1
BEGIN
    RAISERROR(N'🔒 2.56 VIOLATION: m_app_invite_status must have EXACTLY ONE IsConsent row. Consent path 2 is ACCEPTED and nothing else.', 16, 1);
END
GO

IF (SELECT Code FROM dbo.m_app_invite_status WHERE IsConsent = 1 AND Is_Deleted = 0) <> 'ACCEPTED'
BEGIN
    RAISERROR(N'🔒 2.56 VIOLATION: the IsConsent row must be ACCEPTED.', 16, 1);
END
GO

PRINT '    Invite masters ready.';
GO
