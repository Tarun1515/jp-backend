using MailKit.Net.Smtp;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using MimeKit;
using MimeKit.Text;

namespace JP.Infrastructure.Email;

/// <summary>
/// Sends mail over SMTP via MailKit.
/// </summary>
/// <remarks>
/// Nothing about the message body is ever logged. These emails carry OTPs,
/// password-reset links and invite tokens, and a log sink is exactly the kind
/// of place those end up being retained far longer than the tokens are valid.
/// Logs record recipient, subject and outcome only.
/// </remarks>
public sealed class SmtpEmailService : IEmailService
{
    private readonly SmtpOptions _options;
    private readonly IEmailTemplateRenderer _templateRenderer;
    private readonly ILogger<SmtpEmailService> _logger;
    private readonly string _dropFolder;

    public SmtpEmailService(
        IOptions<SmtpOptions> options,
        IEmailTemplateRenderer templateRenderer,
        IHostEnvironment environment,
        ILogger<SmtpEmailService> logger)
    {
        ArgumentNullException.ThrowIfNull(options);
        ArgumentNullException.ThrowIfNull(environment);

        _options = options.Value;
        _templateRenderer = templateRenderer ?? throw new ArgumentNullException(nameof(templateRenderer));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));

        _dropFolder = Path.IsPathRooted(_options.DropFolder)
            ? _options.DropFolder
            : Path.Combine(environment.ContentRootPath, _options.DropFolder);
    }

    public async Task SendAsync(EmailMessage message, CancellationToken cancellationToken = default)
    {
        ArgumentNullException.ThrowIfNull(message);

        var mimeMessage = BuildMimeMessage(message);

        if (!_options.Enabled)
        {
            await DropToDiskAsync(mimeMessage, message, cancellationToken).ConfigureAwait(false);
            return;
        }

        using var client = new SmtpClient
        {
            Timeout = _options.TimeoutSeconds * 1000,
        };

        try
        {
            await client.ConnectAsync(_options.Host, _options.Port, _options.Security, cancellationToken)
                .ConfigureAwait(false);

            if (!string.IsNullOrWhiteSpace(_options.UserName))
            {
                var password = Environment.GetEnvironmentVariable(SmtpOptions.PasswordEnvironmentVariable);

                if (string.IsNullOrEmpty(password))
                {
                    throw new InvalidOperationException(
                        $"SMTP username is configured but the {SmtpOptions.PasswordEnvironmentVariable} " +
                        "environment variable is not set.");
                }

                await client.AuthenticateAsync(_options.UserName, password, cancellationToken)
                    .ConfigureAwait(false);
            }

            await client.SendAsync(mimeMessage, cancellationToken).ConfigureAwait(false);
            await client.DisconnectAsync(quit: true, cancellationToken).ConfigureAwait(false);

            _logger.LogInformation("Sent email to {Recipient} with subject {Subject}",
                message.To, message.Subject);
        }
        catch (Exception ex) when (ex is not OperationCanceledException)
        {
            // Surfaced, not swallowed — but note the subject only, never the body.
            _logger.LogError(ex, "Failed to send email to {Recipient} with subject {Subject}",
                message.To, message.Subject);
            throw;
        }
    }

    public async Task SendTemplateAsync(
        string templateName,
        string to,
        string subject,
        IReadOnlyDictionary<string, string> tokens,
        CancellationToken cancellationToken = default)
    {
        var htmlBody = await _templateRenderer.RenderAsync(templateName, tokens, cancellationToken)
            .ConfigureAwait(false);

        await SendAsync(
            new EmailMessage
            {
                To = to,
                Subject = subject,
                HtmlBody = htmlBody,
            },
            cancellationToken).ConfigureAwait(false);
    }

    private MimeMessage BuildMimeMessage(EmailMessage message)
    {
        var mimeMessage = new MimeMessage();
        mimeMessage.From.Add(new MailboxAddress(_options.FromName, _options.FromAddress));
        mimeMessage.To.Add(MailboxAddress.Parse(message.To));

        foreach (var cc in message.Cc)
        {
            mimeMessage.Cc.Add(MailboxAddress.Parse(cc));
        }

        foreach (var bcc in message.Bcc)
        {
            mimeMessage.Bcc.Add(MailboxAddress.Parse(bcc));
        }

        mimeMessage.Subject = message.Subject;

        var bodyBuilder = new BodyBuilder { HtmlBody = message.HtmlBody };

        bodyBuilder.TextBody = string.IsNullOrWhiteSpace(message.PlainTextBody)
            ? ToPlainText(message.HtmlBody)
            : message.PlainTextBody;

        mimeMessage.Body = bodyBuilder.ToMessageBody();
        return mimeMessage;
    }

    /// <summary>
    /// Writes the message to disk instead of sending it. Used whenever SMTP is
    /// disabled, so a developer can open the rendered email — reset link and
    /// all — without a mail provider, and without those values reaching a log.
    /// </summary>
    private async Task DropToDiskAsync(
        MimeMessage mimeMessage,
        EmailMessage message,
        CancellationToken cancellationToken)
    {
        Directory.CreateDirectory(_dropFolder);

        var fileName = $"{DateTime.UtcNow:yyyyMMdd-HHmmss}-{Guid.NewGuid():N}.eml";
        var path = Path.Combine(_dropFolder, fileName);

        await using (var stream = File.Create(path))
        {
            await mimeMessage.WriteToAsync(stream, cancellationToken).ConfigureAwait(false);
        }

        _logger.LogInformation(
            "SMTP is disabled. Email to {Recipient} with subject {Subject} written to {Path}",
            message.To, message.Subject, path);
    }

    /// <summary>Crude tag strip for the plain-text alternative part.</summary>
    private static string ToPlainText(string html)
    {
        var text = System.Text.RegularExpressions.Regex.Replace(
            html, "<[^>]+>", " ",
            System.Text.RegularExpressions.RegexOptions.None,
            TimeSpan.FromSeconds(2));

        text = System.Net.WebUtility.HtmlDecode(text);

        return System.Text.RegularExpressions.Regex.Replace(
            text, @"\s{2,}", " ",
            System.Text.RegularExpressions.RegexOptions.None,
            TimeSpan.FromSeconds(2)).Trim();
    }
}
