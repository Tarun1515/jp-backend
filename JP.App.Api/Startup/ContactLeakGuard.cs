using System.Reflection;
using JP.Domain.Teachers;

namespace JP.App.Api.Startup;

/// <summary>
/// Refuses to start if the browse DTO has grown a contact field.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 THE GUARD THAT SURVIVES SOMEBODY NOT READING THE COMMENTS.
/// </para>
/// <para>
/// <see cref="TeacherBrowseDto"/> is what a school sees while browsing, and it
/// must never carry an email, a mobile number, a resume path or a date of birth
/// (decisions 2.54 and 2.56). Those are gated behind
/// <c>GET /api/teachers/{uid}/contact</c>, which unlocks only on the teacher's
/// own consent.
/// </para>
/// <para>
/// The comments on that type say so. Comments do not fail a build.
/// </para>
/// <para>
/// This does. It runs once at startup, reflects over the type, and throws if a
/// forbidden property has appeared — so widening the DTO takes the API down on
/// the developer's own machine, immediately, with a message naming the property
/// and the decision it breaks.
/// </para>
/// <para>
/// ⚠️ Deliberately fatal rather than a warning. A warning about a leaked phone
/// number is a warning somebody scrolls past; the failure mode being prevented
/// is silent and permanent, because a school that has already read a teacher's
/// number cannot be made to un-read it.
/// </para>
/// <para>
/// The complementary check is at the HTTP level in
/// <c>jp-docs/scripts/verify/browse-contract.mjs</c>, which reads a real
/// response body as text and greps it. This one catches the type; that one
/// catches a serialiser or mapper that adds a field the type never declared.
/// </para>
/// </remarks>
internal static class ContactLeakGuard
{
    /// <summary>
    /// Property names that must never exist on the browse shape.
    /// </summary>
    /// <remarks>
    /// Matched case-insensitively and by prefix where it helps — "Contact"
    /// catches ContactEmail, ContactMobile and anything else somebody adds with
    /// that prefix, which is the point: the list should be hard to sneak past
    /// rather than exhaustive.
    /// </remarks>
    private static readonly string[] Forbidden =
    [
        "Contact",      // ContactEmail, ContactMobile, ContactPerson…
        "Email",
        "Mobile",
        "Phone",
        "Resume",       // ResumePath
        "Dob",
        "DateOfBirth",
        "UserUid",      // the join key to jp_sso — not a school's business
    ];

    /// <summary>
    /// Throws if <see cref="TeacherBrowseDto"/> declares a forbidden property.
    /// </summary>
    /// <exception cref="InvalidOperationException">
    /// A contact-shaped property is present. The message names it.
    /// </exception>
    public static void Verify()
    {
        var offenders = typeof(TeacherBrowseDto)
            .GetProperties(BindingFlags.Public | BindingFlags.Instance)
            .Select(p => p.Name)
            .Where(name => Forbidden.Any(f => name.Contains(f, StringComparison.OrdinalIgnoreCase)))
            .ToList();

        if (offenders.Count == 0)
        {
            return;
        }

        throw new InvalidOperationException(
            $"TeacherBrowseDto declares {string.Join(", ", offenders)}, which a school browsing the teacher " +
            "database must never receive. Contact details and the resume are gated behind " +
            "GET /api/teachers/{uid}/contact, which unlocks only when the teacher applied to that school or " +
            "accepted its invite (PROJECT_MEMORY 2.56, LOCKED). " +
            "If you need one of those values, use the contact endpoint — do not widen this type. " +
            "This check lives in JP.App.Api/Startup/ContactLeakGuard.cs.");
    }
}
