namespace JP.Domain.Masters;

/// <summary>
/// One master row, in the shape every master returns.
/// </summary>
/// <remarks>
/// All 23 masters share <c>Code</c>, <c>Name</c> and <c>DisplayOrder</c>, which
/// is what lets one endpoint and one config-driven admin screen serve all of
/// them (decision 2.41). <see cref="ParentId"/> is populated only for the
/// hierarchical ones — state, district, city, and the request-type-scoped
/// document types and rejection reasons.
/// </remarks>
public sealed record MasterItemDto
{
    public int Id { get; init; }
    public string Code { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;
    public int DisplayOrder { get; init; }

    /// <summary>Null for a flat master.</summary>
    public int? ParentId { get; init; }
}

/// <summary>
/// A document type, which carries upload rules on top of the master shape.
/// </summary>
/// <remarks>
/// <see cref="MaxSizeKb"/> and <see cref="AllowedExtensions"/> are enforced by
/// the upload endpoint by READING THEM FROM HERE. They are seeded per document
/// type (2.47) precisely so the limits are data rather than constants compiled
/// into a validator.
/// </remarks>
public sealed record DocumentTypeDto
{
    public int Id { get; init; }
    public string Code { get; init; } = string.Empty;
    public string Name { get; init; } = string.Empty;
    public int DisplayOrder { get; init; }
    public int RequestTypeId { get; init; }
    public bool IsMandatory { get; init; }
    public int MaxSizeKb { get; init; }

    /// <summary>Comma-separated, e.g. <c>pdf,jpg,jpeg,png</c>.</summary>
    public string AllowedExtensions { get; init; } = string.Empty;
}

/// <summary>
/// Everything the apps need at load, in one call.
/// </summary>
/// <remarks>
/// Deliberately excludes districts and cities. Those are hierarchical and
/// unbounded — a bulk payload carrying every city in India would be megabytes
/// for a dropdown nobody has opened yet. They are fetched per parent instead.
///
/// ⚠️ Both are EMPTY until the dataset arrives (2.47). The per-parent endpoints
/// return an empty list rather than 404, so a form degrades to state-only.
/// </remarks>
public sealed record MasterBundleDto
{
    public IReadOnlyList<MasterItemDto> Countries { get; init; } = [];
    public IReadOnlyList<MasterItemDto> States { get; init; } = [];
    public IReadOnlyList<MasterItemDto> Boards { get; init; } = [];
    public IReadOnlyList<MasterItemDto> SchoolTypes { get; init; } = [];
    public IReadOnlyList<MasterItemDto> Qualifications { get; init; } = [];
    public IReadOnlyList<MasterItemDto> Subjects { get; init; } = [];
    public IReadOnlyList<MasterItemDto> Designations { get; init; } = [];
    public IReadOnlyList<MasterItemDto> ClassLevels { get; init; } = [];
    public IReadOnlyList<MasterItemDto> Streams { get; init; } = [];
    public IReadOnlyList<MasterItemDto> Genders { get; init; } = [];
    public IReadOnlyList<MasterItemDto> Skills { get; init; } = [];
    public IReadOnlyList<MasterItemDto> Facilities { get; init; } = [];
    public IReadOnlyList<MasterItemDto> ExperienceRanges { get; init; } = [];
    public IReadOnlyList<MasterItemDto> RequestTypes { get; init; } = [];
    public IReadOnlyList<MasterItemDto> ApprovalStatuses { get; init; } = [];
    public IReadOnlyList<DocumentTypeDto> DocumentTypes { get; init; } = [];
    public IReadOnlyList<MasterItemDto> RejectionReasons { get; init; } = [];
}
