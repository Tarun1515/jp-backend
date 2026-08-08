namespace JP.Infrastructure.Email;

/// <summary>An email ready to send.</summary>
public sealed record EmailMessage
{
    public required string To { get; init; }

    public required string Subject { get; init; }

    public required string HtmlBody { get; init; }

    /// <summary>
    /// Plain-text alternative. Worth supplying: a multipart message is
    /// noticeably less likely to be treated as spam than HTML alone.
    /// </summary>
    public string? PlainTextBody { get; init; }

    public IReadOnlyList<string> Cc { get; init; } = [];

    public IReadOnlyList<string> Bcc { get; init; } = [];
}

/// <summary>Outbound email.</summary>
public interface IEmailService
{
    /// <summary>Sends a message that has already been composed.</summary>
    Task SendAsync(EmailMessage message, CancellationToken cancellationToken = default);

    /// <summary>
    /// Renders a template and sends it.
    /// </summary>
    /// <param name="templateName">
    /// File name without extension, from <c>Email/Templates</c> — for example
    /// <c>password-reset</c>.
    /// </param>
    /// <param name="to">Recipient address.</param>
    /// <param name="subject">Subject line.</param>
    /// <param name="tokens">
    /// Placeholder values. Each is substituted for <c>{{Key}}</c> in the
    /// template and HTML-encoded on the way in.
    /// </param>
    /// <param name="cancellationToken">Cancellation token.</param>
    Task SendTemplateAsync(
        string templateName,
        string to,
        string subject,
        IReadOnlyDictionary<string, string> tokens,
        CancellationToken cancellationToken = default);
}
