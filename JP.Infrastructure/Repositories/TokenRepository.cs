using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

internal interface ITokenRepository
{
    Task<ProcResult> SaveRefreshTokenAsync(long userId, string tokenHash, DateTime expiresOnUtc,
        string? ipAddress, string? userAgent, CancellationToken cancellationToken);

    Task<TokenValidationRow?> ValidateRefreshTokenAsync(string tokenHash, CancellationToken cancellationToken);

    Task<RotateTokenResult> RotateRefreshTokenAsync(long userId, string oldTokenHash, string newTokenHash,
        DateTime newExpiresOnUtc, string? ipAddress, string? userAgent, CancellationToken cancellationToken);

    Task<RevokeResult> RevokeRefreshTokenAsync(string tokenHash, long? userId,
        CancellationToken cancellationToken);

    Task<RevokeResult> RevokeAllUserTokensAsync(long userId, int? tokenTypeId, long? revokedByUserId,
        CancellationToken cancellationToken);
}

/// <summary>Refresh, reset, invite and verification tokens.</summary>
internal sealed class TokenRepository : BaseRepository, ITokenRepository
{
    public TokenRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<TokenRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.Sso;

    public Task<ProcResult> SaveRefreshTokenAsync(
        long userId, string tokenHash, DateTime expiresOnUtc, string? ipAddress, string? userAgent,
        CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserId", userId, DbType.Int64);
        p.Add("@TokenHash", tokenHash, DbType.AnsiString, size: 128);
        p.Add("@ExpiresOn", expiresOnUtc, DbType.DateTime2);
        p.Add("@IpAddress", ipAddress, DbType.AnsiString, size: 45);
        p.Add("@UserAgent", userAgent, DbType.String, size: 400);

        return QuerySingleAsync<ProcResult>("USP_SaveRefreshToken", p, cancellationToken);
    }

    public Task<TokenValidationRow?> ValidateRefreshTokenAsync(
        string tokenHash, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@TokenHash", tokenHash, DbType.AnsiString, size: 128);

        return QueryFirstOrDefaultAsync<TokenValidationRow>(
            "USP_ValidateRefreshToken", p, cancellationToken);
    }

    public Task<RotateTokenResult> RotateRefreshTokenAsync(
        long userId, string oldTokenHash, string newTokenHash, DateTime newExpiresOnUtc,
        string? ipAddress, string? userAgent, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserId", userId, DbType.Int64);
        p.Add("@OldTokenHash", oldTokenHash, DbType.AnsiString, size: 128);
        p.Add("@NewTokenHash", newTokenHash, DbType.AnsiString, size: 128);
        p.Add("@NewExpiresOn", newExpiresOnUtc, DbType.DateTime2);
        p.Add("@IpAddress", ipAddress, DbType.AnsiString, size: 45);
        p.Add("@UserAgent", userAgent, DbType.String, size: 400);

        return QuerySingleAsync<RotateTokenResult>("USP_RotateRefreshToken", p, cancellationToken);
    }

    public Task<RevokeResult> RevokeRefreshTokenAsync(
        string tokenHash, long? userId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@TokenHash", tokenHash, DbType.AnsiString, size: 128);
        p.Add("@UserId", userId, DbType.Int64);

        return QuerySingleAsync<RevokeResult>("USP_RevokeRefreshToken", p, cancellationToken);
    }

    public Task<RevokeResult> RevokeAllUserTokensAsync(
        long userId, int? tokenTypeId, long? revokedByUserId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserId", userId, DbType.Int64);
        p.Add("@TokenTypeId", tokenTypeId, DbType.Int32);
        p.Add("@RevokedByUserId", revokedByUserId, DbType.Int64);

        return QuerySingleAsync<RevokeResult>("USP_RevokeAllUserTokens", p, cancellationToken);
    }
}
