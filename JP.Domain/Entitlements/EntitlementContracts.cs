namespace JP.Domain.Entitlements;

/*==============================================================================
  🔴 THE PROHIBITION THIS ENGINE CARRIES EVERYWHERE (2.56 — LOCKED)

  The entitlement engine and contact unlock never reference each other, in
  either direction. Nothing in this file may carry a teacher's contact details,
  and no contact decision may consult anything here.

  A subscription buys the school's CAPABILITY — whether it may search at all,
  how many invitations it may send. Contact opens on the teacher's consent:
  they applied, or they accepted an invitation. If a requirement seems to need
  a plan check inside contact unlock, the requirement is being described
  wrongly — what is sold is reach, and reach is invites.
==============================================================================*/

/// <summary>How a feature's access is decided. Mirrors m_mdm_gating_modes.</summary>
/// <remarks>
/// ⚠️ There is no <c>Disabled</c> member, and its absence is the design.
/// The kill switch is <c>IsActive</c> on the feature — orthogonal to mode — so
/// that switching a feature off does not destroy the record of how it was
/// gated. A mode-based Disabled would overwrite Metered, and restoring it would
/// depend on somebody remembering, mid-incident.
/// </remarks>
public enum GatingMode
{
    /// <summary>Ungated. No mapping is read and nothing is written.</summary>
    Free = 1,

    /// <summary>In the plan or not. No count, and NOTHING is written to the ledger.</summary>
    Boolean = 2,

    /// <summary>Quota per IST calendar month, then credits, then refusal.</summary>
    Metered = 3,
}

/// <summary>Which pocket a consume came out of. Mirrors m_app_ledger_sources.</summary>
public enum LedgerSource
{
    /// <summary>The plan's included allowance. Always spent first.</summary>
    Quota = 1,

    /// <summary>Purchased or granted credits. Only once quota is gone.</summary>
    Credit = 2,
}

/// <summary>What a consume was for — the idempotency key's type half.</summary>
public enum RefEntityType
{
    Job = 1,
    Invite = 2,
    Application = 3,

    /// <summary>An administrative action. Its Uid is minted at the decision.</summary>
    Manual = 4,
}

/// <summary>
/// One entitlement decision — the whole answer, refusals included.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 A REFUSAL IS A RETURN VALUE, NOT AN EXCEPTION, at the service boundary.
/// Phase 4 has to branch on "you are out of job posts" as ordinary business
/// logic; making that arrive as a thrown exception would put a try/catch around
/// the happy path of every gated action.
/// </para>
/// <para>
/// The controller maps a refusal onto the right HTTP status, so over the wire
/// the house convention (2.21/2.12) is unchanged.
/// </para>
/// </remarks>
public sealed class EntitlementDecision
{
    /// <summary>True when the action may proceed.</summary>
    public bool Allowed { get; set; }

    /// <summary>
    /// An <see cref="Core.Constants.ErrorCodes"/> value. Null on a plain allow.
    /// </summary>
    /// <remarks>
    /// ⚠️ Can be non-null while <see cref="Allowed"/> is true —
    /// <c>ALREADY_CONSUMED</c> is a success. Branch on Allowed first.
    /// </remarks>
    public string? Code { get; set; }

    public string? Message { get; set; }

    /// <summary>
    /// True only when a ledger row was actually written. FREE and BOOLEAN
    /// allows are <c>Allowed = true, Consumed = false</c> — they write nothing.
    /// </summary>
    public bool Consumed { get; set; }

    /// <summary>The ledger row, when one was written.</summary>
    public long? EntryId { get; set; }

    public LedgerSource? Source { get; set; }

    // ---- metered only; null for FREE and BOOLEAN ---------------------------

    public int? QuotaUsed { get; set; }

    /// <summary>Null means unlimited within the plan — not zero.</summary>
    public int? QuotaRemaining { get; set; }

    public int? CreditBalance { get; set; }

    public DateTime? PeriodFromUtc { get; set; }
    public DateTime? PeriodToUtc { get; set; }
}

/// <summary>An owner's standing for one feature, recomputed from the ledger.</summary>
public sealed class EntitlementBalanceDto
{
    public Guid OwnerUid { get; set; }
    public int FeatureId { get; set; }
    public string FeatureCode { get; set; } = string.Empty;

    public DateTime PeriodFromUtc { get; set; }
    public DateTime PeriodToUtc { get; set; }

    public int QuotaUsed { get; set; }
    public int CreditBalance { get; set; }
    public int CreditUsedThisPeriod { get; set; }
}

/// <summary>One ledger row, for support and for the verification scripts.</summary>
public sealed class LedgerEntryDto
{
    public long EntryId { get; set; }
    public Guid EntryUid { get; set; }
    public Guid OwnerUid { get; set; }
    public int FeatureId { get; set; }

    public int EntryTypeId { get; set; }
    public string EntryTypeCode { get; set; } = string.Empty;

    public int? SourceId { get; set; }
    public string? SourceCode { get; set; }

    /// <summary>Signed: grants and reversals positive, consumes and expiries negative.</summary>
    public int Units { get; set; }

    public int? RefEntityTypeId { get; set; }
    public string? RefEntityTypeCode { get; set; }
    public Guid? RefEntityUid { get; set; }

    public long? ReversalOfEntryId { get; set; }
    public DateTime? ReversedOn { get; set; }
    public DateTime OccurredOn { get; set; }
    public string? Notes { get; set; }

    /// <summary>🔴 Arrives through an alias in the procedure (2.61).</summary>
    public bool IsActive { get; set; }
}

// ---- the admin matrix ------------------------------------------------------

/// <summary>
/// Everything the plan × feature screen draws.
/// </summary>
/// <remarks>
/// 🔴 The three lists are sent SEPARATELY rather than pre-joined into a grid.
/// A pre-joined grid would have to invent a row for every plan × feature pair
/// and mark most of them unmapped — and then nothing could tell an invented row
/// from a real one carrying zeros.
///
/// Sent this way, UNMAPPED stays what it actually is: the absence of a row in
/// <see cref="Mappings"/>. That is the same fact the engine refuses on, so the
/// screen and the engine agree by construction rather than by two separate
/// implementations of one rule.
/// </remarks>
public sealed class EntitlementMatrixDto
{
    public IReadOnlyList<PlanSummaryDto> Plans { get; set; } = [];
    public IReadOnlyList<FeatureDto> Features { get; set; } = [];
    public IReadOnlyList<PlanFeatureDto> Mappings { get; set; } = [];
    public IReadOnlyList<GatingModeDto> GatingModes { get; set; } = [];
}

public sealed class PlanSummaryDto
{
    public int PlanId { get; set; }
    public string PlanCode { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;

    /// <summary>2 = School, 3 = Teacher. Cross-database meaning (2.2).</summary>
    public int UserTypeId { get; set; }

    public decimal Price { get; set; }
    public bool IsDefault { get; set; }

    /// <summary>🔴 Aliased in the procedure (2.61).</summary>
    public bool IsActive { get; set; }
}

public sealed class FeatureDto
{
    public int FeatureId { get; set; }
    public string FeatureCode { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string? Description { get; set; }

    public int GatingModeId { get; set; }
    public string GatingModeCode { get; set; } = string.Empty;
    public string GatingModeName { get; set; } = string.Empty;

    public int AppliesToUserTypeId { get; set; }
    public int DisplayOrder { get; set; }

    /// <summary>
    /// 🔴 THE KILL SWITCH, and aliased in the procedure (2.61).
    /// </summary>
    /// <remarks>
    /// ⚠️ On this column the silent-false failure Dapper produces without an
    /// alias would be the worst available one: every feature would read as
    /// switched off and the engine would refuse everything, everywhere. The
    /// HTTP verification reads the row and the JSON for exactly this column and
    /// asserts both are TRUE — a false/false pair agrees and proves nothing,
    /// which is precisely how G25 hid for two phases.
    /// </remarks>
    public bool IsActive { get; set; }
}

public sealed class PlanFeatureDto
{
    public int PlanFeatureId { get; set; }
    public int PlanId { get; set; }
    public int FeatureId { get; set; }

    /// <summary>BOOLEAN mode. True = the plan grants it.</summary>
    public bool IsIncluded { get; set; }

    /// <summary>
    /// METERED mode. Null = unlimited within the plan; 0 = explicitly none.
    /// ⚠️ Those are different and the engine does not conflate them.
    /// </summary>
    public int? QuotaPerPeriod { get; set; }

    /// <summary>🔴 Aliased in the procedure (2.61).</summary>
    public bool IsActive { get; set; }
}

public sealed class GatingModeDto
{
    public int GatingModeId { get; set; }
    public string Code { get; set; } = string.Empty;
    public string Name { get; set; } = string.Empty;
    public string? Description { get; set; }
    public int DisplayOrder { get; set; }
}

// ---- requests --------------------------------------------------------------

public sealed class SaveFeatureGatingRequest
{
    public int GatingModeId { get; set; }

    /// <summary>The kill switch. Independent of the mode, deliberately.</summary>
    public bool IsActive { get; set; }
}

public sealed class SavePlanFeatureRequest
{
    public int PlanId { get; set; }
    public int FeatureId { get; set; }

    /// <summary>MAP or UNMAP. UNMAP returns the cell to "no decision" = denied.</summary>
    public string Action { get; set; } = "MAP";

    public bool IsIncluded { get; set; }
    public int? QuotaPerPeriod { get; set; }
}

public sealed class ConsumeRequest
{
    public Guid OwnerUid { get; set; }
    public string FeatureCode { get; set; } = string.Empty;
    public int Units { get; set; } = 1;

    public int? RefEntityTypeId { get; set; }

    /// <summary>
    /// 🔴 The idempotency key. A metered consume without one would charge twice
    /// on any retry, which is the failure the whole design exists to prevent.
    /// </summary>
    public Guid? RefEntityUid { get; set; }

    public string? Notes { get; set; }
}

public sealed class GrantCreditsRequest
{
    public Guid OwnerUid { get; set; }
    public string FeatureCode { get; set; } = string.Empty;
    public int Units { get; set; }
    public string? Notes { get; set; }
}
