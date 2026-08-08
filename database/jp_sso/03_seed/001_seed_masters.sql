/*==============================================================================
  jp_sso — 03_seed / 001_seed_masters.sql

  Seeds all 7 jp_sso master tables.

  Re-runnable. MERGE corrects a changed Name or DisplayOrder on re-run, but
  never deletes unmatched target rows — soft delete only, and an admin may have
  deliberately deactivated something.

  ---------------------------------------------------------------------------
  THESE IDS ARE CONTRACT
  ---------------------------------------------------------------------------
  Every id below is mirrored by an enum in JP.Core.Enums and, for status codes,
  by constants in the Angular app. Never renumber an existing row. To retire
  one, set Is_Active = 0; to add one, use the next free id.
==============================================================================*/

USE jp_sso;
GO

-- Filtered indexes REQUIRE these. sqlcmd defaults QUOTED_IDENTIFIER to OFF
-- (SSMS defaults it ON), so without this every CREATE INDEX with a WHERE
-- clause fails with Msg 1934 — and so does any later INSERT into the table.
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

SET NOCOUNT ON;
GO

/*------------------------------------------------------------------------------
  m_sso_user_types — JP.Core.Enums.UserType
------------------------------------------------------------------------------*/
MERGE dbo.m_sso_user_types AS tgt
USING (VALUES
        (1, 'ADMIN',   N'Administrator', 1),
        (2, 'SCHOOL',  N'School',        2),
        (3, 'TEACHER', N'Teacher',       3)
      ) AS src (UserTypeId, Code, Name, DisplayOrder)
    ON tgt.UserTypeId = src.UserTypeId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (UserTypeId, Code, Name, DisplayOrder)
         VALUES (src.UserTypeId, src.Code, src.Name, src.DisplayOrder);

PRINT '    m_sso_user_types seeded.';
GO

/*------------------------------------------------------------------------------
  m_sso_user_status — JP.Core.Enums.UserStatus

  Only StatusId = 2 (ACTIVE) clears [RequireActiveAccount]. A school registers
  at 1 and stays there until an admin approves it; a teacher registers straight
  into 2 because teacher verification is a soft badge, not a gate (2.9).
------------------------------------------------------------------------------*/
MERGE dbo.m_sso_user_status AS tgt
USING (VALUES
        (1, 'PENDING_APPROVAL',  N'Pending approval',   1),
        (2, 'ACTIVE',            N'Active',             2),
        (3, 'REJECTED',          N'Rejected',           3),
        (4, 'SUSPENDED',         N'Suspended',          4),
        (5, 'LOCKED',            N'Locked',             5),
        (6, 'RESUBMIT_REQUIRED', N'Resubmit required',  6)
      ) AS src (StatusId, Code, Name, DisplayOrder)
    ON tgt.StatusId = src.StatusId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (StatusId, Code, Name, DisplayOrder)
         VALUES (src.StatusId, src.Code, src.Name, src.DisplayOrder);

PRINT '    m_sso_user_status seeded.';
GO

/*------------------------------------------------------------------------------
  m_sso_hash_algorithms — JP.Core.Enums.PasswordHashAlgorithm

  DefaultIterations must stay in step with AppConstants.Password.Pbkdf2Iterations.
  Raising it here and there affects only NEW passwords; existing credentials
  keep verifying at whatever cost their own row records.
------------------------------------------------------------------------------*/
MERGE dbo.m_sso_hash_algorithms AS tgt
USING (VALUES
        (1, 'PBKDF2_SHA256', N'PBKDF2-HMAC-SHA256', 210000, 1)
      ) AS src (HashAlgorithmId, Code, Name, DefaultIterations, DisplayOrder)
    ON tgt.HashAlgorithmId = src.HashAlgorithmId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name
                  OR tgt.DefaultIterations <> src.DefaultIterations)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DefaultIterations = src.DefaultIterations,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (HashAlgorithmId, Code, Name, DefaultIterations, DisplayOrder)
         VALUES (src.HashAlgorithmId, src.Code, src.Name, src.DefaultIterations, src.DisplayOrder);

PRINT '    m_sso_hash_algorithms seeded.';
GO

/*------------------------------------------------------------------------------
  m_sso_token_types — JP.Core.Enums.TokenType

  Validity values match AppConstants.Tokens:
    refresh 7 days, password reset 30 min, email verify 24 h, invite 7 days.
------------------------------------------------------------------------------*/
MERGE dbo.m_sso_token_types AS tgt
USING (VALUES
        (1, 'REFRESH',        N'Refresh token',      10080, 1),
        (2, 'PASSWORD_RESET', N'Password reset',        30, 2),
        (3, 'EMAIL_VERIFY',   N'Email verification',  1440, 3),
        (4, 'INVITE',         N'Invitation',         10080, 4)
      ) AS src (TokenTypeId, Code, Name, DefaultValidityMinutes, DisplayOrder)
    ON tgt.TokenTypeId = src.TokenTypeId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name
                  OR tgt.DefaultValidityMinutes <> src.DefaultValidityMinutes)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DefaultValidityMinutes = src.DefaultValidityMinutes,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (TokenTypeId, Code, Name, DefaultValidityMinutes, DisplayOrder)
         VALUES (src.TokenTypeId, src.Code, src.Name, src.DefaultValidityMinutes, src.DisplayOrder);

PRINT '    m_sso_token_types seeded.';
GO

/*------------------------------------------------------------------------------
  m_sso_otp_channels — JP.Core.Enums.OtpChannel
------------------------------------------------------------------------------*/
MERGE dbo.m_sso_otp_channels AS tgt
USING (VALUES
        (1, 'EMAIL', N'Email', 1),
        (2, 'SMS',   N'SMS',   2)
      ) AS src (OtpChannelId, Code, Name, DisplayOrder)
    ON tgt.OtpChannelId = src.OtpChannelId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (OtpChannelId, Code, Name, DisplayOrder)
         VALUES (src.OtpChannelId, src.Code, src.Name, src.DisplayOrder);

PRINT '    m_sso_otp_channels seeded.';
GO

/*------------------------------------------------------------------------------
  m_sso_lock_reasons — JP.Core.Enums.LockReason

  IsAutoUnlock is what separates the two: a failed-attempts lock expires by
  itself at UnlockOn; an admin suspension has to be lifted by a person.
------------------------------------------------------------------------------*/
MERGE dbo.m_sso_lock_reasons AS tgt
USING (VALUES
        (1, 'FAILED_ATTEMPTS', N'Too many failed sign-in attempts', 1, 1),
        (2, 'ADMIN_SUSPEND',   N'Suspended by an administrator',    0, 2)
      ) AS src (LockReasonId, Code, Name, IsAutoUnlock, DisplayOrder)
    ON tgt.LockReasonId = src.LockReasonId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.IsAutoUnlock <> src.IsAutoUnlock)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.IsAutoUnlock = src.IsAutoUnlock,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (LockReasonId, Code, Name, IsAutoUnlock, DisplayOrder)
         VALUES (src.LockReasonId, src.Code, src.Name, src.IsAutoUnlock, src.DisplayOrder);

PRINT '    m_sso_lock_reasons seeded.';
GO

/*------------------------------------------------------------------------------
  m_sso_modules — the 10 functional areas permissions group under.
------------------------------------------------------------------------------*/
MERGE dbo.m_sso_modules AS tgt
USING (VALUES
        (1,  'AUTH',         N'Authentication',  1),
        (2,  'USERS',        N'Users',           2),
        (3,  'JOBS',         N'Jobs',            3),
        (4,  'APPLICANTS',   N'Applicants',      4),
        (5,  'BRANCHES',     N'Branches',        5),
        (6,  'VERIFICATION', N'Verification',    6),
        (7,  'REPORTS',      N'Reports',         7),
        (8,  'MODERATION',   N'Moderation',      8),
        (9,  'CMS',          N'Content',         9),
        (10, 'SETTINGS',     N'Settings',       10)
      ) AS src (ModuleId, Code, Name, DisplayOrder)
    ON tgt.ModuleId = src.ModuleId
WHEN MATCHED AND (tgt.Code <> src.Code OR tgt.Name <> src.Name OR tgt.DisplayOrder <> src.DisplayOrder)
    THEN UPDATE SET tgt.Code = src.Code, tgt.Name = src.Name,
                    tgt.DisplayOrder = src.DisplayOrder, tgt.ModifiedOn = SYSUTCDATETIME()
WHEN NOT MATCHED BY TARGET
    THEN INSERT (ModuleId, Code, Name, DisplayOrder)
         VALUES (src.ModuleId, src.Code, src.Name, src.DisplayOrder);

PRINT '    m_sso_modules seeded.';
GO
