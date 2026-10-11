/*
================================================================================
  PHASE 6C — t_app_notifications

--------------------------------------------------------------------------------
  🔒 THE SCOPE IS RecipientUserUid, AND THERE IS NO SECOND WAY IN
--------------------------------------------------------------------------------
  The brief locks this: "a user reads exactly their rows, 404-class behaviour
  for anyone else's". So this table has **no SchoolId and no OrganizationUid**,
  and that absence is the design.

  🔴 It would have been easy to add SchoolId "for reporting". It would also have
  created the query somebody eventually writes — every notification for a
  school, read by whoever is senior enough — and from then on the per-user scope
  would be a convention rather than a fact. There is no column to filter by, so
  there is no such query to write.

  A school-facing event therefore FANS OUT at write time: one row per recipient
  user, each owning its own read state. That is the honest model anyway — "read"
  is something a person does, not an organisation.

--------------------------------------------------------------------------------
  ⚠️ WHY THE TEXT IS STORED RATHER THAN RENDERED ON READ
--------------------------------------------------------------------------------
  Title and Body are written at creation, not composed from the type plus the
  referenced row. Two reasons, and the second is the real one:

    1. A notification is a record of what somebody was TOLD. Re-rendering it
       later from live data would silently rewrite history — "Shortlisted for
       Physics Teacher" becoming "Shortlisted for Senior Physics Teacher"
       because the job was edited.
    2. 🔒 The referenced row may stop being readable by the recipient. An
       application can be withdrawn, an offer deleted. Rendering on read would
       mean a notification list that has to resolve contact-gated rows to draw
       itself, which is exactly the kind of back door 2.56 exists to prevent.

  ⚠️ So nothing here is contact-shaped. A teacher's name is not a secret (the
  browse profile returns it), but no email, mobile, or resume path goes in this
  table — those are only ever served by USP_GetTeacherContactForSchool.

--------------------------------------------------------------------------------
  ActionUrl — a RELATIVE path, inside the app that owns the recipient
--------------------------------------------------------------------------------
  Written as '/applicants/12', never as 'http://localhost:4300/applicants/12'.
  G30's lesson was a button that did nothing; an absolute URL baked into a row
  is the slower version of the same bug — it works until the host changes.
================================================================================
*/
USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF OBJECT_ID('dbo.t_app_notifications', 'U') IS NULL
BEGIN
    CREATE TABLE dbo.t_app_notifications
    (
        NotificationId      bigint          IDENTITY(1,1)   NOT NULL,
        NotificationUid     uniqueidentifier NOT NULL CONSTRAINT DF_t_app_notifications_Uid DEFAULT (NEWID()),

        /*
          🔒 THE ONLY SCOPE. Not a school, not an organisation — the person.
          Deliberately not an FK: users live in jp_sso and 2.2 forbids a
          cross-database constraint. The API only ever passes the uid from the
          caller's own JWT (2.39).
        */
        RecipientUserUid    uniqueidentifier NOT NULL,

        NotificationTypeId  int             NOT NULL,

        Title               nvarchar(200)   NOT NULL,
        Body                nvarchar(1000)  NULL,

        /** Relative path within the recipient's own app. See the header. */
        ActionUrl           nvarchar(300)   NULL,

        /*
          What this is about, for grouping and for the screen's icon.
          1 application · 2 invitation · 3 offer · 4 job — the same numbering
          the feature ledger uses for its references, deliberately.
        */
        RefEntityTypeId     tinyint         NULL,
        RefEntityUid        uniqueidentifier NULL,

        IsRead              bit             NOT NULL CONSTRAINT DF_t_app_notifications_IsRead DEFAULT (0),
        ReadOn              datetime2(3)    NULL,

        /** Stamped by the dispatcher, so a resend is visible rather than guessed. */
        EmailSentOn         datetime2(3)    NULL,

        Is_Deleted          tinyint         NOT NULL CONSTRAINT DF_t_app_notifications_IsDeleted DEFAULT (0),
        CreatedOn           datetime2(3)    NOT NULL CONSTRAINT DF_t_app_notifications_CreatedOn DEFAULT (SYSUTCDATETIME()),
        ModifiedOn          datetime2(3)    NULL,
        RowVersion          int             NOT NULL CONSTRAINT DF_t_app_notifications_RowVersion DEFAULT (1),

        CONSTRAINT PK_t_app_notifications PRIMARY KEY CLUSTERED (NotificationId),
        CONSTRAINT UQ_t_app_notifications_Uid UNIQUE (NotificationUid),
        CONSTRAINT FK_t_app_notifications_m_app_notification_type
            FOREIGN KEY (NotificationTypeId) REFERENCES dbo.m_app_notification_type (NotificationTypeId),

        /*
          ⚠️ ReadOn and IsRead cannot disagree. Without this, "mark read" could
          set the flag and forget the stamp, and the only symptom would be a
          blank column in a list somebody reads six months from now.
        */
        CONSTRAINT CK_t_app_notifications_ReadOn
            CHECK ((IsRead = 1 AND ReadOn IS NOT NULL) OR (IsRead = 0 AND ReadOn IS NULL))
    );
END
GO

/*
  The list query: one person's notifications, newest first.

  ⚠️ CreatedOn DESC is in the key rather than left to a sort, because this is
  the only way this table is ever read and the list is paged.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_notifications_Recipient' AND object_id = OBJECT_ID('dbo.t_app_notifications'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_t_app_notifications_Recipient
        ON dbo.t_app_notifications (RecipientUserUid, Is_Deleted, CreatedOn DESC)
        INCLUDE (NotificationTypeId, Title, IsRead);
END
GO

/*
  🔴 THE UNREAD BADGE IS ITS OWN INDEX, FILTERED.

  Every screen in the portal asks for this count on every navigation. Counting
  unread rows out of the list index means reading all of a person's history to
  answer "is there anything new" — and the answer is almost always a small
  number of rows.

  ⚠️ Filtered index, so `-I` (QUOTED_IDENTIFIER ON) is mandatory when running
  this file — Msg 1934 otherwise. The whole build sets it; a hand-run sqlcmd
  needs -I.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
               WHERE name = 'IX_t_app_notifications_Unread' AND object_id = OBJECT_ID('dbo.t_app_notifications'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_t_app_notifications_Unread
        ON dbo.t_app_notifications (RecipientUserUid)
        WHERE IsRead = 0 AND Is_Deleted = 0;
END
GO

/*
  ⚠️ NO UNIQUE CONSTRAINT ON (Recipient, Type, RefEntityUid), AND THAT IS A
  DECISION.

  It would prevent a double notification for one event, which is tempting. But
  the same type can legitimately repeat for the same entity: an offer is sent,
  withdrawn, and sent again (2.73 allows exactly that), and the teacher should
  be told twice. A constraint here would have turned a supported negotiation
  into a silent swallow.

  🔴 Duplicate suppression therefore belongs to the CALLER, which knows whether
  this occurrence is new — and 021's creators are called from inside each
  event's own transaction, so "the event happened once" already guarantees "the
  notification was written once".
*/

PRINT '  t_app_notifications ready';
GO
