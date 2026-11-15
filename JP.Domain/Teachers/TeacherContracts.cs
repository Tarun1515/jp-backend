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

    /*
      Client instruction, 15 Nov 2026: the teacher's address carries the same
      chain the school's does — State, District, City/Town, Tehsil/Sub-tehsil,
      Area or village.

      ⚠️ DISTRICT IS STORED NOW. It used to be rebuilt in the browser from the
      saved city on every re-open, which held only because a city has one
      district — and stops holding under a tehsil, which sits between them.

      ⚠️ DELIBERATELY NOT ON TeacherBrowseDto. That is what a SCHOOL sees, and
      its procedure does not read these columns — adding them there would ship
      three fields that are always null, which is the dead-field problem this
      pass has been clearing out. A teacher's village is also a home-address
      detail a school does not need in order to decide whether to invite them.
    */
    public int? CurrentDistrictId { get; init; }
    public int? CurrentTehsilId { get; init; }
    public string? CurrentAreaOrVillage { get; init; }

    /// <summary>
    /// D1. The teacher's own map pin — where "nearby jobs first" measures from.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔒 ON THIS TYPE AND ON NO OTHER. This is what the teacher sees of their
    /// OWN profile, read through their own token. <see cref="TeacherBrowseDto"/>
    /// — what a SCHOOL sees — has no coordinate properties and must never grow
    /// any: a home address to ±11 cm is somebody's front door, and 039 already
    /// refused the teacher AddressLine1/2 and Pincode on exactly that ground
    /// while a school's address is published on every advert. The only thing
    /// that leaves the building is
    /// <see cref="JP.Domain.Applications.JobBrowseItemDto.DistanceMetres"/>,
    /// a scalar from an origin the reader cannot see.
    /// </para>
    /// <para>
    /// ⚠️ BOTH OR NEITHER. Half a pin is a point on the Greenwich meridian —
    /// in the Atlantic, for anything in India — so
    /// <c>USP_UpdateTeacherProfile</c> refuses one without the other and names
    /// which half is missing. The computed column (041) independently reads a
    /// half pin as no pin, so storage cannot be left inconsistent either way.
    /// </para>
    /// <para>
    /// ⚠️ NULL MEANS NOBODY ASKED, AND THERE IS NO FALLBACK. The job browse
    /// does not guess from <see cref="CurrentCityId"/>'s centroid: with no pin
    /// the list comes back in date order, unchanged, and the screen offers the
    /// map instead. 041's header argues why a guessed distance is worse than
    /// none.
    /// </para>
    /// </remarks>
    public decimal? Latitude { get; init; }

    /// <inheritdoc cref="Latitude"/>
    public decimal? Longitude { get; init; }

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

    /// <summary>
    /// Extra detail under the chosen town.
    /// </summary>
    /// <remarks>
    /// <para>
    /// 🔴 ADDED 15 Nov 2026, AND IT IS THE FIELD THAT WAS MISSING WHILE THE
    /// COLUMN EXISTED. <c>t_app_teacher_preferred_locations.TehsilId</c> has
    /// been there since 036; the <c>dbo.PreferredLocationList</c> table type
    /// had no column for it, so the picker on the teacher profile accepted a
    /// tehsil, the screen said "Saved", and the value was discarded on the way
    /// to the database.
    /// </para>
    /// <para>
    /// ⚠️ NOT PART OF THE PLACE'S IDENTITY. A town belongs to exactly one
    /// tehsil, so two rows differing only by tehsil would be nonsense rather
    /// than two preferences. The procedure matches on (CityId, StateId) with
    /// NULL-equality and UPDATES this in place, exactly as it does
    /// PreferenceOrder.
    /// </para>
    /// </remarks>
    public int? TehsilId { get; init; }
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

    /*
      The other three levels of the chain (15 Nov 2026). All optional, like
      every other field here — a teacher who filled their address in before
      today sends null, which is the honest value rather than a reason to
      refuse their save.
    */
    public int? CurrentDistrictId { get; init; }
    public int? CurrentTehsilId { get; init; }
    public string? CurrentAreaOrVillage { get; init; }

    /// <summary>D1. The map pin. Optional, like everything else here.</summary>
    /// <remarks>
    /// <para>
    /// 🔴 THE PROCEDURE WRITES THIS PLAINLY — IT DOES NOT COALESCE. Sending
    /// null CLEARS the pin, because "remove my home coordinates" has to be a
    /// request this product can honour. <c>USP_SaveBranch</c>'s geocoded anchor
    /// does the opposite (null keeps what is stored) and the difference is
    /// deliberate: a campus edit must not un-geocode an address, while this
    /// form sends the whole profile row on every save.
    /// </para>
    /// <para>
    /// ⚠️ WHICH MAKES THE CLIENT RESPONSIBLE FOR ROUND-TRIPPING IT. The teacher
    /// profile screen has nine section Save buttons over ONE row, and each one
    /// PUTs the whole draft. A section that forgot this field would silently
    /// delete somebody's pin while showing "Saved" — the exact failure the
    /// tehsil picker had in reverse. <c>nearby-jobs.mjs</c> asserts the round
    /// trip.
    /// </para>
    /// <para>
    /// ⚠️ BOTH OR NEITHER, AND THE RANGES ARE CHECKED. The procedure refuses
    /// one coordinate without the other, and a latitude outside −90..90 or a
    /// longitude outside −180..180 — the refusal names the likely cause, which
    /// is the two boxes being swapped.
    /// </para>
    /// </remarks>
    public decimal? Latitude { get; init; }

    /// <inheritdoc cref="Latitude"/>
    public decimal? Longitude { get; init; }

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

/// <summary>
/// Whether this teacher can ask to be verified, and what to say when they
/// cannot.
/// </summary>
/// <remarks>
/// <para>
/// 🔒 NO IDENTITY NUMBER CROSSES THIS BOUNDARY (2.50). MissingDocument is a
/// document type's NAME, read from m_mdm_document_types. There is deliberately
/// no field here — and no column under it — that could carry an Aadhaar or PAN
/// number. The document is the record; an admin's eyes verify it.
/// </para>
/// <para>
/// ⚠️ CanRequest IS COMPUTED ON THE SERVER, not inferred in the browser from the
/// other three. The screen should not have to re-derive a rule, and the server's
/// answer is the one the endpoint will actually enforce.
/// </para>
/// </remarks>
public sealed record TeacherVerificationReadinessDto
{
    /// <summary>Already carries the badge — asking again is refused.</summary>
    public bool IsVerified { get; init; }

    /// <summary>Verification documents on the profile, of any type.</summary>
    public int DocumentCount { get; init; }

    /// <summary>
    /// The first mandatory document with nothing uploaded against it, in the
    /// order the teacher sees them. Null when the profile is complete.
    /// </summary>
    public string? MissingDocument { get; init; }

    /// <summary>Not verified yet, and nothing mandatory is missing.</summary>
    public bool CanRequest { get; init; }
}
