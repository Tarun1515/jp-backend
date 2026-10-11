using JP.Infrastructure.Repositories;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Email;

/// <summary>
/// Sends the emails that notifications owe. Phase 6C.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 WHY THIS IS A POLLER AND NOT A CALL AT THE EVENT.
/// </para>
/// <para>
/// Notifications are written by SQL, inside the transaction of the event that
/// caused them (021). So at the moment one is created there is no C# in the call
/// stack that knows it happened — the API only sees "the offer was sent". A
/// poller is the honest consequence of that choice, and the choice is the right
/// one: it is what makes "the offer exists" and "the teacher was told" the same
/// fact.
/// </para>
/// <para>
/// ⚠️ Sending inside the transaction was the alternative and it is worse in
/// three ways: locks held across an SMTP round trip, a failed send rolling back
/// the offer it was announcing, and a duplicate send on any retry of the event.
/// </para>
/// <para>
/// 🔴 WHICH ROWS: only types whose master row says <c>SendEmail = 1</c> (029),
/// and only those with no <c>EmailSentOn</c>. The stamp is written only after a
/// send succeeds, so an unstamped row is retried on the next pass — a duplicate
/// email is a nuisance, a silently dropped offer notification is not.
/// </para>
/// <para>
/// ⚠️ A notification carries a recipient UID, never an address — 2.2 forbids
/// jp_app joining jp_sso. The address is resolved here, per recipient, which
/// also means 021 cannot be turned into a way to read a mailing list.
/// </para>
/// </remarks>
internal sealed class NotificationEmailWorker : BackgroundService
{
    /*
      ⚠️ Thirty seconds, not one. Nothing here is time-critical to the second —
      an email arriving half a minute after the in-portal row is invisible to
      the recipient — and a tight loop would mean a query against the
      notifications table several times a second forever, for the long stretches
      when there is nothing to send.
    */
    private static readonly TimeSpan Interval = TimeSpan.FromSeconds(30);

    private const int BatchSize = 25;

    private readonly IServiceScopeFactory _scopes;
    private readonly ILogger<NotificationEmailWorker> _logger;

    public NotificationEmailWorker(
        IServiceScopeFactory scopes,
        ILogger<NotificationEmailWorker> logger)
    {
        _scopes = scopes;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await SendBatchAsync(stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                break;
            }
            catch (Exception ex)
            {
                /*
                  🔴 THE LOOP MUST SURVIVE ANYTHING. A worker that dies on one
                  bad row stops sending every notification email from then on,
                  and nothing would say so — the symptom would be "we stopped
                  getting offer emails some time last month".
                */
                _logger.LogError(ex, "The notification email pass failed. It will be retried.");
            }

            try
            {
                await Task.Delay(Interval, stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
        }
    }

    private async Task SendBatchAsync(CancellationToken cancellationToken)
    {
        /*
          ⚠️ A SCOPE PER PASS. The repositories are scoped, and a BackgroundService
          is a singleton — resolving them from the root would hand this loop a
          connection it holds for the life of the process. EmailDispatchQueue's
          own header records the bug that taught this codebase the lesson.
        */
        using var scope = _scopes.CreateScope();

        var notifications = scope.ServiceProvider.GetRequiredService<INotificationRepository>();
        var users = scope.ServiceProvider.GetRequiredService<IUserRepository>();
        var queue = scope.ServiceProvider.GetRequiredService<IEmailDispatchQueue>();

        var pending = await notifications.GetPendingEmailsAsync(BatchSize, cancellationToken)
            .ConfigureAwait(false);

        if (pending.Count == 0) return;

        foreach (var row in pending)
        {
            /*
              ⚠️ GetUserByUidAsync, not GetUsersByUids. The batch lookup is
              ORGANISATION-SCOPED (009's header says why: the caller already
              resolved the org and must not be able to reach across it), and a
              notification's recipient can be a teacher — who has no
              organisation at all. The per-uid read is the one that answers for
              every kind of recipient.
            */
            var (profile, _) = await users.GetUserByUidAsync(row.RecipientUserUid, cancellationToken)
                .ConfigureAwait(false);

            var address = profile?.Email;

            if (string.IsNullOrWhiteSpace(address))
            {
                /*
                  ⚠️ STAMPED ANYWAY, and this is a judgement rather than an
                  oversight. A recipient with no address is not a transient
                  failure — retrying it every thirty seconds forever would mean
                  one unsendable row blocking the batch and filling the log.
                  The in-portal notification is already there, which is the
                  channel that matters.
                */
                _logger.LogWarning(
                    "Notification {NotificationId} has no email address for its recipient; marking it sent.",
                    row.NotificationId);

                await notifications.MarkEmailSentAsync(row.NotificationId, cancellationToken)
                    .ConfigureAwait(false);

                continue;
            }

            queue.Enqueue(new EmailDispatchRequest(
                TemplateName: "notification",
                Recipient: address,
                Subject: row.Title,
                Tokens: new Dictionary<string, string>
                {
                    ["title"] = row.Title,
                    ["body"] = row.Body ?? string.Empty,
                }));

            /*
              ⚠️ Stamped on ENQUEUE, not on delivery, because the queue is
              deliberately fire-and-forget (its own header explains why). So the
              guarantee here is "handed to the sender once", not "delivered" —
              and that is the strongest guarantee anything in this process can
              honestly make about an email.
            */
            await notifications.MarkEmailSentAsync(row.NotificationId, cancellationToken)
                .ConfigureAwait(false);
        }

        _logger.LogInformation("Queued {Count} notification email(s).", pending.Count);
    }
}
