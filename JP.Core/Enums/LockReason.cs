namespace JP.Core.Enums;

/// <summary>Mirrors <c>m_sso_lock_reasons</c>.</summary>
public enum LockReason
{
    /// <summary>Automatic, after too many failed logins. Self-clearing.</summary>
    FailedAttempts = 1,

    /// <summary>Deliberate admin action. Requires an admin to lift it.</summary>
    AdminSuspend = 2,
}
