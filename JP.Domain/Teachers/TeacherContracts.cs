namespace JP.Domain.Teachers;

/// <summary>
/// The teacher's own view of their profile.
/// </summary>
/// <remarks>
/// 🔴 There is no TeacherId on any REQUEST type in this file. Phase 3D built
/// the procedures so that "edit somebody else's profile" cannot be EXPRESSED —
/// none of them takes a teacher id, verified against sys.parameters — and
/// accepting one here would reintroduce at the API layer exactly what the
/// database refuses to offer.
/// </remarks>
public sealed record TeacherProfileDto
{
    public long TeacherId { get; init; }
    public Guid TeacherUid { get; init; }

    public string FullName { get; init; } = string.Empty;
    public string? PhotoPath { get; init; }
    public DateOnly? Dob { get; init; }
    public int? GenderId { get; init; }
    public int? QualificationId { get; init; }
    public string? HighestQualificationText { get; init; }
    public int? DesignationId { get; init; }
    public int? TotalExperienceMonths { get; init; }
    public string? CurrentSchool { get; init; }
    public string? LastSchool { get; init; }
    public decimal? ExpectedSalaryMin { get; init; }
    public decimal? ExpectedSalaryMax { get; init; }
    public int? CurrentCityId { get; init; }
    public int? CurrentStateId { get; init; }
    public string? AboutMe { get; init; }
    public string? ResumePath { get; init; }

    public bool IsVerified { get; init; }
    public DateTime? VerifiedOn { get; init; }
    public bool IsSuspended { get; init; }
    public byte ProfileCompletionPercent { get; init; }
    public int RowVersion { get; init; }

    public IReadOnlyList<int> SubjectIds { get; init; } = [];
    public IReadOnlyList<int> ClassLevelIds { get; init; } = [];
    public IReadOnlyList<int> SkillIds { get; init; } = [];
    public IReadOnlyList<TeacherLanguageDto> Languages { get; init; } = [];
    public IReadOnlyList<TeacherLocationDto> PreferredLocations { get; init; } = [];
    public IReadOnlyList<TeacherExperienceDto> Experiences { get; init; } = [];
    public IReadOnlyList<TeacherDocumentDto> Documents { get; init; } = [];
}

/*==============================================================================
  🔴 THE BROWSE DTO — THE SECURITY SURFACE OF THIS PHASE
==============================================================================*/

/// <summary>
/// What a SCHOOL sees while browsing the teacher database.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 THIS TYPE HAS NO ContactEmail, NO ContactMobile AND NO ResumePath — not
/// null, ABSENT. Do not add them. If you are here because you need one of them,
/// the endpoint you want is <c>GET /api/teachers/{uid}/contact</c>, which is
/// gated by the teacher's consent (decision 2.56, LOCKED).
/// </para>
/// <para>
/// A property that exists and is usually null is one mapper change from being
/// populated, and the change would be made by somebody who never read this
/// comment. The whole reason Phase 3D wrote two procedures instead of one with a
/// flag was to make the leak impossible rather than merely unlikely, and that
/// only survives if the API keeps them apart too.
/// </para>
/// <para>
/// ⚠️ Dob is absent as well. An age is not needed to decide whether somebody can
/// teach physics, and publishing it puts age discrimination one filter away.
/// </para>
/// <para>
/// 🔴 TWO THINGS ENFORCE THIS, because the comment above does not.
///
/// <c>JP.App.Api/Startup/ContactLeakGuard.cs</c> reflects over this type at
/// startup and REFUSES TO START if a contact-shaped property appears — so
/// widening it takes the API down on your own machine, immediately, naming the
/// property. And <c>jp-docs/scripts/verify/browse-contract.mjs</c> reads a real
/// response body as text and greps it, which catches a serialiser or mapper
/// adding a field this type never declared.
/// </para>
/// </remarks>
public sealed record TeacherBrowseDto
{
    public Guid TeacherUid { get; init; }
    public string FullName { get; init; } = string.Empty;
    public string? PhotoPath { get; init; }
    public int? GenderId { get; init; }
    public int? QualificationId { get; init; }
    public string? HighestQualificationText { get; init; }
    public int? DesignationId { get; init; }
    public int? TotalExperienceMonths { get; init; }
    public string? CurrentSchool { get; init; }
    public string? LastSchool { get; init; }
    public decimal? ExpectedSalaryMin { get; init; }
    public decimal? ExpectedSalaryMax { get; init; }
    public int? CurrentCityId { get; init; }
    public int? CurrentStateId { get; init; }
    public string? AboutMe { get; init; }
    public bool IsVerified { get; init; }
    public byte ProfileCompletionPercent { get; init; }

    public IReadOnlyList<int> SubjectIds { get; init; } = [];
    public IReadOnlyList<int> ClassLevelIds { get; init; } = [];
    public IReadOnlyList<int> SkillIds { get; init; } = [];
    public IReadOnlyList<TeacherLanguageDto> Languages { get; init; } = [];
    public IReadOnlyList<TeacherLocationDto> PreferredLocations { get; init; } = [];
    public IReadOnlyList<TeacherExperiencePublicDto> Experiences { get; init; } = [];

    /// <summary>
    /// The FACT that a document exists and was verified — never the file.
    /// </summary>
    /// <remarks>
    /// "Somebody checked this" is what a school wants from a document it is not
    /// qualified to authenticate anyway. The path is not here and there is no
    /// endpoint that will serve it to a school.
    /// </remarks>
    public IReadOnlyList<TeacherDocumentBadgeDto> Documents { get; init; } = [];
}

/// <summary>
/// A teacher's contact details — the ONLY type in this system that carries them
/// to a school.
/// </summary>
/// <remarks>
/// 🔴 Returned exclusively by <c>GET /api/teachers/{uid}/contact</c>, which
/// refuses unless the teacher applied to this school or accepted its invite
/// (2.56, LOCKED).
///
/// ResumePath travels with the phone number because it IS a contact detail: a
/// resume carries an email and a mobile in its first three lines, so serving the
/// file while withholding the columns would be theatre.
/// </remarks>
public sealed record TeacherContactDto
{
    public Guid TeacherUid { get; init; }
    public string FullName { get; init; } = string.Empty;
    public string? ContactEmail { get; init; }
    public string? ContactMobile { get; init; }
    public string? ResumePath { get; init; }
}

public sealed record TeacherLanguageDto
{
    public int LanguageId { get; init; }

    /// <summary>1 basic · 2 conversational · 3 fluent · 4 native.</summary>
    public byte? ProficiencyLevel { get; init; }
}

public sealed record TeacherLocationDto
{
    /// <summary>⚠️ Null means "anywhere in this state" — a real preference (2.47).</summary>
    public int? CityId { get; init; }

    public int StateId { get; init; }
    public int PreferenceOrder { get; init; }
}

public sealed record TeacherExperienceDto
{
    public long Id { get; init; }
    public string SchoolName { get; init; } = string.Empty;
    public int? DesignationId { get; init; }
    public int? SubjectId { get; init; }
    public DateOnly FromDate { get; init; }
    public DateOnly? ToDate { get; init; }
    public bool IsCurrent { get; init; }
}

/// <summary>The same career, without the row id a school has no use for.</summary>
public sealed record TeacherExperiencePublicDto
{
    public string SchoolName { get; init; } = string.Empty;
    public int? DesignationId { get; init; }
    public int? SubjectId { get; init; }
    public DateOnly FromDate { get; init; }
    public DateOnly? ToDate { get; init; }
    public bool IsCurrent { get; init; }
}

public sealed record TeacherDocumentDto
{
    public long DocumentId { get; init; }
    public int DocumentTypeId { get; init; }
    public string FileName { get; init; } = string.Empty;
    public int FileSizeKb { get; init; }
    public string MimeType { get; init; } = string.Empty;
    public bool IsVerified { get; init; }
    public DateTime? VerifiedOn { get; init; }
    public DateTime CreatedOn { get; init; }
}

/// <summary>The badge, not the document. No id, no filename, no path.</summary>
public sealed record TeacherDocumentBadgeDto
{
    public int DocumentTypeId { get; init; }
    public bool IsVerified { get; init; }
}

// =============================================================================
// REQUESTS — none of them carries a teacher id
// =============================================================================

public sealed record UpdateTeacherProfileRequest
{
    public int RowVersion { get; init; }

    public string FullName { get; init; } = string.Empty;
    public DateOnly? Dob { get; init; }
    public int? GenderId { get; init; }
    public int? QualificationId { get; init; }
    public string? HighestQualificationText { get; init; }
    public int? DesignationId { get; init; }
    public string? CurrentSchool { get; init; }
    public string? LastSchool { get; init; }
    public decimal? ExpectedSalaryMin { get; init; }
    public decimal? ExpectedSalaryMax { get; init; }
    public int? CurrentCityId { get; init; }
    public int? CurrentStateId { get; init; }
    public string? AboutMe { get; init; }
}

/// <remarks>
/// ⚠️ FULL SET, NOT A DELTA. The procedure diffs against what is stored and
/// soft-deletes anything absent (2.53, 2.54). Sending only the new id removes
/// every other one.
/// </remarks>
public sealed record SaveIdSetRequest
{
    public IReadOnlyList<int> Ids { get; init; } = [];
}

/// <remarks>⚠️ Full set. A language whose level changed is updated in place.</remarks>
public sealed record SaveLanguagesRequest
{
    public IReadOnlyList<TeacherLanguageDto> Languages { get; init; } = [];
}

/// <remarks>⚠️ Full set, keyed on (CityId, StateId) with NULL-equality (3A).</remarks>
public sealed record SavePreferredLocationsRequest
{
    public IReadOnlyList<TeacherLocationDto> Locations { get; init; } = [];
}

/// <remarks>
/// ⚠️ NOT a set sync. Experiences are entities the teacher edits individually —
/// two roles at one school starting the same month are legitimate, which is why
/// 3A gave the table no unique index (2.51).
/// </remarks>
public sealed record SaveExperienceRequest
{
    public string SchoolName { get; init; } = string.Empty;
    public int? DesignationId { get; init; }
    public int? SubjectId { get; init; }
    public DateOnly FromDate { get; init; }
    public DateOnly? ToDate { get; init; }
    public bool IsCurrent { get; init; }
}
