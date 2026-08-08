using System.Collections.Concurrent;
using System.Net;
using System.Text;

namespace JP.Infrastructure.Email;

/// <summary>
/// Loads HTML templates from disk and substitutes <c>{{Placeholder}}</c> tokens.
/// </summary>
/// <remarks>
/// Templates are read once and cached, since they only change on deployment.
/// <para>
/// Token values are HTML-encoded before substitution. A teacher whose name is
/// <c>&lt;script&gt;</c> would otherwise have that markup rendered inside every
/// notification email built from their profile.
/// </para>
/// </remarks>
public sealed class FileEmailTemplateRenderer : IEmailTemplateRenderer
{
    private readonly ConcurrentDictionary<string, string> _cache = new(StringComparer.OrdinalIgnoreCase);
    private readonly string _templateDirectory;

    public FileEmailTemplateRenderer()
    {
        // Templates are copied next to the binary by the csproj, so they
        // resolve identically under `dotnet run` and a published deployment.
        _templateDirectory = Path.Combine(AppContext.BaseDirectory, "Email", "Templates");
    }

    public async Task<string> RenderAsync(
        string templateName,
        IReadOnlyDictionary<string, string> tokens,
        CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(tokens);

        if (string.IsNullOrWhiteSpace(templateName))
        {
            throw new ArgumentException("A template name is required.", nameof(templateName));
        }

        // The name reaches disk, so a caller must not be able to walk out of
        // the template directory with it.
        var safeName = Path.GetFileNameWithoutExtension(templateName);
        if (string.IsNullOrEmpty(safeName))
        {
            throw new ArgumentException("A template name is required.", nameof(templateName));
        }

        var template = await LoadAsync(safeName, cancellationToken).ConfigureAwait(false);

        var builder = new StringBuilder(template);
        foreach (var (key, value) in tokens)
        {
            builder.Replace($"{{{{{key}}}}}", WebUtility.HtmlEncode(value ?? string.Empty));
        }

        return builder.ToString();
    }

    private async Task<string> LoadAsync(string templateName, CancellationToken cancellationToken)
    {
        if (_cache.TryGetValue(templateName, out var cached))
        {
            return cached;
        }

        var path = Path.Combine(_templateDirectory, $"{templateName}.html");

        if (!File.Exists(path))
        {
            throw new FileNotFoundException($"Email template '{templateName}' was not found.", path);
        }

        var content = await File.ReadAllTextAsync(path, cancellationToken).ConfigureAwait(false);
        _cache[templateName] = content;
        return content;
    }
}
