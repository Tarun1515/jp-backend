namespace JP.Core.Constants;

/// <summary>
/// Claim names embedded in the access token.
/// </summary>
/// <remarks>
/// Short names are used deliberately — every claim is repeated in every JWT on
/// every request, and <c>roles</c>/<c>perms</c> are multi-valued.
/// <para>
/// Both APIs must agree on these names, since JP.Sso.Api issues the token and
/// JP.App.Api consumes it.
/// </para>
/// </remarks>
public static class JpClaimTypes
{
    /// <summary>Numeric <c>t_sso_users.UserId</c>. Internal use only.</summary>
    public const string UserId = "uid";

    /// <summary>Public <c>t_sso_users.UserUid</c>. This is what APIs and URLs expose.</summary>
    public const string UserUid = "uuid";

    /// <summary>1 = Admin, 2 = School, 3 = Teacher. See <see cref="Enums.UserType"/>.</summary>
    public const string UserType = "utype";

    /// <summary>Account status at token-issue time. See <see cref="Enums.UserStatus"/>.</summary>
    public const string Status = "status";

    /// <summary>
    /// The tenant boundary. Every org-scoped query takes its OrganizationUid
    /// from this claim and never from the request body — that is the IDOR
    /// defence for the whole application.
    /// </summary>
    public const string OrganizationUid = "orgUid";

    /// <summary>Role codes, e.g. <c>SCHOOL_OWNER</c>. Multi-valued.</summary>
    public const string Roles = "roles";

    /// <summary>Permission codes, e.g. <c>JOB.CREATE</c>. Multi-valued.</summary>
    public const string Permissions = "perms";

    /// <summary>Opaque per-token id, used to tie a refresh chain together.</summary>
    public const string TokenId = "jti";
}
