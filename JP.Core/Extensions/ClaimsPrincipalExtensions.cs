using System.Security.Claims;
using JP.Core.Constants;
using JP.Core.Enums;
using JP.Core.Exceptions;

namespace JP.Core.Extensions;

/// <summary>
/// Reads the JWT claims that identity and tenancy decisions are made from.
/// </summary>
/// <remarks>
/// This type exists to make the right thing the easy thing. Every org-scoped
/// query must take its OrganizationUid from the token, never from the request
/// body — <see cref="RequireOrganizationUid"/> is one call, so there is no
/// temptation to read it off a DTO instead.
/// </remarks>
public static class ClaimsPrincipalExtensions
{
    /// <summary><c>t_sso_users.UserId</c>. Throws if the token lacks it.</summary>
    public static long GetUserId(this ClaimsPrincipal principal)
    {
        ArgumentNullException.ThrowIfNull(principal);

        var raw = principal.FindFirst(JpClaimTypes.UserId)?.Value;
        if (!long.TryParse(raw, out var userId))
        {
            throw new AppException("The access token is missing a valid user id.",
                ErrorCodes.TokenInvalid, System.Net.HttpStatusCode.Unauthorized);
        }

        return userId;
    }

    /// <summary><c>t_sso_users.UserUid</c> — the public identifier. Throws if absent.</summary>
    public static Guid GetUserUid(this ClaimsPrincipal principal)
    {
        ArgumentNullException.ThrowIfNull(principal);

        var raw = principal.FindFirst(JpClaimTypes.UserUid)?.Value;
        if (!Guid.TryParse(raw, out var userUid))
        {
            throw new AppException("The access token is missing a valid user uid.",
                ErrorCodes.TokenInvalid, System.Net.HttpStatusCode.Unauthorized);
        }

        return userUid;
    }

    public static UserType GetUserType(this ClaimsPrincipal principal)
    {
        ArgumentNullException.ThrowIfNull(principal);

        var raw = principal.FindFirst(JpClaimTypes.UserType)?.Value;
        if (!int.TryParse(raw, out var value) || !Enum.IsDefined(typeof(UserType), value))
        {
            throw new AppException("The access token is missing a valid user type.",
                ErrorCodes.TokenInvalid, System.Net.HttpStatusCode.Unauthorized);
        }

        return (UserType)value;
    }

    /// <summary>
    /// Account status as at token issue. Deliberately a snapshot: a status
    /// change takes effect for the user when their access token next refreshes.
    /// </summary>
    public static UserStatus GetStatus(this ClaimsPrincipal principal)
    {
        ArgumentNullException.ThrowIfNull(principal);

        var raw = principal.FindFirst(JpClaimTypes.Status)?.Value;
        if (!int.TryParse(raw, out var value) || !Enum.IsDefined(typeof(UserStatus), value))
        {
            throw new AppException("The access token is missing a valid account status.",
                ErrorCodes.TokenInvalid, System.Net.HttpStatusCode.Unauthorized);
        }

        return (UserStatus)value;
    }

    /// <summary>
    /// The caller's tenant, or <see langword="null"/> for users who have none
    /// (admins, and teachers — a teacher belongs to no organisation).
    /// </summary>
    public static Guid? GetOrganizationUid(this ClaimsPrincipal principal)
    {
        ArgumentNullException.ThrowIfNull(principal);

        var raw = principal.FindFirst(JpClaimTypes.OrganizationUid)?.Value;
        return Guid.TryParse(raw, out var organizationUid) ? organizationUid : null;
    }

    /// <summary>
    /// The caller's tenant, refusing the request if there isn't one.
    /// </summary>
    /// <remarks>
    /// Use this in every school-scoped list, detail, create and update path.
    /// It is the IDOR defence: the value can only come from the signed token,
    /// so a caller cannot widen their own scope by editing a payload.
    /// </remarks>
    /// <exception cref="ForbiddenException">The token carries no organisation.</exception>
    public static Guid RequireOrganizationUid(this ClaimsPrincipal principal)
    {
        return principal.GetOrganizationUid()
            ?? throw new ForbiddenException("This account is not linked to an organisation.");
    }

    /// <summary>Role codes such as <c>SCHOOL_OWNER</c>.</summary>
    public static IReadOnlyList<string> GetRoles(this ClaimsPrincipal principal)
    {
        ArgumentNullException.ThrowIfNull(principal);

        return principal.FindAll(JpClaimTypes.Roles)
            .Select(c => c.Value)
            .ToList();
    }

    /// <summary>Permission codes such as <c>JOB.CREATE</c>.</summary>
    public static IReadOnlyList<string> GetPermissions(this ClaimsPrincipal principal)
    {
        ArgumentNullException.ThrowIfNull(principal);

        return principal.FindAll(JpClaimTypes.Permissions)
            .Select(c => c.Value)
            .ToList();
    }

    /// <summary>Whether the caller holds a given permission code.</summary>
    public static bool HasPermission(this ClaimsPrincipal principal, string permissionCode)
    {
        ArgumentNullException.ThrowIfNull(principal);

        return principal.FindAll(JpClaimTypes.Permissions)
            .Any(c => string.Equals(c.Value, permissionCode, StringComparison.OrdinalIgnoreCase));
    }

    /// <summary>Whether the caller holds at least one of the given role codes.</summary>
    public static bool IsInAnyRole(this ClaimsPrincipal principal, params string[] roleCodes)
    {
        ArgumentNullException.ThrowIfNull(principal);
        ArgumentNullException.ThrowIfNull(roleCodes);

        var held = principal.GetRoles();
        return roleCodes.Any(required =>
            held.Any(h => string.Equals(h, required, StringComparison.OrdinalIgnoreCase)));
    }
}
