using System.Data;
using Dapper;
using JP.Core.Enums;
using JP.Infrastructure.Data;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace JP.Infrastructure.Repositories;

internal interface IMenuRepository
{
    Task<IReadOnlyList<MenuRow>> GetUserMenusAsync(long userId, CancellationToken cancellationToken);
}

internal sealed class MenuRepository : BaseRepository, IMenuRepository
{
    public MenuRepository(
        IDbConnectionFactory connectionFactory,
        IOptions<DatabaseOptions> databaseOptions,
        ILogger<MenuRepository> logger)
        : base(connectionFactory, databaseOptions, logger)
    {
    }

    protected override JpDatabase Database => JpDatabase.Sso;

    /// <summary>
    /// The menus this user is allowed to see.
    /// </summary>
    /// <remarks>
    /// Takes the numeric UserId, which the service reads from the JWT's own
    /// claim. There is no overload taking it from anywhere else, so one user
    /// cannot request another's navigation.
    /// </remarks>
    public Task<IReadOnlyList<MenuRow>> GetUserMenusAsync(long userId, CancellationToken cancellationToken)
    {
        var p = new DynamicParameters();
        p.Add("@UserId", userId, DbType.Int64);

        return QueryAsync<MenuRow>("USP_GetUserMenus", p, cancellationToken);
    }
}
