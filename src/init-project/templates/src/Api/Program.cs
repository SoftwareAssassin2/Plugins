using System.Diagnostics.CodeAnalysis;
using Api;
using Api.Auth;
using DataAccess;
using DataAccess.Rls;
using Microsoft.AspNetCore.Authentication.JwtBearer;
using Microsoft.EntityFrameworkCore;

// Bootstrap/startup wiring — excluded from the coverage gate per docs/tdd.md §5.
// Keep this thin: validate, delegate into BusinessLogic, shape the response
// (docs/architecture.md). The decision-bearing auth/session-context logic lives in
// testable units (Api.Auth.SessionContextFactory / SessionUnitOfWorkMiddleware,
// DataAccess.Rls.SessionUnitOfWork) — this file only composes them. See
// docs/keycloak.md §4 and docs/config-management.md §4 for the env-var contract.

var builder = WebApplication.CreateBuilder(args);

// Runtime DB connection: the least-privilege `api` role (NEVER owner/migrator/
// superuser). API_CONNECTION_STRING is assembled by `system.sh build-config` into
// src/Api/.env (loaded into the environment by docker compose).
var apiConnectionString = builder.Configuration["API_CONNECTION_STRING"]
    ?? Environment.GetEnvironmentVariable("API_CONNECTION_STRING");
builder.Services.AddDbContext<PlatformDbContext>(options =>
    options.UseNpgsql(apiConnectionString));

// Per-request session-context unit of work (transaction-first, then SET LOCAL).
builder.Services.AddScoped<IDbSession, EfDbSession>();
builder.Services.AddScoped<ISessionUnitOfWork, SessionUnitOfWork>();

// Keycloak JWT bearer validation. Authority is the realm issuer; the Api is the
// confidential client whose tokens we accept (KEYCLOAK_* from src/Api/.env).
var keycloakPublicUrl = builder.Configuration["KEYCLOAK_PUBLIC_URL"]
    ?? Environment.GetEnvironmentVariable("KEYCLOAK_PUBLIC_URL");
var keycloakRealm = builder.Configuration["KEYCLOAK_REALM"]
    ?? Environment.GetEnvironmentVariable("KEYCLOAK_REALM");
var apiClientId = builder.Configuration["KEYCLOAK_API_CLIENT_ID"]
    ?? Environment.GetEnvironmentVariable("KEYCLOAK_API_CLIENT_ID");

builder.Services
    .AddAuthentication(JwtBearerDefaults.AuthenticationScheme)
    .AddJwtBearer(options =>
    {
        if (!string.IsNullOrWhiteSpace(keycloakPublicUrl) && !string.IsNullOrWhiteSpace(keycloakRealm))
        {
            options.Authority = $"{keycloakPublicUrl!.TrimEnd('/')}/realms/{keycloakRealm}";
        }

        options.Audience = apiClientId;
        // Keycloak surfaces realm roles under a custom claim; map the subject and
        // roles onto the standard claim types SessionContextFactory reads.
        options.TokenValidationParameters.NameClaimType = SessionContextFactory.SubjectClaimType;
        options.TokenValidationParameters.RoleClaimType = SessionContextFactory.RoleClaimType;
    });
builder.Services.AddAuthorization();

var app = builder.Build();

app.UseAuthentication();
app.UseAuthorization();

// Opens the per-request unit of work for authenticated requests (transaction +
// SET LOCAL app.user_id) so row-level security scopes every query.
app.UseMiddleware<SessionUnitOfWorkMiddleware>();

app.MapGet("/health", () => HealthStatus.Live());

app.Run();

// Exposed so a future WebApplicationFactory-based integration test can reference
// the entry-point assembly; the partial Program type is the conventional handle.
[ExcludeFromCodeCoverage]
public partial class Program;
