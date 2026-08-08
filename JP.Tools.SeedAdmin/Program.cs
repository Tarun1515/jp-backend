using System.Data;
using System.Globalization;
using System.Security.Cryptography;
using System.Text;
using Dapper;
using JP.Core.Constants;
using JP.Core.Enums;
using JP.Infrastructure.Data;
using JP.Infrastructure.Security;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Options;

namespace JP.Tools.SeedAdmin;

/*==============================================================================
  Creates the first administrator account.

  ----------------------------------------------------------------------------
  WHY THIS IS A TOOL AND NOT A SEED SCRIPT
  ----------------------------------------------------------------------------
  database/jp_sso/03_seed/ seeds roles and permissions, because those are the
  same on every installation. It does NOT seed an admin account, because that
  would mean a password hash lives in a committed .sql file — and a hash in
  source control is a credential shared by every clone, every branch and every
  backup, on every environment, forever. Rotating it means editing history.

  So the hash is derived HERE, on the operator's machine, at run time, from a
  password that only they have seen. The tool prints no hash unless --print-sql
  is asked for explicitly, and even then it prints to the console rather than
  writing a file, so there is nothing to accidentally commit.

  ----------------------------------------------------------------------------
  USAGE
  ----------------------------------------------------------------------------
    jp-seed-admin --email admin@example.com
    jp-seed-admin --email admin@example.com --generate
    jp-seed-admin --email admin@example.com --role SUPPORT_ADMIN --mobile 9876543210
    jp-seed-admin --email admin@example.com --generate --print-sql

  Password source, in order:
    --password <value>   explicit (visible in shell history — prefer --generate)
    --generate           a 20-character random password, printed once
    (neither)            masked interactive prompt, entered twice

  Exit codes: 0 created · 1 usage error · 2 refused by the database · 3 failed.
==============================================================================*/

internal static class Program
{
    private const string SsoConnectionName = "Sso";

    private static async Task<int> Main(string[] args)
    {
        try
        {
            var options = CommandLineOptions.Parse(args);

            if (options is null)
            {
                return 1;
            }

            return await RunAsync(options).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            Error($"Unexpected failure: {ex.Message}");

            return 3;
        }
    }

    private static async Task<int> RunAsync(CommandLineOptions options)
    {
        var password = ResolvePassword(options);

        if (password is null)
        {
            return 1;
        }

        // Derived with the SAME service the API uses, so the credential this
        // writes is verified by exactly the code that will check it at login.
        // A tool with its own hashing implementation is a tool that eventually
        // disagrees with the application about what a valid password is.
        var passwordService = new PasswordService();
        PasswordHashResult hashed;

        try
        {
            hashed = passwordService.HashPassword(password);
        }
        catch (ArgumentException ex)
        {
            Error(ex.Message);

            return 1;
        }

        Console.WriteLine();
        Console.WriteLine($"  Email      : {options.Email}");
        Console.WriteLine($"  Mobile     : {options.Mobile ?? "(none)"}");
        Console.WriteLine($"  Role       : {options.RoleCode}");
        // Invariant, not the operator's culture: an en-IN console renders
        // 210000 as "2,10,000", which reads like a different number.
        var iterations = hashed.Iterations.ToString("N0", CultureInfo.InvariantCulture);
        Console.WriteLine($"  Algorithm  : {hashed.Algorithm} @ {iterations} iterations");
        Console.WriteLine();

        if (options.PrintSql)
        {
            PrintSql(options, hashed);

            return 0;
        }

        return await CreateAsync(options, hashed).ConfigureAwait(false);
    }

    // -------------------------------------------------------------------------
    // Database
    // -------------------------------------------------------------------------

    private static async Task<int> CreateAsync(CommandLineOptions options, PasswordHashResult hashed)
    {
        using var host = BuildHost(options.ConnectionString);

        var factory = host.Services.GetRequiredService<IDbConnectionFactory>();

        await using var connection = await factory
            .CreateOpenConnectionAsync(JpDatabase.Sso)
            .ConfigureAwait(false);

        var parameters = new DynamicParameters();
        parameters.Add("@Email", options.Email, DbType.String, size: 150);
        parameters.Add("@Mobile", options.Mobile, DbType.AnsiString, size: 15);
        parameters.Add("@PasswordHash", hashed.Hash, DbType.Binary, size: 64);
        parameters.Add("@PasswordSalt", hashed.Salt, DbType.Binary, size: 32);
        parameters.Add("@HashAlgorithmId", (int)hashed.Algorithm, DbType.Int32);
        parameters.Add("@Iterations", hashed.Iterations, DbType.Int32);
        parameters.Add("@RoleCode", options.RoleCode, DbType.AnsiString, size: 50);
        parameters.Add("@CreatedByUserId", null, DbType.Int64);

        var result = await connection.QuerySingleAsync<ProcResult>(
            "dbo.USP_CreateAdminUser", parameters, commandType: CommandType.StoredProcedure)
            .ConfigureAwait(false);

        if (result.Status != 1)
        {
            Error($"{result.Message} [{result.Code}]");

            return 2;
        }

        Success($"{result.Message}  UserUid = {result.UserUid}");

        Console.WriteLine();
        Console.WriteLine("  The account is Active and its email is marked verified — an");
        Console.WriteLine("  administrator has nobody to approve them. Sign in and change the");
        Console.WriteLine("  password if it was generated here.");

        return 0;
    }

    /// <summary>
    /// A minimal host: configuration, DatabaseOptions and the connection
    /// factory. It deliberately does NOT call AddJpInfrastructure — that
    /// validates Jwt, Smtp, FileStorage and Auth at startup, and this tool
    /// issues no tokens, sends no email and stores no files. Requiring a JWT
    /// signing key to create a user would be a reason to put one somewhere it
    /// does not belong.
    /// </summary>
    private static IHost BuildHost(string? connectionStringOverride)
    {
        var builder = Host.CreateApplicationBuilder();

        if (!string.IsNullOrWhiteSpace(connectionStringOverride))
        {
            builder.Configuration.AddInMemoryCollection(
            [
                new KeyValuePair<string, string?>(
                    $"ConnectionStrings:{SsoConnectionName}", connectionStringOverride),
            ]);
        }

        builder.Services.Configure<DatabaseOptions>(
            builder.Configuration.GetSection(DatabaseOptions.SectionName));

        builder.Services.AddSingleton<IDbConnectionFactory, DbConnectionFactory>();

        return builder.Build();
    }

    private sealed class ProcResult
    {
        public int Status { get; init; }

        public string? Code { get; init; }

        public string? Message { get; init; }

        public long? Id { get; init; }

        public Guid? UserUid { get; init; }
    }

    // -------------------------------------------------------------------------
    // Passwords
    // -------------------------------------------------------------------------

    private static string? ResolvePassword(CommandLineOptions options)
    {
        if (options.Password is not null)
        {
            Warn("--password was supplied on the command line, where it is visible "
               + "in shell history and to `ps`. Prefer --generate or the prompt.");

            return options.Password;
        }

        if (options.Generate)
        {
            var generated = GeneratePassword();

            Console.WriteLine();
            Console.WriteLine("  Generated password (shown once — copy it now):");
            Console.WriteLine();
            Console.WriteLine($"      {generated}");
            Console.WriteLine();

            return generated;
        }

        if (Console.IsInputRedirected)
        {
            Error("No password source. stdin is redirected, so the interactive prompt "
                + "is unavailable — pass --generate, or --password if you must.");

            return null;
        }

        var first = ReadMasked("  Password: ");
        var second = ReadMasked("  Confirm : ");

        if (!string.Equals(first, second, StringComparison.Ordinal))
        {
            Error("The two entries did not match.");

            return null;
        }

        return first;
    }

    private static string ReadMasked(string prompt)
    {
        Console.Write(prompt);

        var buffer = new StringBuilder();

        while (true)
        {
            var key = Console.ReadKey(intercept: true);

            if (key.Key == ConsoleKey.Enter)
            {
                Console.WriteLine();

                return buffer.ToString();
            }

            if (key.Key == ConsoleKey.Backspace)
            {
                if (buffer.Length > 0)
                {
                    buffer.Length--;
                    // Erase the asterisk rather than just moving back, or the
                    // display keeps showing characters the buffer no longer has.
                    Console.Write("\b \b");
                }

                continue;
            }

            if (!char.IsControl(key.KeyChar))
            {
                buffer.Append(key.KeyChar);
                Console.Write('*');
            }
        }
    }

    /// <summary>
    /// A 20-character password with at least one character from each class.
    /// </summary>
    /// <remarks>
    /// Built from <see cref="RandomNumberGenerator.GetInt32(int)"/> — rejection
    /// sampling, so the distribution is uniform. The final shuffle matters:
    /// without it the guaranteed characters always land in the same four
    /// positions, which hands an attacker the shape of every password this tool
    /// has ever produced.
    /// </remarks>
    private static string GeneratePassword()
    {
        const string Lower = "abcdefghijkmnopqrstuvwxyz";
        const string Upper = "ABCDEFGHJKLMNPQRSTUVWXYZ";
        const string Digits = "23456789";
        const string Symbols = "!@#$%^&*-_=+?";
        const int Length = 20;

        var all = Lower + Upper + Digits + Symbols;
        var characters = new char[Length];

        characters[0] = Pick(Lower);
        characters[1] = Pick(Upper);
        characters[2] = Pick(Digits);
        characters[3] = Pick(Symbols);

        for (var i = 4; i < Length; i++)
        {
            characters[i] = Pick(all);
        }

        // Fisher-Yates.
        for (var i = Length - 1; i > 0; i--)
        {
            var j = RandomNumberGenerator.GetInt32(i + 1);
            (characters[i], characters[j]) = (characters[j], characters[i]);
        }

        return new string(characters);

        static char Pick(string set) => set[RandomNumberGenerator.GetInt32(set.Length)];
    }

    // -------------------------------------------------------------------------
    // --print-sql
    // -------------------------------------------------------------------------

    private static void PrintSql(CommandLineOptions options, PasswordHashResult hashed)
    {
        Warn("The statement below contains a real password hash. It is printed to "
           + "the console on purpose and must NOT be saved into the repository.");

        Console.WriteLine();
        Console.WriteLine("USE jp_sso;");
        Console.WriteLine("GO");
        Console.WriteLine();
        Console.WriteLine("EXEC dbo.USP_CreateAdminUser");
        Console.WriteLine($"     @Email           = N'{options.Email.Replace("'", "''", StringComparison.Ordinal)}',");
        Console.WriteLine(options.Mobile is null
            ? "     @Mobile          = NULL,"
            : $"     @Mobile          = '{options.Mobile}',");
        Console.WriteLine($"     @PasswordHash    = {ToHex(hashed.Hash)},");
        Console.WriteLine($"     @PasswordSalt    = {ToHex(hashed.Salt)},");
        Console.WriteLine($"     @HashAlgorithmId = {(int)hashed.Algorithm},");
        Console.WriteLine($"     @Iterations      = {hashed.Iterations.ToString(CultureInfo.InvariantCulture)},");
        Console.WriteLine($"     @RoleCode        = '{options.RoleCode}';");
        Console.WriteLine("GO");
        Console.WriteLine();
    }

    private static string ToHex(byte[] bytes) =>
        "0x" + Convert.ToHexString(bytes);

    // -------------------------------------------------------------------------
    // Console
    // -------------------------------------------------------------------------

    private static void Success(string message) => Write(ConsoleColor.Green, "  OK    ", message);

    private static void Warn(string message) => Write(ConsoleColor.Yellow, "  NOTE  ", message);

    private static void Error(string message) => Write(ConsoleColor.Red, "  ERROR ", message);

    private static void Write(ConsoleColor colour, string label, string message)
    {
        var previous = Console.ForegroundColor;

        Console.ForegroundColor = colour;
        Console.Write(label);
        Console.ForegroundColor = previous;
        Console.WriteLine(message);
    }

    // -------------------------------------------------------------------------
    // Arguments
    // -------------------------------------------------------------------------

    private sealed class CommandLineOptions
    {
        private static readonly string[] AdminRoles = ["SUPER_ADMIN", "ADMIN", "SUPPORT_ADMIN"];

        public required string Email { get; init; }

        public string? Mobile { get; init; }

        public string RoleCode { get; init; } = "SUPER_ADMIN";

        public string? Password { get; init; }

        public bool Generate { get; init; }

        public bool PrintSql { get; init; }

        public string? ConnectionString { get; init; }

        /// <summary>Returns null and prints the reason when the arguments are unusable.</summary>
        public static CommandLineOptions? Parse(string[] args)
        {
            string? email = null, mobile = null, password = null, connection = null;
            var role = "SUPER_ADMIN";
            bool generate = false, printSql = false;

            for (var i = 0; i < args.Length; i++)
            {
                switch (args[i].ToLowerInvariant())
                {
                    case "--email": email = Next(args, ref i); break;
                    case "--mobile": mobile = Next(args, ref i); break;
                    case "--role": role = Next(args, ref i) ?? role; break;
                    case "--password": password = Next(args, ref i); break;
                    case "--connection": connection = Next(args, ref i); break;
                    case "--generate": generate = true; break;
                    case "--print-sql": printSql = true; break;
                    case "-h":
                    case "--help":
                        PrintUsage();

                        return null;
                    default:
                        Error($"Unknown argument '{args[i]}'.");
                        PrintUsage();

                        return null;
                }
            }

            email = email?.Trim().ToLowerInvariant();
            mobile = string.IsNullOrWhiteSpace(mobile) ? null : mobile.Trim();
            role = role.Trim().ToUpperInvariant();

            if (string.IsNullOrWhiteSpace(email))
            {
                Error("--email is required.");
                PrintUsage();

                return null;
            }

            if (!AdminRoles.Contains(role, StringComparer.Ordinal))
            {
                Error($"--role must be one of: {string.Join(", ", AdminRoles)}.");

                return null;
            }

            if (password is not null && generate)
            {
                Error("--password and --generate are mutually exclusive.");

                return null;
            }

            if (password is { Length: > AppConstants.Password.MaxLength })
            {
                Error($"--password is longer than {AppConstants.Password.MaxLength} characters.");

                return null;
            }

            return new CommandLineOptions
            {
                Email = email,
                Mobile = mobile,
                RoleCode = role,
                Password = password,
                Generate = generate,
                PrintSql = printSql,
                ConnectionString = connection,
            };
        }

        private static string? Next(string[] args, ref int index) =>
            index + 1 < args.Length && !args[index + 1].StartsWith("--", StringComparison.Ordinal)
                ? args[++index]
                : null;

        private static void PrintUsage()
        {
            Console.WriteLine();
            Console.WriteLine("  jp-seed-admin — creates an administrator account in jp_sso.");
            Console.WriteLine();
            Console.WriteLine("    --email <address>     required");
            Console.WriteLine("    --mobile <10 digits>  optional");
            Console.WriteLine("    --role <code>         SUPER_ADMIN (default) | ADMIN | SUPPORT_ADMIN");
            Console.WriteLine("    --generate            generate a random password and print it once");
            Console.WriteLine("    --password <value>    supply one (visible in shell history)");
            Console.WriteLine("    --print-sql           print the EXEC statement instead of running it");
            Console.WriteLine("    --connection <string> override the configured jp_sso connection");
            Console.WriteLine();
            Console.WriteLine("  With neither --generate nor --password, the password is prompted for.");
            Console.WriteLine();
        }
    }
}
