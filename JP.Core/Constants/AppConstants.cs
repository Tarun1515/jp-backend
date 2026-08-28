namespace JP.Core.Constants;

/// <summary>Cross-cutting values that are policy, not configuration.</summary>
public static class AppConstants
{
    /// <summary>Password hashing defaults.</summary>
    /// <remarks>
    /// These are the values used when hashing a NEW password. Verification
    /// always reads the algorithm id and iteration count stored alongside the
    /// hash in <c>t_sso_user_credentials</c>, so raising
    /// <see cref="Pbkdf2Iterations"/> later re-hashes new passwords more
    /// strongly without invalidating a single existing one.
    /// </remarks>
    public static class Password
    {
        public const int Pbkdf2Iterations = 210_000;

        /// <summary>Matches <c>t_sso_user_credentials.PasswordSalt varbinary(32)</c>.</summary>
        public const int SaltBytes = 32;

        /// <summary>Matches <c>t_sso_user_credentials.PasswordHash varbinary(64)</c>.</summary>
        public const int HashBytes = 64;

        /// <summary>How many previous passwords may not be reused.</summary>
        public const int HistoryDepth = 3;

        /// <summary>
        /// Shortest accepted password. Exposed so FluentValidation rules and the
        /// Angular form validators state the same number the hasher enforces.
        /// </summary>
        public const int MinLength = 8;

        /// <summary>
        /// Longest accepted password.
        /// </summary>
        /// <remarks>
        /// This is a denial-of-service control, not a usability preference.
        /// PBKDF2 cost scales with input length, and login is a public,
        /// unauthenticated endpoint — an uncapped input lets a few requests
        /// carrying megabyte-sized "passwords" saturate every core. 128
        /// characters is far beyond any real passphrase.
        /// </remarks>
        public const int MaxLength = 128;

        /// <summary>
        /// Refuse to verify a credential row claiming more iterations than this.
        /// </summary>
        /// <remarks>
        /// Verification uses the iteration count stored with the credential, so
        /// a tampered or corrupt row could otherwise turn a single login attempt
        /// into an arbitrarily expensive operation. Set well above
        /// <see cref="Pbkdf2Iterations"/> to leave room for future increases.
        /// </remarks>
        public const int MaxVerifyIterations = 2_000_000;
    }

    /// <summary>Login lockout policy, enforced in <c>USP_RecordLoginAttempt</c>.</summary>
    public static class Lockout
    {
        public const int MaxFailedAttempts = 5;
        public const int LockoutMinutes = 30;
    }

    /// <summary>One-time password policy.</summary>
    public static class Otp
    {
        public const int Length = 6;
        public const int ValidityMinutes = 10;
        public const int MaxVerifyAttempts = 5;
    }

    /// <summary>Token lifetimes. Overridable per environment via JwtOptions.</summary>
    public static class Tokens
    {
        public const int AccessTokenMinutes = 60;
        public const int RefreshTokenDays = 7;
        public const int PasswordResetMinutes = 30;
        public const int InviteValidityDays = 7;

        /// <summary>Entropy of a refresh / reset token before hashing.</summary>
        public const int RandomTokenBytes = 64;
    }

    /// <summary>Paging defaults applied to every list endpoint.</summary>
    public static class Paging
    {
        public const int DefaultPageNumber = 1;
        public const int DefaultPageSize = 20;

        /// <summary>Hard ceiling. A caller asking for more is clamped, not refused.</summary>
        public const int MaxPageSize = 200;
    }

    /// <summary>Named connection strings. Must match the keys in appsettings.json.</summary>
    public static class ConnectionNames
    {
        public const string Sso = "Sso";
        public const string Mdm = "Mdm";
        public const string App = "App";
    }

    /// <summary>
    /// Seeded permission codes.
    /// </summary>
    /// <remarks>
    /// These match t_sso_permissions.Code exactly. A permission checked with a
    /// string literal at the call site is one nobody can find when the code is
    /// renamed, and one a typo turns into a silent allow-nobody.
    /// </remarks>
    public static class PermissionCodes
    {
        public const string VerificationSchool = "VERIFICATION.SCHOOL";
        public const string VerificationTeacher = "VERIFICATION.TEACHER";

        /*
          Job permissions — seeded in Phase 1A, and the SEED is the authority on
          who holds them (Phase 4).

          🔴 As seeded: HR has Create, Edit and View; Owner and Senior HR have
          all five; Viewer has View only. So an HR prepares drafts and somebody
          senior publishes them. Nothing in the code re-decides that — a
          hard-coded role check would be a second answer to a question the
          database already answers, and the two would drift.
        */
        public const string JobView = "JOB.VIEW";
        public const string JobCreate = "JOB.CREATE";
        public const string JobEdit = "JOB.EDIT";
        public const string JobPublish = "JOB.PUBLISH";
        public const string JobClose = "JOB.CLOSE";

        /// <summary>
        /// Seeded in Phase 1A, held by SUPER_ADMIN alone. Phase 2.5 gates the
        /// plan × feature matrix on it rather than seeding a new permission —
        /// deciding what a plan includes IS a system setting, and a permission
        /// nobody has yet would need a role grant before the screen could be
        /// opened at all.
        /// </summary>
        public const string SettingsManage = "SETTINGS.MANAGE";
    }

    /// <summary>Seeded role codes. See DB_TABLE_STRUCTURE.md.</summary>
    public static class RoleCodes
    {
        public const string SuperAdmin = "SUPER_ADMIN";
        public const string VerificationAdmin = "VERIFICATION_ADMIN";
        public const string ModerationAdmin = "MODERATION_ADMIN";
        public const string SchoolOwner = "SCHOOL_OWNER";
        public const string SeniorHr = "SENIOR_HR";
        public const string Hr = "HR";
        public const string SchoolViewer = "SCHOOL_VIEWER";
        public const string Teacher = "TEACHER";
    }
}
