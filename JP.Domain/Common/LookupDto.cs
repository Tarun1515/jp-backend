namespace JP.Domain.Common;

/// <summary>
/// One row of a master table, shaped for a dropdown.
/// </summary>
/// <remarks>
/// Every <c>m_*</c> master projects to this, which is what lets
/// <c>GET /api/masters/{masterKey}</c> be a single generic endpoint and lets
/// the Angular MasterService cache all masters uniformly.
/// <para>
/// No dropdown anywhere in this application is hardcoded in a component or an
/// enum on the client — it comes from here.
/// </para>
/// </remarks>
public sealed class LookupDto
{
    /// <summary>Primary key of the master row.</summary>
    public int Id { get; set; }

    /// <summary>Stable business code, e.g. <c>CBSE</c>. Safe to compare against in code.</summary>
    public string Code { get; set; } = string.Empty;

    /// <summary>Display text.</summary>
    public string Name { get; set; } = string.Empty;

    public int DisplayOrder { get; set; }

    /// <summary>
    /// Parent key for dependent dropdowns — state within country, district
    /// within state, city within district. Null for flat masters.
    /// </summary>
    public int? ParentId { get; set; }
}
