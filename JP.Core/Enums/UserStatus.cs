namespace JP.Core.Enums;

/// <summary>
/// Mirrors <c>m_sso_user_status</c>.
/// </summary>
/// <remarks>
/// Values are seeded database rows and are contract — never renumber.
/// <para>
/// Only <see cref="Active"/> passes <c>[RequireActiveAccount]</c>. Note that a
/// <see cref="PendingApproval"/> user can still log in and receives a real
/// token: schools must be able to reach the document-upload screen while they
/// wait for verification.
/// </para>
/// </remarks>
public enum UserStatus
{
    /// <summary>School signup default. Hard gate — business endpoints are blocked.</summary>
    PendingApproval = 1,

    /// <summary>Full access. Teacher signup default (soft verification).</summary>
    Active = 2,

    Rejected = 3,
    Suspended = 4,

    /// <summary>Locked by failed login attempts. Clears automatically at UnlockOn.</summary>
    Locked = 5,

    /// <summary>Verification returned the request for corrected documents.</summary>
    ResubmitRequired = 6,
}
