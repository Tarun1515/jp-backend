using Dapper;
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

        /*
          🔴 BEFORE ANY REPOSITORY RUNS.

          Dapper cannot turn the DateTime a `date` column yields into a
          DateOnly on its own, and decision 2.28 puts DateOnly on every calendar
          date. Without these two handlers, reading a date of birth throws
          AFTER the row was written — the caller sees a failure for something
          that succeeded. See DateOnlyTypeHandler.
        */
        SqlMapper.AddTypeHandler(new DateOnlyTypeHandler());
        SqlMapper.AddTypeHandler(new TimeOnlyTypeHandler());

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

        // Phase 2D — jp_mdm and jp_app. Separate repositories because they
        // target separate databases: two connections, two commits, which is the
        // shape decision 2.2 requires.
        services.AddScoped<IMasterRepository, MasterRepository>();
        services.AddScoped<IApprovalRepository, ApprovalRepository>();
        services.AddScoped<IProvisioningRepository, ProvisioningRepository>();
        services.AddScoped<IPlanRepository, PlanRepository>();
        services.AddScoped<IAppProvisioningRepository, AppProvisioningRepository>();

        // ---- Phase 3E: profile APIs ------------------------------------
        services.AddScoped<ISchoolRepository, SchoolRepository>();
        services.AddScoped<IBranchRepository, BranchRepository>();
        services.AddScoped<ITeacherRepository, TeacherRepository>();
        services.AddScoped<ISchoolProfileService, SchoolProfileService>();
        services.AddScoped<IBranchService, BranchService>();
        services.AddScoped<ITeacherProfileService, TeacherProfileService>();
        services.AddScoped<ITeacherDirectoryService, TeacherDirectoryService>();
        services.AddScoped<ITeacherProvisioningService, TeacherProvisioningService>();

        // ---- Phase 3G: school team --------------------------------------
        // ⚠️ SchoolTeamService writes to jp_app AND jp_sso, so it depends on
        // repositories for both. That is the shape decision 2.2 requires: two
        // connections, two commits, and the orchestration in the API layer.
        services.AddScoped<ISchoolTeamRepository, SchoolTeamRepository>();
        services.AddScoped<ISchoolTeamService, SchoolTeamService>();

        // ---- Phase 3I: the dashboards -----------------------------------
        // Compose from the profile, team and subscription reads that already
        // exist. The subscription is the one thing nothing else returned.
        services.AddScoped<ISubscriptionRepository, SubscriptionRepository>();
        services.AddScoped<IDashboardService, DashboardService>();

        /*
          ---- Phase 2.5: the entitlement engine ---------------------------

          🔴 TWO REPOSITORIES, AND NEITHER IS IMasterService.

          IEntitlementRepository (jp_mdm) resolves the feature and its plan
          mapping in one query on every consume. It is deliberately NOT the
          master repository and must never be given a cache: an hour of lag
          would mean the kill switch engages an hour after the operator flips
          it, during exactly the incident it was flipped for.

          IEntitlementLedgerRepository (jp_app) owns the append-only ledger.
          Two databases that cannot join (2.2) means two repositories; the
          service is what joins them.

          ⚠️ Nothing here is gated yet — every feature seeds FREE. Phase 4
          writes the first real consume.
        */
        services.AddScoped<IEntitlementRepository, EntitlementRepository>();
        services.AddScoped<IEntitlementLedgerRepository, EntitlementLedgerRepository>();
        services.AddScoped<IEntitlementService, EntitlementService>();

        /*
          ---- Phase 4: jobs, the engine's first real consumer ---------------

          🔴 JobService depends on IEntitlementRepository — the DIRECT jp_mdm
          read, not IMasterService and not a cache. Publishing resolves the
          gating fresh every time, for the same reason the engine does: a kill
          switch with an hour of lag is not a kill switch.

          The consume itself happens inside USP_PublishJob's transaction, so
          nothing here calls the entitlement service separately.
        */
        services.AddScoped<IJobRepository, JobRepository>();
        services.AddScoped<IJobService, JobService>();

        // Public service interfaces — the boundary the API talks to.
        services.AddScoped<IAuthService, AuthService>();
        services.AddScoped<IUserService, UserService>();
        services.AddScoped<IRoleService, RoleService>();
        services.AddScoped<IMenuService, MenuService>();

        // Phase 2D.
        services.AddScoped<IMasterService, MasterService>();
        services.AddScoped<IApprovalService, ApprovalService>();
        services.AddScoped<IDocumentService, DocumentService>();

        // The cross-database work that follows a completed approval. Scoped,
        // not singleton: it depends on scoped repositories, and each run
        // belongs to one request.
        services.AddScoped<IApprovalOrchestrationService, ApprovalOrchestrationService>();

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
