using System.Globalization;
using System.Security.Claims;
using System.Text;
using JP.Core.Constants;
using Microsoft.Extensions.Options;
using Microsoft.IdentityModel.JsonWebTokens;
using Microsoft.IdentityModel.Tokens;

namespace JP.Infrastructure.Security;

/// <summary>
/// HMAC-SHA256 JWT issuing and validation.
/// </summary>
/// <remarks>
/// Uses <see cref="JsonWebTokenHandler"/> rather than the older
/// <c>JwtSecurityTokenHandler</c>, and turns off inbound claim-type mapping so
/// the short claim names survive the round trip: without that, the handler
/// rewrites well-known claims to long WS-Federation URIs and
/// <c>ClaimsPrincipal.FindFirst("uid")</c> quietly returns nothing.
/// </remarks>
public sealed class JwtService : IJwtService
{
    private readonly JwtOptions _options;
    private readonly ITokenHasher _tokenHasher;
    private readonly SigningCredentials _signingCredentials;
    private readonly TokenValidationParameters _validationParameters;
    private readonly JsonWebTokenHandler _handler = new();

    public JwtService(IOptions<JwtOptions> options, ITokenHasher tokenHasher)
    {
        ArgumentNullException.ThrowIfNull(options);

        _options = options.Value;
        _tokenHasher = tokenHasher ?? throw new ArgumentNullException(nameof(tokenHasher));

        var key = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(_options.Key));
        _signingCredentials = new SigningCredentials(key, SecurityAlgorithms.HmacSha256);

        _validationParameters = new TokenValidationParameters
        {
            ValidateIssuer = true,
            ValidIssuer = _options.Issuer,
            ValidateAudience = true,
            ValidAudience = _options.Audience,
            ValidateIssuerSigningKey = true,
            IssuerSigningKey = key,
            ValidateLifetime = true,
            ClockSkew = TimeSpan.FromSeconds(_options.ClockSkewSeconds),
            NameClaimType = JpClaimTypes.UserUid,
        };
    }

    public AccessTokenResult CreateAccessToken(JwtUserContext user)
    {
        ArgumentNullException.ThrowIfNull(user);

        var tokenId = Guid.NewGuid().ToString("N");
        var expiresOn = DateTime.UtcNow.AddMinutes(_options.AccessTokenMinutes);

        var claims = new List<Claim>
        {
            new(JpClaimTypes.UserId, user.UserId.ToString(CultureInfo.InvariantCulture)),
            new(JpClaimTypes.UserUid, user.UserUid.ToString()),
            new(JpClaimTypes.UserType, ((int)user.UserType).ToString(CultureInfo.InvariantCulture)),
            new(JpClaimTypes.Status, ((int)user.Status).ToString(CultureInfo.InvariantCulture)),
            new(JpClaimTypes.TokenId, tokenId),
        };

        // Omitted entirely rather than sent as empty for admins and teachers,
        // so RequireOrganizationUid() fails loudly instead of matching "".
        if (user.OrganizationUid.HasValue)
        {
            claims.Add(new Claim(JpClaimTypes.OrganizationUid, user.OrganizationUid.Value.ToString()));
        }

        claims.AddRange(user.Roles.Select(role => new Claim(JpClaimTypes.Roles, role)));
        claims.AddRange(user.Permissions.Select(permission => new Claim(JpClaimTypes.Permissions, permission)));

        var descriptor = new SecurityTokenDescriptor
        {
            Subject = new ClaimsIdentity(claims),
            Issuer = _options.Issuer,
            Audience = _options.Audience,
            Expires = expiresOn,
            IssuedAt = DateTime.UtcNow,
            SigningCredentials = _signingCredentials,
        };

        return new AccessTokenResult(_handler.CreateToken(descriptor), expiresOn, tokenId);
    }

    public RefreshTokenResult CreateRefreshToken()
    {
        return new RefreshTokenResult(
            _tokenHasher.CreateToken(),
            DateTime.UtcNow.AddDays(_options.RefreshTokenDays));
    }

    public async Task<ClaimsPrincipal?> ValidateAccessTokenAsync(string token, bool validateLifetime = true)
    {
        if (string.IsNullOrWhiteSpace(token))
        {
            return null;
        }

        var parameters = _validationParameters.Clone();
        parameters.ValidateLifetime = validateLifetime;

        var result = await _handler.ValidateTokenAsync(token, parameters).ConfigureAwait(false);

        // Deliberately swallows the reason. A caller that learns *why* a token
        // failed learns something about the key or the clock; the only useful
        // answer to the client is "not valid".
        return result.IsValid ? new ClaimsPrincipal(result.ClaimsIdentity) : null;
    }
}
