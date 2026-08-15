namespace JP.Domain.Schools;

/// <summary>
/// The school's own view of itself.
/// </summary>
/// <remarks>
/// 🔴 There is no SchoolId or OrganizationUid on any REQUEST type in this file,
/// and there must never be. Both come from the caller's token and their
/// membership (decision 2.39). A client that could name its own school could
/// name somebody else's.
/// </remarks>
public sealed record SchoolProfileDto
{
    public long SchoolId { get; init; }
    public Guid SchoolUid { get; init; }
    public Guid OrganizationUid { get; init; }

    public string SchoolName { get; init; } = string.Empty;
    public int? SchoolTypeId { get; init; }
    public int? BoardId { get; init; }
    public string? AffiliationNumber { get; init; }
    public string? RegistrationNo { get; init; }
    public string? PanNumber { get; init; }
    public string? LogoPath { get; init; }
    public byte? GroupType { get; init; }
    public short? EstablishedYear { get; init; }
    public string? AboutSchool { get; init; }
    public string? Website { get; init; }
    public string? ContactEmail { get; init; }
    public string? ContactMobile { get; init; }
    public string? PrincipalName { get; init; }
    public string? HrContactName { get; init; }
    public string? HrContactMobile { get; init; }

    public string? AddressLine1 { get; init; }
    public string? AddressLine2 { get; init; }
    public int? CityId { get; init; }
    public int? DistrictId { get; init; }
    public int? StateId { get; init; }
    public string? Pincode { get; init; }

    public bool IsVerified { get; init; }
    public DateTime? VerifiedOn { get; init; }
    public bool IsSuspended { get; init; }
    public DateTime? SuspendedOn { get; init; }
    public string? SuspensionReason { get; init; }

    public int RowVersion { get; init; }
    public int BranchCount { get; init; }

    public IReadOnlyList<BranchDto> Branches { get; init; } = [];
    public IReadOnlyList<SchoolPhotoDto> Photos { get; init; } = [];
    public IReadOnlyList<int> FacilityIds { get; init; } = [];
}

/// <summary>
/// 🔴 WHAT A TEACHER SEES. A SEPARATE TYPE, NOT A FILTERED VIEW OF THE ABOVE.
/// </summary>
/// <remarks>
/// <para>
/// This mirrors the two-procedure split in the database (decision 2.53):
/// <c>USP_GetSchoolPublicProfile</c> is its own procedure rather than the
/// own-view with a flag, because a shared shape with an "isPublic" switch is one
/// forgotten column away from leaking.
/// </para>
/// <para>
/// The same argument applies here. If this were
/// <c>SchoolProfileDto</c> with some properties left null, the next person to
/// add a column to the own-view mapper would populate it here too without ever
/// seeing this comment.
/// </para>
/// <para>
/// ABSENT, each for its own reason: PanNumber (a tax identifier no teacher
/// needs), OrganizationUid (an internal key that invites enumeration),
/// SuspensionReason (an administrative note written for us), RowVersion
/// (concurrency plumbing for an editor that does not exist here), and the
/// internal contacts.
/// </para>
/// </remarks>
public sealed record SchoolPublicProfileDto
{
    public Guid SchoolUid { get; init; }
    public string SchoolName { get; init; } = string.Empty;
    public int? SchoolTypeId { get; init; }
    public int? BoardId { get; init; }
    public string? LogoPath { get; init; }
    public short? EstablishedYear { get; init; }
    public string? AboutSchool { get; init; }
    public string? Website { get; init; }

    public string? AddressLine1 { get; init; }
    public string? AddressLine2 { get; init; }
    public int? CityId { get; init; }
    public int? DistrictId { get; init; }
    public int? StateId { get; init; }
    public string? Pincode { get; init; }

    public bool IsVerified { get; init; }

    public IReadOnlyList<BranchPublicDto> Branches { get; init; } = [];
    public IReadOnlyList<SchoolPhotoPublicDto> Photos { get; init; } = [];
    public IReadOnlyList<int> FacilityIds { get; init; } = [];
}

public sealed record SchoolPhotoDto
{
    public long PhotoId { get; init; }
    public long? BranchId { get; init; }
    public string FilePath { get; init; } = string.Empty;
    public string? Caption { get; init; }
    public int DisplayOrder { get; init; }
}

/// <summary>The public shape: no ids a caller could use to address a row.</summary>
public sealed record SchoolPhotoPublicDto
{
    public string FilePath { get; init; } = string.Empty;
    public string? Caption { get; init; }
    public int DisplayOrder { get; init; }
}

public sealed record BranchDto
{
    public long BranchId { get; init; }
    public Guid BranchUid { get; init; }
    public long SchoolId { get; init; }
    public string BranchName { get; init; } = string.Empty;
    public string? BranchCode { get; init; }
    public bool IsHeadOffice { get; init; }
    public string? AddressLine1 { get; init; }
    public string? AddressLine2 { get; init; }
    public int? CityId { get; init; }
    public int? DistrictId { get; init; }
    public int? StateId { get; init; }
    public string? Pincode { get; init; }
    public decimal? Latitude { get; init; }
    public decimal? Longitude { get; init; }
    public string? ContactPerson { get; init; }
    public string? ContactEmail { get; init; }
    public string? ContactMobile { get; init; }
    public bool IsActive { get; init; }
    public int RowVersion { get; init; }
}

/// <summary>What a teacher sees of a campus: where it is, and nothing else.</summary>
public sealed record BranchPublicDto
{
    public Guid BranchUid { get; init; }
    public string BranchName { get; init; } = string.Empty;
    public string? AddressLine1 { get; init; }
    public string? AddressLine2 { get; init; }
    public int? CityId { get; init; }
    public int? DistrictId { get; init; }
    public int? StateId { get; init; }
    public string? Pincode { get; init; }
    public decimal? Latitude { get; init; }
    public decimal? Longitude { get; init; }
}

// =============================================================================
// REQUESTS
// =============================================================================

/// <remarks>
/// 🔴 No SchoolId. The school is resolved from the caller's membership
/// (decision 2.39). SchoolName, the verification flags and the suspension flags
/// are absent too — a rename changes what was verified, and suspension is an
/// administrator's decision.
/// </remarks>
public sealed record UpdateSchoolProfileRequest
{
    public int RowVersion { get; init; }

    public int? SchoolTypeId { get; init; }
    public int? BoardId { get; init; }
    public string? AffiliationNumber { get; init; }
    public string? RegistrationNo { get; init; }
    public string? PanNumber { get; init; }
    public byte? GroupType { get; init; }
    public short? EstablishedYear { get; init; }
    public string? AboutSchool { get; init; }
    public string? Website { get; init; }
    public string? ContactEmail { get; init; }
    public string? ContactMobile { get; init; }
    public string? PrincipalName { get; init; }
    public string? HrContactName { get; init; }
    public string? HrContactMobile { get; init; }
    public string? AddressLine1 { get; init; }
    public string? AddressLine2 { get; init; }
    public int? CityId { get; init; }
    public int? DistrictId { get; init; }
    public int? StateId { get; init; }
    public string? Pincode { get; init; }
}

/// <summary>
/// The complete desired set of facilities.
/// </summary>
/// <remarks>
/// ⚠️ FULL SET, NOT A DELTA. The procedure diffs against what is stored and
/// soft-deletes anything absent here (decision 2.53). Sending only the new
/// facility removes every other one.
/// </remarks>
public sealed record SaveFacilitiesRequest
{
    public long? BranchId { get; init; }
    public IReadOnlyList<int> FacilityIds { get; init; } = [];
}

public sealed record ReorderPhotosRequest
{
    /// <summary>
    /// Photo ids in their new order — position 1 first.
    /// </summary>
    /// <remarks>
    /// ⚠️ The ORDER OF THIS ARRAY is the data. It used to be sent to a procedure
    /// that sorted by the id value instead, so every reorder quietly wrote
    /// insertion order and reported success; 3F found it by asking for c, a, b
    /// and getting a, b, c. The position is now explicit all the way down.
    /// </remarks>
    public IReadOnlyList<long> PhotoIds { get; init; } = [];
}

/// <summary>Retitles one photo. Nothing else about it changes.</summary>
public sealed record SavePhotoCaptionRequest
{
    public string? Caption { get; init; }
}

/// <remarks>
/// 🔴 No SchoolId and no IsHeadOffice. The school comes from the caller's
/// membership; the head office is where provisioning put it, and moving it is a
/// different operation with its own consequences (2.53).
/// </remarks>
public sealed record SaveBranchRequest
{
    /// <summary>Required when updating, ignored on insert.</summary>
    public int? RowVersion { get; init; }

    public string BranchName { get; init; } = string.Empty;
    public string? BranchCode { get; init; }
    public string? AddressLine1 { get; init; }
    public string? AddressLine2 { get; init; }
    public int? CityId { get; init; }
    public int? DistrictId { get; init; }
    public int? StateId { get; init; }
    public string? Pincode { get; init; }
    public decimal? Latitude { get; init; }
    public decimal? Longitude { get; init; }
    public string? ContactPerson { get; init; }
    public string? ContactEmail { get; init; }
    public string? ContactMobile { get; init; }
    public bool IsActive { get; init; } = true;
}

public sealed record DeleteBranchRequest
{
    public int RowVersion { get; init; }
}

public sealed record SaveBranchResponse
{
    public long BranchId { get; init; }
    public Guid BranchUid { get; init; }
    public string Message { get; init; } = string.Empty;
}
