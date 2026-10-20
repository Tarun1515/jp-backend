/*==============================================================================
  jp_sso — 023_t_sso_user_status_history.sql

  PHASE 8A — G45. Every account status change, with the reason, forever.

  ---------------------------------------------------------------------------
  🔴 THE GAP THIS CLOSES: THE REASON WAS ASKED FOR AND THROWN AWAY
  ---------------------------------------------------------------------------
  USP_UpdateUserStatus has always accepted @Remarks. It kept it in exactly one
  case — a suspension, as a t_sso_user_lockouts row — because that table is
  what answers "why can I not sign in". For every OTHER transition the
  parameter was accepted, validated, and dropped on the floor:

      ACTIVE   (2)  a reactivation — why was this account brought back?
      REJECTED (3)  a rejected registration — on what grounds?

  The Accounts screen was built in 8-0 around the hole rather than over it: it
  offered the reason field only on suspend and unlock, "where the reason is
  kept". That was honest, and it was still a product that cannot answer the
  question a school asks on the phone six weeks later — *who rejected us, and
  what did they say?*

  ⚠️ WHY NOT JUST WIDEN THE LOCKOUT TABLE. A lockout is a thing with a
  duration: LockedOn, UnlockOn, UnlockedByUserId, IsAutoUnlock. A rejection is
  not a lockout and an activation is its opposite; writing them there would
  mean rows where half the columns are meaningless and every read of
  t_sso_user_lockouts would need to learn which rows are really locks. The
  lockout row stays exactly as it is — suspension still writes both, because
  the two tables answer two different questions.

  ---------------------------------------------------------------------------
  🔴 APPEND-ONLY, THE SAME WAY 034 IS APPEND-ONLY
  ---------------------------------------------------------------------------
  No Is_Deleted. No ModifiedOn. No ModifiedBy. No Is_Active.

  That is the structural half: there is no column through which an edit or a
  deletion can be expressed, so the soft-delete shape every other table in
  this schema carries is simply absent here. A history that can be revised is
  not history, and the first person who wants to revise one of these rows will
  be the person it is about.

  ⚠️ NO TRIGGER, deliberately, and for the reason 034 gives: this schema has no
  triggers in any production file, and introducing the first one for this table
  would mean every future reader has to know that writes behave differently
  here than everywhere else. 006_admin.sql carries build guards instead.

  ⚠️ AND THE LIMIT, STATED PLAINLY: somebody with direct database access can
  still UPDATE a row. Nothing short of DENY on a separate login stops that, and
  this project uses one login. What is prevented is the APPLICATION growing a
  way to do it — which is the realistic risk, because applications grow.

  ---------------------------------------------------------------------------
  FromStatusId IS NULLABLE, AND THAT IS NOT LAZINESS
  ---------------------------------------------------------------------------
  A registration arrives at PENDING_APPROVAL without coming from anywhere.
  Rows for accounts that existed before this table did also have no knowable
  previous status, and inventing one would be fabricating history on the first
  day of the table's life. NULL means "not known", and the screen says "set to
  Pending approval" rather than "changed from X to Pending approval".

  ⚠️ USP_UpdateUserStatus NEVER WRITES NULL HERE, and an early draft of it did
  by accident: it copied NULLIF(@CurrentStatusId, 5) from the lockout INSERT
  beside it, having guessed that 5 was some pre-registration state. 5 is
  LOCKED. The lockout row blanks it deliberately — PreviousStatusId is what an
  unlock restores and nothing should be restored TO Locked — but a history that
  forgets an account was locked has lost the only interesting part. The guess
  was caught by reading m_sso_user_status instead of trusting the neighbouring
  line: 1 PENDING_APPROVAL · 2 ACTIVE · 3 REJECTED · 4 SUSPENDED · 5 LOCKED ·
  6 RESUBMIT_REQUIRED.

  🔴 NO FOREIGN KEY FROM ActionByUserId TO t_sso_users, deliberately. An
  administrator's account may one day be hard-deleted, and when it is, this
  history must survive that deletion unchanged — an FK would either block the
  delete or, worse, invite somebody to clear the history to allow it. The id is
  kept for the join that usually succeeds; the screen falls back to "an
  administrator (account no longer exists)" when it does not.
==============================================================================*/

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.tables WHERE name = 't_sso_user_status_history' AND schema_id = SCHEMA_ID('dbo'))
BEGIN
    PRINT '    Creating table [t_sso_user_status_history] ...';

    CREATE TABLE dbo.t_sso_user_status_history
    (
        StatusHistoryId     bigint          IDENTITY(1,1) NOT NULL,
        UserId              bigint          NOT NULL,

        -- NULL = not known. See the header: a registration comes from nowhere.
        FromStatusId        int             NULL,
        ToStatusId          int             NOT NULL,

        /*
          The reason, as the administrator typed it. nvarchar(500) matches
          @Remarks on USP_UpdateUserStatus and Remarks on t_sso_user_lockouts,
          so nothing is silently truncated as it moves between them.

          NULL is allowed and means the administrator gave none — which is
          itself worth recording, and is different from an empty string.
        */
        Reason              nvarchar(500)   NULL,

        -- Who did it. No FK, by decision — see the header.
        ActionByUserId      bigint          NULL,

        -- An INSTANT (decision 2.28): a status change happens at a moment.
        CreatedOn           datetime2       NOT NULL
            CONSTRAINT DF_t_sso_user_status_history_CreatedOn DEFAULT (SYSUTCDATETIME()),

        /*
          ⚠️ NOTHING BELOW THIS LINE. No Is_Deleted, no Is_Active, no
          ModifiedOn, no ModifiedBy. Their absence is the append-only
          guarantee, not an oversight — if you are here to add one, read the
          header first.
        */

        CONSTRAINT PK_t_sso_user_status_history PRIMARY KEY CLUSTERED (StatusHistoryId),

        CONSTRAINT FK_t_sso_user_status_history_t_sso_users
            FOREIGN KEY (UserId) REFERENCES dbo.t_sso_users (UserId),

        CONSTRAINT FK_t_sso_user_status_history_m_sso_user_status_To
            FOREIGN KEY (ToStatusId) REFERENCES dbo.m_sso_user_status (StatusId),

        CONSTRAINT FK_t_sso_user_status_history_m_sso_user_status_From
            FOREIGN KEY (FromStatusId) REFERENCES dbo.m_sso_user_status (StatusId),

        /*
          A transition that goes nowhere is not a transition. The procedure
          already refuses it with 'The account is already in that state.';
          this makes it unrepresentable rather than merely unreachable.
        */
        CONSTRAINT CK_t_sso_user_status_history_Moved
            CHECK (FromStatusId IS NULL OR FromStatusId <> ToStatusId)
    );

    PRINT '    [t_sso_user_status_history] created.';
END
ELSE
BEGIN
    PRINT '    [t_sso_user_status_history] already exists.';
END
GO

/*
  One account's history, newest first — the only read pattern there is.
  CreatedOn descending is included so the screen's ORDER BY is covered by the
  index rather than sorted per request.
*/
IF NOT EXISTS (SELECT 1 FROM sys.indexes
                WHERE name = 'IX_t_sso_user_status_history_UserId'
                  AND object_id = OBJECT_ID('dbo.t_sso_user_status_history'))
BEGIN
    CREATE NONCLUSTERED INDEX IX_t_sso_user_status_history_UserId
        ON dbo.t_sso_user_status_history (UserId, CreatedOn DESC)
        INCLUDE (FromStatusId, ToStatusId, Reason, ActionByUserId);

    PRINT '    IX_t_sso_user_status_history_UserId created.';
END
GO

/*==============================================================================
  BUILD GUARD — THE COLUMNS THAT MUST NOT APPEAR
==============================================================================*/

/*
  🔴 THE APPEND-ONLY PROMISE, CHECKED STRUCTURALLY.

  The header says an edit cannot be EXPRESSED here because there is no column
  to express it through. That is only true for as long as nobody adds one, and
  "somebody will add Is_Deleted out of habit" is the most likely future of this
  table — every other table in the schema has it, and a developer copying a
  neighbouring file gets it for free.

  Checked against sys.columns rather than by reading the CREATE above, because
  the CREATE above does not run on a database where the table already exists.
  An ALTER in a later file is exactly how this would arrive.

  Proven to fire: ALTER TABLE dbo.t_sso_user_status_history ADD Is_Deleted
  tinyint NOT NULL DEFAULT (0) fails this with the column named.
*/
DECLARE @mutable nvarchar(400) = N'';

SELECT @mutable = STRING_AGG(CAST(c.name AS nvarchar(128)), N', ')
  FROM sys.columns c
 WHERE c.object_id = OBJECT_ID('dbo.t_sso_user_status_history')
   AND c.name IN ('Is_Deleted', 'Is_Active', 'ModifiedOn', 'ModifiedBy');

IF ISNULL(@mutable, N'') <> N''
BEGIN
    DECLARE @msg nvarchar(1200) =
        N'023_t_sso_user_status_history: 🔴 AN APPEND-ONLY TABLE HAS GROWN A MUTABLE COLUMN: '
        + @mutable
        + N'. This table is the record of who changed whose account and why. A history that can be edited or soft-deleted is not a history, and the first person who wants to edit one of these rows will be the person it is about. If a row here is genuinely wrong, the fix is another row, not an UPDATE.';

    RAISERROR('%s', 16, 1, @msg);
END
GO

PRINT '    t_sso_user_status_history ready.';
GO
