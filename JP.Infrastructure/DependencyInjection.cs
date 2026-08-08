using JP.Infrastructure.Data;
using JP.Infrastructure.Email;
using JP.Infrastructure.Middleware;
using JP.Infrastructure.Repositories;
using JP.Infrastructure.Security;
using JP.Infrastructure.Services;
using JP.Infrastructure.Storage;
using Microsoft.AspNetCore.Builder;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;

namespace JP.Infrastructure;

/// <summary>
/// Wires up everything JP.Infrastructure provides. Both APIs call
/// <see cref="AddJpInfrastructure"/> and <see cref="UseJpInfrastructure"/>.
/// </summary>
public static class DependencyInjection
{
    /// <summary>
    /// Registers infrastructure services and binds their configuration.
    /// </summary>
    /// <remarks>
    /// Every options block is validated with <c>ValidateOnStart</c>. A missing
    /// JWT key or connection string therefore fails the application at boot,
    /// where it is obvious, rather than on the first request that needs it —
    /// which in practice means in front of a user.
    /// </remarks>
    public static IServiceCollection AddJpInfrastructure(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(configuration);

        services.AddOptions<DatabaseOptions>()
            .Bind(configuration.GetSection(DatabaseOptions.SectionName))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services.AddOptions<JwtOptions>()
            .Bind(configuration.GetSection(JwtOptions.SectionName))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services.AddOptions<FileStorageOptions>()
            .Bind(configuration.GetSection(FileStorageOptions.SectionName))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services.AddOptions<SmtpOptions>()
            .Bind(configuration.GetSection(SmtpOptions.SectionName))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        services.AddOptions<AuthOptions>()
            .Bind(configuration.GetSection(AuthOptions.SectionName))
            .ValidateDataAnnotations()
            .ValidateOnStart();

        // Stateless and thread-safe, so one instance each.
        services.AddSingleton<IDbConnectionFactory, DbConnectionFactory>();
        services.AddSingleton<IPasswordService, PasswordService>();
        services.AddSingleton<ITokenHasher, Sha256TokenHasher>();
        services.AddSingleton<IJwtService, JwtService>();
        services.AddSingleton<IFileStorageService, LocalDiskFileStorageService>();
        services.AddSingleton<IEmailTemplateRenderer, FileEmailTemplateRenderer>();

        // Scoped: an SMTP client per request keeps one slow send from blocking
        // another, and keeps failures isolated to the request that caused them.
        services.AddScoped<IEmailService, SmtpEmailService>();

        /*
          Email is queued, never sent inline. On the auth endpoints that is a
          SECURITY property, not a performance one: forgot-password must take
          the same time whether the address exists or not, and rendering a
          template on the thread pool during the request was measurably
          breaking that. See Email/EmailDispatchQueue.cs.
        */
        services.AddSingleton<IEmailDispatchQueue, EmailDispatchQueue>();
        services.AddHostedService<EmailDispatchWorker>();

        /*
          The login decoy credential is a SINGLETON, and that matters: it is
          derived with 210,000 PBKDF2 iterations, so building one per request
          would add ~200 ms to every sign-in for no benefit.
        */
        services.AddSingleton<IDummyCredentialProvider, DummyCredentialProvider>();

        /*
          Repositories and service implementations are INTERNAL to this
          assembly. They are registered here because only this assembly can see
          them — which is exactly the point: the types that carry password
          hashes cannot be named, let alone returned, from an API project.
        */
        services.AddScoped<IUserRepository, UserRepository>();
        services.AddScoped<ITokenRepository, TokenRepository>();
        services.AddScoped<IRoleRepository, RoleRepository>();
        services.AddScoped<IMenuRepository, MenuRepository>();

        // Public service interfaces — the boundary the API talks to.
        services.AddScoped<IAuthService, AuthService>();
        services.AddScoped<IUserService, UserService>();
        services.AddScoped<IRoleService, RoleService>();
        services.AddScoped<IMenuService, MenuService>();

        // IMiddleware implementations are resolved from DI per request.
        services.AddTransient<GlobalExceptionHandlerMiddleware>();
        services.AddTransient<RequestResponseLoggingMiddleware>();

        return services;
    }

    /// <summary>
    /// Inserts the infrastructure middleware. Call this early — before
    /// authentication, routing and endpoints.
    /// </summary>
    /// <remarks>
    /// Order is deliberate. Logging sits OUTSIDE the exception handler so that
    /// a request which blows up is still logged, with the 500 the handler
    /// actually returned rather than the status it had when it failed.
    /// </remarks>
    public static IApplicationBuilder UseJpInfrastructure(this IApplicationBuilder app)
    {
        ArgumentNullException.ThrowIfNull(app);

        app.UseMiddleware<RequestResponseLoggingMiddleware>();
        app.UseMiddleware<GlobalExceptionHandlerMiddleware>();

        return app;
    }
}
