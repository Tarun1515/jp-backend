using System.ComponentModel.DataAnnotations;
using MailKit.Security;

namespace JP.Infrastructure.Email;

/// <summary>
/// SMTP configuration, bound from the <c>Smtp</c> section.
/// </summary>
/// <remarks>
/// The password is NOT here. Like the SQL password, it is read from an
/// environment variable (<c>SMTP_PASSWORD</c>) so nothing secret is ever
/// committed.
/// <para>
/// Client question 6 — which provider, and on whose budget — is still open, so
/// this is deliberately plain SMTP: SendGrid, SES and MSG91 all speak it, and
/// switching to a provider SDK later means replacing one class.
/// </para>
/// </remarks>
public sealed class SmtpOptions
{
    public const string SectionName = "Smtp";

    /// <summary>Environment variable holding the SMTP password.</summary>
    public const string PasswordEnvironmentVariable = "SMTP_PASSWORD";

    /// <summary>
    /// When false, nothing is sent: messages are written to
    /// <see cref="DropFolder"/> instead. This is the development default —
    /// no real provider needed, and no risk of mailing a real teacher from a
    /// dev box seeded with production-shaped data.
    /// </summary>
    public bool Enabled { get; set; }

    public string Host { get; set; } = string.Empty;

    [Range(1, 65535)]
    public int Port { get; set; } = 587;

    public SecureSocketOptions Security { get; set; } = SecureSocketOptions.StartTls;

    public string UserName { get; set; } = string.Empty;

    [Required]
    [EmailAddress]
    public string FromAddress { get; set; } = "no-reply@localhost";

    public string FromName { get; set; } = "Teacher Recruitment Portal";

    /// <summary>
    /// Where messages are written when <see cref="Enabled"/> is false.
    /// Relative paths resolve against the application content root.
    /// </summary>
    public string DropFolder { get; set; } = "App_Data/mail-drop";

    [Range(1, 300)]
    public int TimeoutSeconds { get; set; } = 30;
}
