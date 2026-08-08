namespace JP.Infrastructure.Email;

/// <summary>Turns a named HTML template plus placeholder values into a body.</summary>
public interface IEmailTemplateRenderer
{
    /// <summary>
    /// Renders <c>Email/Templates/{templateName}.html</c>, substituting each
    /// <c>{{Key}}</c> placeholder.
    /// </summary>
    /// <exception cref="FileNotFoundException">No such template.</exception>
    Task<string> RenderAsync(
        string templateName,
        IReadOnlyDictionary<string, string> tokens,
        CancellationToken cancellationToken = default);
}
