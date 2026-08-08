using System.Threading.Channels;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Email;

/*==============================================================================
  Background email dispatch.

  ----------------------------------------------------------------------------
  WHY THIS EXISTS — IT IS A TIMING FIX, NOT A PERFORMANCE ONE
  ----------------------------------------------------------------------------
  Forgot-password must answer in the same time whether the address has an
  account or not, or the endpoint becomes an account-existence oracle. The
  original code sent the email with Task.Run, which is off the request thread
  but NOT off the thread pool — rendering the template and writing the message
  competed with that same request's remaining continuations (serialise the
  response, write the socket).

  Measured over 30 paired requests, that showed up as a systematic +8.5 ms on
  the address that exists, about 10% of the response time. The stored procedure
  accounted for only 1.3 ms of it; the rest was the dispatch.

  Handing the work to a dedicated consumer reduces the per-request cost of
  "there was an email to send" to a TryWrite on a channel — tens of
  nanoseconds, and far below the jitter an attacker would have to see through.

  It also fixes a lifetime bug that was waiting to happen: Task.Run captured
  IEmailService from the REQUEST's DI scope and used it after that scope was
  disposed. The worker below opens its own scope per message instead.
==============================================================================*/

/// <summary>One queued message.</summary>
public sealed record EmailDispatchRequest(
    string TemplateName,
    string Recipient,
    string Subject,
    IReadOnlyDictionary<string, string> Tokens);

/// <summary>Accepts a message for sending and returns immediately.</summary>
public interface IEmailDispatchQueue
{
    /// <summary>
    /// Queues a message. Never throws and never blocks — a failure to send must
    /// not fail the request that triggered it, and must not change how long
    /// that request took.
    /// </summary>
    void Enqueue(EmailDispatchRequest request);
}

/// <inheritdoc cref="IEmailDispatchQueue"/>
public sealed class EmailDispatchQueue : IEmailDispatchQueue
{
    /*
      Bounded, because unbounded is how a mail outage becomes an out-of-memory
      crash. DropWrite rather than Wait: blocking the writer would put the
      backlog back onto the request thread, which is the whole thing this class
      exists to prevent. A drop is logged loudly — losing a password-reset email
      is bad, and silently losing one is worse.
    */
    private const int Capacity = 1000;

    private readonly Channel<EmailDispatchRequest> _channel =
        Channel.CreateBounded<EmailDispatchRequest>(new BoundedChannelOptions(Capacity)
        {
            FullMode = BoundedChannelFullMode.DropWrite,
            SingleReader = true,
            SingleWriter = false,
        });

    private readonly ILogger<EmailDispatchQueue> _logger;

    public EmailDispatchQueue(ILogger<EmailDispatchQueue> logger) => _logger = logger;

    internal ChannelReader<EmailDispatchRequest> Reader => _channel.Reader;

    public void Enqueue(EmailDispatchRequest request)
    {
        ArgumentNullException.ThrowIfNull(request);

        if (!_channel.Writer.TryWrite(request))
        {
            // Template and recipient only. Tokens carry reset links and OTP
            // values and must never reach a log.
            _logger.LogError(
                "Email queue is full ({Capacity}); dropped '{Template}' to {Recipient}.",
                Capacity, request.TemplateName, request.Recipient);
        }
    }
}

/// <summary>Drains the queue, one message at a time, for the life of the process.</summary>
public sealed class EmailDispatchWorker : BackgroundService
{
    private readonly EmailDispatchQueue _queue;
    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<EmailDispatchWorker> _logger;

    public EmailDispatchWorker(
        IEmailDispatchQueue queue,
        IServiceScopeFactory scopeFactory,
        ILogger<EmailDispatchWorker> logger)
    {
        _queue = (EmailDispatchQueue)queue;
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        await foreach (var message in _queue.Reader.ReadAllAsync(stoppingToken).ConfigureAwait(false))
        {
            try
            {
                // A fresh scope per message. IEmailService is scoped, and the
                // request that queued this has long since ended.
                using var scope = _scopeFactory.CreateScope();

                var email = scope.ServiceProvider.GetRequiredService<IEmailService>();

                await email.SendTemplateAsync(
                        message.TemplateName, message.Recipient, message.Subject,
                        message.Tokens, stoppingToken)
                    .ConfigureAwait(false);
            }
            catch (OperationCanceledException) when (stoppingToken.IsCancellationRequested)
            {
                // Shutting down. Anything still queued is lost by design — the
                // user can ask for another reset link.
                break;
            }
            catch (Exception ex)
            {
                // One bad message must not stop the queue.
                _logger.LogError(ex, "Failed to send '{Template}' email to {Recipient}.",
                    message.TemplateName, message.Recipient);
            }
        }
    }
}
