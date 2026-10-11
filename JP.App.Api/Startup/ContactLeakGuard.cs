using System.Reflection;
using JP.Domain.Invites;
using JP.Domain.Teachers;

namespace JP.App.Api.Startup;

/// <summary>
/// Refuses to start if any school-facing teacher shape has grown a contact field.
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
/// <para>
/// 🔴 PHASE 6B WIDENED THE SET IT CHECKS, because 6B widened the exposure.
/// Until then one type — the browse profile — was all a school could see of a
/// teacher it had no consent from. Search changed that: a school can now page
/// through the WHOLE teacher base, and an invitation list carries a teacher
/// summary too. So <see cref="TeacherSearchResultDto"/> and
/// <see cref="SchoolInviteDto"/> are checked alongside it.
/// </para>
/// <para>
/// ⚠️ And the risk is strictly worse on those two. Every row on an applicant
/// list has consented, so a contact column there would break the SHAPE rule
/// without breaking 2.56. In a search result almost nobody has consented: one
/// property would leak every teacher on the platform at once, to any school
/// that typed a filter.
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
    /// Every school-facing shape that describes a teacher without consent.
    /// </summary>
    /// <remarks>
    /// ⚠️ ADDING A SHAPE HERE IS CHEAPER THAN REMEMBERING TO. A new
    /// school-facing teacher projection that is not on this list is guarded by
    /// nothing but the comments on it.
    /// </remarks>
    private static readonly Type[] Guarded =
    [
        typeof(TeacherBrowseDto),
        typeof(TeacherSearchResultDto),
        typeof(SchoolInviteDto),
    ];

    /// <summary>
    /// Throws if any guarded shape declares a forbidden property.
    /// </summary>
    /// <exception cref="InvalidOperationException">
    /// A contact-shaped property is present. The message names the type and the
    /// property.
    /// </exception>
    public static void Verify()
    {
        var offenders = Guarded
            .SelectMany(type => type
                .GetProperties(BindingFlags.Public | BindingFlags.Instance)
                .Select(p => p.Name)
                .Where(name => Forbidden.Any(f => name.Contains(f, StringComparison.OrdinalIgnoreCase)))
                .Select(name => $"{type.Name}.{name}"))
            .ToList();

        if (offenders.Count == 0)
        {
            return;
        }

        throw new InvalidOperationException(
            $"{string.Join(", ", offenders)} — a school seeing a teacher it has no consent from must never " +
            "receive any of these. Contact details and the resume are gated behind " +
            "GET /api/teachers/{uid}/contact, which unlocks only when the teacher applied to that school or " +
            "accepted its invitation (PROJECT_MEMORY 2.56, LOCKED). " +
            "If you need one of those values, use the contact endpoint — do not widen these types. " +
            "This check lives in JP.App.Api/Startup/ContactLeakGuard.cs.");
    }
}
