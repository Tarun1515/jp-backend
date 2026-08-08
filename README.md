# jp-backend

Both APIs, the shared .NET projects, and the database scripts for all three
databases.

> 🔴 **Read `../jp-docs/PROJECT_MEMORY.md` before doing any work here.**
> `jp-docs` must be cloned as a sibling of this repository.

---

## Why this is one repository and the frontend is five

`JP.Core`, `JP.Domain` and `JP.Infrastructure` are referenced by **both** APIs.
Splitting the APIs apart would force those three into NuGet packages, and every
backend change would become a version-bump-build-publish-consume cycle.

The frontend can live with that because `npm link` is a clean local escape
hatch: during development an app points straight at the library's working copy
and changes flow through with no publish at all. **There is no equally clean
equivalent in C#** — `ProjectReference` across repository boundaries is not a
supported workflow, and local NuGet feeds are a poor substitute.

Both APIs also deploy together, so the separation would buy nothing and cost a
publish step on every change.

Decision recorded in `PROJECT_MEMORY.md`. Do not revisit it without reading that
entry first.

---

## Layout

```
JP.Core/             envelope, constants, enums, exceptions — no dependencies
JP.Domain/           request and response contracts (the public API surface)
JP.Infrastructure/   Dapper, PBKDF2, JWT, SMTP, middleware, filters
                     repositories and services are `internal` on purpose — the
                     types carrying password hashes cannot be named from an API
                     project, so no serializer can reach them
JP.Sso.Api/          auth, users, roles, permissions, menus      :5199
JP.App.Api/          masters and business data (Phase 2+)        :5299
JP.Tools.SeedAdmin/  operator tool — creates the first admin
database/            run_all.sql + jp_sso, jp_mdm, jp_app scripts
```

---

## Setup

### 1. Databases

SQL Server **2019** (15.0), instance `localhost\TARUN`, Windows auth.
No 2022+ syntax anywhere — decision 2.11.

```powershell
sqlcmd -S localhost\TARUN -E -b -f 65001 -i database\run_all.sql
```

`-b` stops on the first error; `-f 65001` reads the files as UTF-8. The script
is idempotent — re-running it is how new scripts get applied.

### 2. Dev settings

```powershell
copy JP.Sso.Api\appsettings.Development.example.json JP.Sso.Api\appsettings.Development.json
copy JP.App.Api\appsettings.Development.example.json JP.App.Api\appsettings.Development.json
```

The real files are gitignored so a machine-specific connection string never
lands in the repository.

### 3. JWT signing key — the SAME value in BOTH APIs

`JP.Sso.Api` signs the token and `JP.App.Api` validates it. Two different keys
means every call to `JP.App.Api` returns 401 with nothing in the logs saying
why.

```powershell
$key = [Convert]::ToBase64String((1..64 | ForEach-Object { Get-Random -Maximum 256 }))
cd JP.Sso.Api ; dotnet user-secrets set "Jwt:Key" "$key"
cd ..\JP.App.Api ; dotnet user-secrets set "Jwt:Key" "$key"
```

> Do not build the key with `Get-Random -Count`. It returns *distinct* elements,
> so it silently produces a shorter and much weaker key than asked for.

### 4. First administrator

No admin row exists in any seed script, deliberately: a password hash committed
to a `.sql` file is a credential shared by every clone and backup, forever.

```powershell
cd JP.Tools.SeedAdmin
dotnet run -- --email you@example.com --generate
```

---

## Running

```powershell
dotnet build JP.sln          # expect 0 warnings, 0 errors
cd JP.Sso.Api ; dotnet run   # http://localhost:5199, Swagger in Development
cd JP.App.Api ; dotnet run   # http://localhost:5299
```

CORS allows only the four app origins — 4200, 4300, 4400, 4500. An Angular dev
server on any other port is refused, which is the loud failure we want.

---

## Tests

```powershell
cd database
sqlcmd -S localhost\TARUN -d jp_sso -E -b -f 65001 -I -i jp_sso\99_tests\001_test_sso_procedures.sql
sqlcmd -S localhost\TARUN -d jp_sso -E -b -f 65001 -I -i jp_sso\99_tests\002_test_error_log.sql
sqlcmd -S localhost\TARUN -d jp_sso -E -b -f 65001 -I -i jp_sso\99_tests\003_test_menus.sql
```

Expect 73, 17 and 31 assertions. Every suite runs inside a transaction that is
always rolled back, so they are safe against a working database.

`-I` is required — it turns `QUOTED_IDENTIFIER` on, which sqlcmd leaves off and
SSMS turns on.
