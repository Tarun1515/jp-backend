/*==============================================================================
  jp_app — 019_alter_t_app_school_users_fullname.sql

  The name a team member is known by, added for Phase 3G.

  ---------------------------------------------------------------------------
  🔴 WHY A NAME COLUMN HAS TO EXIST SOMEWHERE, AND WHY IT IS HERE
  ---------------------------------------------------------------------------
  t_sso_users has no name. It has Email and Mobile and nothing else that
  identifies a person, because identity in jp_sso is "which account is this",
  not "who is this".

  That was fine while every school screen showed one account — your own. A TEAM
  screen is a list of other people, and a list of other people identified only
  by email address is unreadable:

      priya.s@greenwood.edu      Senior HR    2 campuses
      r.menon@greenwood.edu      HR           1 campus
      admin@greenwood.edu        Owner        All campuses

  Nobody who works there thinks of their colleagues that way, and the row they
  are looking for is the one they cannot pick out.

  ⚠️ It goes on the MEMBERSHIP rather than on t_sso_users on purpose. This is
  what the school calls this person on their own team — the same argument that
  put DesignationText here. Putting a name on t_sso_users would also put one on
  every teacher and every administrator, which is a decision about identity
  across the whole product and not something a team screen gets to make.

  ---------------------------------------------------------------------------
  ⚠️ EXISTING ROWS STAY NULL. NOTHING IS INVENTED.
  ---------------------------------------------------------------------------
  Every membership that exists today was created by provisioning, which never
  had a name to record. There is a tempting backfill — t_app_schools has
  PrincipalName and HrContactName — and it is wrong: neither field is a promise
  about WHO THE OWNER ACCOUNT BELONGS TO. A school whose registration named its
  principal, and whose account is operated by an office administrator, would get
  the principal's name attached to somebody else's login.

  So the column is nullable, the UI falls back to the email, and the name
  arrives when somebody types it: at invite time for new members, and from the
  team screen for existing ones.

  Target: SQL Server 2019 (15.0).
==============================================================================*/

USE jp_app;
GO

SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

IF NOT EXISTS (SELECT 1 FROM sys.columns
               WHERE object_id = OBJECT_ID('dbo.t_app_school_users') AND name = 'FullName')
BEGIN
    PRINT '    Adding column [t_app_school_users].[FullName] ...';

    /*
      150 characters, matching t_app_teachers.FullName and the contact-name
      columns on t_app_schools. One length for one kind of fact.
    */
    ALTER TABLE dbo.t_app_school_users ADD FullName nvarchar(150) NULL;
END
GO
