using JP.Domain.Masters;
using JP.Infrastructure.Repositories;
using Microsoft.Extensions.Logging;

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
/// <para>
/// 🔴 There is NO whitelist in this class, on purpose.
///
/// <c>USP_GetMaster</c> already selects a branch of a CASE it wrote itself, and
/// answers an unknown key with an empty set. Adding a second list here would
/// mean two lists that have to agree — and the day they stop agreeing is the
/// day a master silently disappears from a dropdown, or worse, a new one is
/// reachable that the procedure never intended to expose.
///
/// One gate, in the procedure.
/// </para>
/// <para>
/// 🔴 TWO PROCEDURES NOW, AND STILL NO LIST HERE (PRE-5, G26).
///
/// Five masters live in jp_app — employment types, job status and the three
/// ledger vocabularies — because the tables that point at them carry physical
/// foreign keys, and a physical FK may not cross a database (2.2). They are
/// served by <c>USP_GetAppMaster</c>, which has the same whitelist shape and
/// the same result-set shape.
///
/// ⚠️ The obvious implementation — a <c>HashSet</c> here naming the five
/// jp_app keys — is exactly the second list the paragraph above forbids, just
/// wearing a routing hat. So there is none: jp_mdm is asked first, and its
/// <c>@Recognised = 0</c> is what sends the key on to jp_app. Each procedure
/// stays its own gate, and adding a master anywhere is still a one-file edit.
/// </para>
/// <para>
/// ⚠️ ORDER IS NOT ARBITRARY: jp_mdm carries twenty-three of the twenty-eight
/// keys, so asking it first means the common case is one round trip and only
/// the five jp_app keys (and genuinely unknown ones) pay for a second. A key
/// claimed by BOTH procedures would be answered by jp_mdm and the jp_app
/// branch would never run — silently. The key sets are disjoint, and
/// <c>jobs-screens.mjs</c> asserts that by reading both procedure bodies.
/// </para>
/// <para>
/// 🔴 NOTHING GATING COMES THROUGH HERE. <c>m_mdm_features</c> and
/// <c>m_mdm_plan_features</c> are read by <see cref="IEntitlementRepository"/>,
/// directly and uncached, and the responses this service feeds carry an hour of
/// <c>Cache-Control</c>. Employment types are ordinary reference data and that
/// hour is fine for them; a gating mode with an hour of lag is an unsellable
/// kill switch. Do not route one through the other in either direction.
/// </para>
/// </remarks>
internal sealed class MasterService : IMasterService
{
    private readonly IMasterRepository _repository;
    private readonly IAppMasterRepository _appRepository;
    private readonly ILogger<MasterService> _logger;

    public MasterService(
        IMasterRepository repository,
        IAppMasterRepository appRepository,
        ILogger<MasterService> logger)
    {
        _repository = repository;
        _appRepository = appRepository;
        _logger = logger;
    }

    public async Task<IReadOnlyList<MasterItemDto>> GetAsync(
        string masterKey,
        int? parentId,
        CancellationToken cancellationToken)
    {
        var key = masterKey ?? string.Empty;

        var (rows, recognised) = await _repository
            .GetAsync(key, parentId, cancellationToken)
            .ConfigureAwait(false);

        /*
          🔴 THE FALL-THROUGH, AND WHY IT IS A FALL-THROUGH AND NOT A LOOKUP.

          jp_mdm did not recognise the key. That is either a jp_app master or a
          key nobody has. Asking jp_app is how we find out, and it costs a
          round trip only on the paths that need one.

          ⚠️ It is guarded on `!recognised`, NOT on `rows.Count == 0`. A
          recognised-but-empty master is a real and expected answer — districts
          and cities return nothing at all until the dataset lands (2.47) — and
          falling through on emptiness would send those two keys to jp_app on
          every single request, for ever, to be told nothing a second time.
        */
        if (!recognised)
        {
            var (appRows, appRecognised) = await _appRepository
                .GetAsync(key, parentId, cancellationToken)
                .ConfigureAwait(false);

            if (appRecognised)
            {
                return appRows.Select(ToDto).ToList();
            }
        }

        /*
          🔴 THE CALLER LEARNS NOTHING. WE LEARN IMMEDIATELY.

          An unrecognised key still returns an empty list — a client probing
          for table names must not be able to tell a real-but-empty master
          from one that does not exist.

          But a whitelist that fails closed and silently deflects an attacker
          and hides our own typo equally well, and only the first was intended.
          The school-type key mismatch (2.49) returned 200 with no rows for
          weeks and was found by a person noticing a blank dropdown.

          Warning, not error: the response is correct, and an alert that fires
          on every probe from the internet would be turned off within a day.
        */
        if (!recognised)
        {
            _logger.LogWarning(
                "Master key {MasterKey} is in NEITHER whitelist — not USP_GetMaster (jp_mdm) and not " +
                "USP_GetAppMaster (jp_app). The caller got an empty list. If this came from our own " +
                "client, it is a typo or a key neither procedure ever learned.",
                masterKey);
        }

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
    ///
    /// ⚠️ THE jp_app MASTERS ARE NOT IN THE BUNDLE EITHER, and that is also a
    /// decision. This bundle is jp_mdm's load-time set and runs on one
    /// connection; adding employment types would open a SECOND database on
    /// every cold start of every app, for one dropdown on one screen in one of
    /// them. The per-key endpoint serves it, carries the same hour of
    /// <c>Cache-Control</c>, and is fetched once by the form that needs it.
    /// Revisit only when a jp_app master is wanted on most screens.
    /// </remarks>
    public async Task<MasterBundleDto> GetBundleAsync(CancellationToken cancellationToken)
    {
        // Goes through GetAsync rather than the repository directly, so an
        // unrecognised key in THIS list logs the same warning as one from a
        // client. The bundle's keys are hardcoded here, which is exactly where
        // a typo would otherwise be hardest to notice.
        Task<IReadOnlyList<MasterItemDto>> Get(string key) =>
            GetAsync(key, null, cancellationToken);

        var (documentTypeRows, _) = await _repository
            .GetAsync("DOCUMENT_TYPE", null, cancellationToken)
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
