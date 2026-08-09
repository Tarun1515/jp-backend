using JP.Domain.Masters;
using JP.Infrastructure.Repositories;

namespace JP.Infrastructure.Services;

public interface IMasterService
{
    Task<IReadOnlyList<MasterItemDto>> GetAsync(string masterKey, int? parentId, CancellationToken cancellationToken);

    Task<MasterBundleDto> GetBundleAsync(CancellationToken cancellationToken);
}

/// <summary>
/// Reads master data.
/// </summary>
/// <remarks>
/// 🔴 There is NO whitelist in this class, on purpose.
///
/// <c>USP_GetMaster</c> already selects a branch of a CASE it wrote itself, and
/// answers an unknown key with an empty set. Adding a second list here would
/// mean two lists that have to agree — and the day they stop agreeing is the
/// day a master silently disappears from a dropdown, or worse, a new one is
/// reachable that the procedure never intended to expose.
///
/// One gate, in the procedure.
/// </remarks>
internal sealed class MasterService : IMasterService
{
    private readonly IMasterRepository _repository;

    public MasterService(IMasterRepository repository)
    {
        _repository = repository;
    }

    public async Task<IReadOnlyList<MasterItemDto>> GetAsync(
        string masterKey,
        int? parentId,
        CancellationToken cancellationToken)
    {
        var rows = await _repository.GetAsync(masterKey ?? string.Empty, parentId, cancellationToken)
            .ConfigureAwait(false);

        return rows.Select(ToDto).ToList();
    }

    /// <summary>
    /// Everything the apps need at load, in one call.
    /// </summary>
    /// <remarks>
    /// ⚠️ Districts and cities are absent by design. They are hierarchical and
    /// unbounded — every city in India in a bundle nobody has filtered yet is
    /// megabytes for a dropdown that may never open. They come from the
    /// per-parent endpoints, which return an EMPTY list until the dataset
    /// arrives (2.47) so the forms degrade to state-only rather than erroring.
    ///
    /// Sequential rather than parallel: each call takes a connection from the
    /// pool, and firing seventeen at once to save a few milliseconds on a
    /// response that is cached for hours is a bad trade.
    /// </remarks>
    public async Task<MasterBundleDto> GetBundleAsync(CancellationToken cancellationToken)
    {
        async Task<IReadOnlyList<MasterItemDto>> Get(string key) =>
            (await _repository.GetAsync(key, null, cancellationToken).ConfigureAwait(false))
            .Select(ToDto).ToList();

        var documentTypeRows = await _repository.GetAsync("DOCUMENT_TYPE", null, cancellationToken)
            .ConfigureAwait(false);

        return new MasterBundleDto
        {
            Countries = await Get("COUNTRY").ConfigureAwait(false),
            States = await Get("STATE").ConfigureAwait(false),
            Boards = await Get("BOARD").ConfigureAwait(false),
            SchoolTypes = await Get("SCHOOL_TYPE").ConfigureAwait(false),
            Qualifications = await Get("QUALIFICATION").ConfigureAwait(false),
            Subjects = await Get("SUBJECT").ConfigureAwait(false),
            Designations = await Get("DESIGNATION").ConfigureAwait(false),
            ClassLevels = await Get("CLASS_LEVEL").ConfigureAwait(false),
            Streams = await Get("STREAM").ConfigureAwait(false),
            Genders = await Get("GENDER").ConfigureAwait(false),
            Skills = await Get("SKILL").ConfigureAwait(false),
            Facilities = await Get("FACILITY").ConfigureAwait(false),
            ExperienceRanges = await Get("EXPERIENCE_RANGE").ConfigureAwait(false),
            RequestTypes = await Get("REQUEST_TYPE").ConfigureAwait(false),
            ApprovalStatuses = await Get("APPROVAL_STATUS").ConfigureAwait(false),
            RejectionReasons = await Get("REJECTION_REASON").ConfigureAwait(false),
            DocumentTypes = documentTypeRows.Select(r => new DocumentTypeDto
            {
                Id = r.Id,
                Code = r.Code,
                Name = r.Name,
                DisplayOrder = r.DisplayOrder,
                RequestTypeId = r.ParentId ?? 0,
                IsMandatory = r.IsMandatory ?? false,
                MaxSizeKb = r.MaxSizeKb ?? 0,
                AllowedExtensions = r.AllowedExtensions ?? string.Empty,
            }).ToList(),
        };
    }

    private static MasterItemDto ToDto(MasterRow r) => new()
    {
        Id = r.Id,
        Code = r.Code,
        Name = r.Name,
        DisplayOrder = r.DisplayOrder,
        ParentId = r.ParentId,
    };
}
