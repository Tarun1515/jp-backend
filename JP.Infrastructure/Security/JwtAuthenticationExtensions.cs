using System.Text;
using System.Text.Json;
using JP.Core.Common;
using JP.Core.Constants;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.AspNetCore.Http;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.IdentityModel.Tokens;

namespace JP.Infrastructure.Security;

/// <summary>
/// JWT bearer authentication, configured identically in both APIs.
/// </summary>
/// <remarks>
/// Shared on purpose: JP.Sso.Api issues the tokens and JP.App.Api validates
/// them, so any drift between two hand-written copies of this setup would show
/// up as tokens that work against one API and not the other.
/// </remarks>
public static class JwtAuthenticationExtensions
{
    private static readonly JsonSerializerOptions JsonOptions = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
    };

    public static IServiceCollection AddJpJwtAuthentication(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        ArgumentNullException.ThrowIfNull(services);
        ArgumentNullException.ThrowIfNull(configuration);

        var options = configuration.GetSection(JwtOptions.SectionName).Get<JwtOptions>()
            ?? throw new InvalidOperationException(
                "The 'Jwt' configuration section is missing.");

        if (string.IsNullOrWhiteSpace(options.Key))
        {
            throw new InvalidOperationException(
                "Jwt:Key is not configured. In development set it with: " +
                "dotnet user-secrets set \"Jwt:Key\" \"<64+ character string>\"");
        }

        services
            .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
            .AddJwtBearer(bearer =>
            {
                // Without this the handler rewrites well-known claims to long
                // WS-Federation URIs, and the short names this system uses stop
                // resolving. Every ClaimsPrincipal lookup would silently return
                // nothing.
                bearer.MapInboundClaims = false;

                bearer.TokenValidationParameters = new TokenValidationParameters
                {
                    ValidateIssuer = true,
                    ValidIssuer = options.Issuer,
                    ValidateAudience = true,
                    ValidAudience = options.Audience,
                    ValidateIssuerSigningKey = true,
                    IssuerSigningKey = new SymmetricSecurityKey(Encoding.UTF8.GetBytes(options.Key)),
                    ValidateLifetime = true,
                    ClockSkew = TimeSpan.FromSeconds(options.ClockSkewSeconds),
                    NameClaimType = JpClaimTypes.UserUid,
                    RoleClaimType = JpClaimTypes.Roles,
                };

                bearer.Events = new JwtBearerEvents
                {
                    // Default behaviour is an empty 401 body. Everything else in
                    // this API answers in the Response envelope, and the Angular
                    // interceptor parses one shape only.
                    OnChallenge = async context =>
                    {
                        context.HandleResponse();

                        if (context.Response.HasStarted)
                        {
                            return;
                        }

                        // Distinguishing "expired" from "invalid" is what lets
                        // the client refresh silently instead of bouncing the
                        // user to the login screen.
                        var expired = context.AuthenticateFailure is SecurityTokenExpiredException;

                        var (message, code) = expired
                            ? ("Your session has expired.", ErrorCodes.TokenExpired)
                            : ("You are not signed in.", ErrorCodes.Unauthorized);

                        await WriteAsync(context.Response, StatusCodes.Status401Unauthorized,
                            ApiResponse.Failure(message, code)).ConfigureAwait(false);
                    },

                    OnForbidden = async context =>
                    {
                        if (context.Response.HasStarted)
                        {
                            return;
                        }

                        await WriteAsync(context.Response, StatusCodes.Status403Forbidden,
                            ApiResponse.Failure("You do not have permission to perform this action.",
                                ErrorCodes.Forbidden)).ConfigureAwait(false);
                    },
                };
            });

        services.AddAuthorization();

        return services;
    }

    private static async Task WriteAsync<T>(HttpResponse response, int statusCode, Response<T> body)
    {
        response.StatusCode = statusCode;
        response.ContentType = "application/json; charset=utf-8";

        await response.WriteAsync(JsonSerializer.Serialize(body, JsonOptions)).ConfigureAwait(false);
    }
}
