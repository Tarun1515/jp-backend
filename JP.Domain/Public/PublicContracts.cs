namespace JP.Domain.Public;

/// <summary>
/// One job as the PUBLIC listing shows it. Phase 7A.
/// </summary>
/// <remarks>
/// <para>
/// 🔒 WHAT IS ABSENT IS THE CONTRACT. No teacher field, no application count,
/// no saved flag, no plan, no quota, no entitlement, and none of the school's
/// private contact details. The raw-bytes sweep asserts that over the wire
/// rather than trusting this list, because a field added to a nested type
/// would not show up in a reading of this file.
/// </para>
/// <para>
/// 🔴 A SEPARATE TYPE FROM THE TEACHER'S JOB CARD, deliberately. Sharing one
/// would mean the public contract changing whenever the authenticated one
/// does — additively and silently, which is the whole reason 024 is not
/// <c>USP_BrowseJobs</c> with a null caller.
/// </para>
/// <para>
/// ⚠️ <c>CityName</c> is null until the city master is seeded (G40). State is
/// seeded and carries the location on the card meanwhile.
/// </para>
/// </remarks>
public sealed class PublicJobCardDto
{
    /// <summary>
    /// 🔴 The Uid, never the id (2.39). An incrementing integer in a public URL
    /// tells a competitor how many jobs exist and how fast that grows.
    /// </summary>
    public Guid JobUid { get; set; }

    public string JobTitle { get; set; } = string.Empty;

    public int? SubjectId { get; set; }

    public string? SubjectName { get; set; }

    public int? DesignationId { get; set; }

    public string? DesignationName { get; set; }

    public int? EmploymentTypeId { get; set; }

    public string? EmploymentTypeName { get; set; }

    public int? NoOfVacancies { get; set; }

    public int? MinExperienceMonths { get; set; }

    public int? MaxExperienceMonths { get; set; }

    public decimal? SalaryMin { get; set; }

    public decimal? SalaryMax { get; set; }

    public bool IsSalaryNegotiable { get; set; }

    public int? CityId { get; set; }

    public string? CityName { get; set; }

    public int? StateId { get; set; }

    public string? StateName { get; set; }

    public DateTime? LastDateToApply { get; set; }

    public DateTime? PublishedOn { get; set; }

    public Guid SchoolUid { get; set; }

    public string SchoolName { get; set; } = string.Empty;

    public string? SchoolLogoPath { get; set; }

    /// <summary>
    /// The badge. 🔒 Soft verification stays soft (2.9): an unverified school's
    /// jobs are listed exactly the same, and this is a signal rather than a
    /// gate.
    /// </summary>
    public bool IsSchoolVerified { get; set; }
}

/// <summary>One job in full, as the public detail page shows it.</summary>
/// <remarks>
/// 🔒 The school's PUBLIC profile summary travels with it — identity and
/// description, NOT <c>ContactEmail</c> or <c>ContactMobile</c>, although both
/// exist on the table and the brief would permit them. A phone number on an
/// anonymous page is scraped within a day, and it routes applications AROUND
/// the platform — and the application is consent path 1 (2.56). Website is
/// included: a school's own site is public by nature and bypasses nothing.
/// </remarks>
public sealed class PublicJobDetailDto
{
    public Guid JobUid { get; set; }

    public string JobTitle { get; set; } = string.Empty;

    public string? JobDescription { get; set; }

    public int? SubjectId { get; set; }

    public string? SubjectName { get; set; }

    public int? DesignationId { get; set; }

    public string? DesignationName { get; set; }

    public int? QualificationId { get; set; }

    public string? QualificationName { get; set; }

    public int? EmploymentTypeId { get; set; }

    public string? EmploymentTypeName { get; set; }

    public int? NoOfVacancies { get; set; }

    public int? MinExperienceMonths { get; set; }

    public int? MaxExperienceMonths { get; set; }

    public decimal? SalaryMin { get; set; }

    public decimal? SalaryMax { get; set; }

    public bool IsSalaryNegotiable { get; set; }

    public int? CityId { get; set; }

    public string? CityName { get; set; }

    public int? StateId { get; set; }

    public string? StateName { get; set; }

    public DateTime? LastDateToApply { get; set; }

    public DateTime? ExpectedJoiningDate { get; set; }

    public DateTime? PublishedOn { get; set; }

    public Guid SchoolUid { get; set; }

    public string SchoolName { get; set; } = string.Empty;

    public string? SchoolLogoPath { get; set; }

    public bool IsSchoolVerified { get; set; }

    public string? AboutSchool { get; set; }

    public string? Website { get; set; }

    public short? EstablishedYear { get; set; }

    public int? SchoolTypeId { get; set; }

    public string? SchoolTypeName { get; set; }

    public int? BoardId { get; set; }

    public string? BoardName { get; set; }

    public string? BranchName { get; set; }

    public string? BranchCityName { get; set; }

    /// <summary>
    /// The levels this job teaches. A job teaching three is three entries —
    /// flattening them into a string would be a display decision made in SQL.
    /// </summary>
    public IReadOnlyList<PublicClassLevelDto> ClassLevels { get; set; } = [];
}

public sealed class PublicClassLevelDto
{
    public int ClassLevelId { get; set; }

    public string ClassLevelName { get; set; } = string.Empty;
}

/// <summary>
/// What the listing may be filtered by — and only values that can return a job.
/// </summary>
/// <remarks>
/// ⚠️ REACHABLE ROWS ONLY, the same discipline the app-master whitelist keeps.
/// A filter offering forty subjects of which thirty-eight produce an empty page
/// reads as a broken product rather than a narrow filter.
///
/// ⚠️ <see cref="Cities"/> is empty until the city master is seeded (G40), and
/// the UI renders no city control when it is — which is the intended shape, not
/// a missing feature.
/// </remarks>
public sealed class PublicJobFiltersDto
{
    public IReadOnlyList<PublicFilterOptionDto> Subjects { get; set; } = [];

    public IReadOnlyList<PublicFilterOptionDto> Cities { get; set; } = [];

    public IReadOnlyList<PublicFilterOptionDto> States { get; set; } = [];

    public IReadOnlyList<PublicFilterOptionDto> ClassLevels { get; set; } = [];
}

/// <summary>One filter option, with how many live jobs it would return.</summary>
public sealed class PublicFilterOptionDto
{
    public int Id { get; set; }

    public string Name { get; set; } = string.Empty;

    public int JobCount { get; set; }
}

/// <summary>One FAQ, grouped by audience on the page.</summary>
public sealed class PublicFaqDto
{
    public int FaqId { get; set; }

    /// <summary>TEACHER · SCHOOL · GENERAL. A code, not a free string.</summary>
    public string Category { get; set; } = string.Empty;

    public string Question { get; set; } = string.Empty;

    public string Answer { get; set; } = string.Empty;

    public int DisplayOrder { get; set; }
}

/// <summary>One designated content block, addressed by the key a template names.</summary>
public sealed class PublicContentBlockDto
{
    public string BlockKey { get; set; } = string.Empty;

    public string? BlockTitle { get; set; }

    public string BlockContent { get; set; } = string.Empty;

    public string? ImagePath { get; set; }

    public int DisplayOrder { get; set; }
}

/// <summary>What the contact form sends.</summary>
/// <remarks>
/// 🔴 <see cref="Website"/> IS THE HONEYPOT, and its name is the point: a bot
/// filling in every field it can see fills this one, a person never sees it.
/// A field called <c>Honeypot</c> would be skipped by anything that reads the
/// markup.
///
/// ⚠️ A filled honeypot returns <c>200</c> and writes NOTHING. Telling the bot
/// it was detected teaches whoever wrote it to stop filling that field.
/// </remarks>
public sealed class ContactEnquiryRequest
{
    public string Name { get; set; } = string.Empty;

    public string Email { get; set; } = string.Empty;

    public string? Mobile { get; set; }

    public string Subject { get; set; } = string.Empty;

    public string Message { get; set; } = string.Empty;

    /// <summary>🔴 The honeypot. See the remarks on this type.</summary>
    public string? Website { get; set; }
}
