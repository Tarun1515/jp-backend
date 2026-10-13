using System.Threading.Channels;
using JP.Infrastructure.Repositories;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace JP.Infrastructure.Services;

/// <summary>
/// Records that a public job page was viewed. Phase 7A.
/// </summary>
/// <remarks>
/// 🔴 <c>Record</c> MUST NOT BLOCK, THROW OR AWAIT. It is called from a read
/// that a visitor is waiting on, and a view counter is not worth one
/// millisecond of that wait — let alone a failure.
/// </remarks>
public interface IJobViewCounter
{
    void Record(Guid jobUid);
}

/// <summary>
/// The ONE maintained counter in a system where every other count is derived.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 WHY A STORED COUNTER IS ACCEPTABLE HERE AND NOWHERE ELSE (2.81).
/// </para>
/// <para>
/// 014's header states the rule: "<c>t_app_jobs.ApplicationCount</c> is
/// deliberately never written — a maintained counter is a second source of
/// truth that drifts, and the drift is SILENT." ViewCount breaks that rule,
/// and two things make it the exception rather than a relapse:
/// </para>
/// <para>
/// 1. ApplicationCount has rows to derive FROM. A view is not a row, and
/// making it one means a per-view hit log that grows without bound to support
/// a number nobody acts on.
/// </para>
/// <para>
/// 2. NOTHING BRANCHES ON ViewCount. It gates nothing, prices nothing and
/// orders nothing — featured ordering is derived from dates (7B), not views.
/// ApplicationCount's drift was a VISIBLE CONTRADICTION: the number stopped
/// matching the list printed beneath it. ViewCount's drift is invisible and
/// inconsequential, and 024 carries a build guard that fails if any procedure
/// ever filters or orders by it — which is the boundary the acceptance rests
/// on.
/// </para>
/// <para>
/// 🔴 THE WRITE PATH, AND THE TWO SHAPES REJECTED.
/// </para>
/// <para>
/// Rejected — a per-request UPDATE inside the detail procedure. Simplest, and
/// it breaks three things: lock contention on a hot job, every public read
/// becomes a write, and the read stops being PURE — which 2.81's caching
/// decision and 024's "the detail procedure only reads" both depend on.
/// </para>
/// <para>
/// Rejected — <c>_ = Task.Run(...)</c>. It looks batched and is not: the DI
/// scope is gone, work vanishes on shutdown, and an exception has nowhere to
/// go.
/// </para>
/// <para>
/// ⚠️ THE ACCEPTED COST: a restart loses up to one flush interval of views, on
/// a vanity number nothing branches on. The opposite of the ledger, where 2.64
/// kept every count derived and exact because it decides whether somebody can
/// post a job.
/// </para>
/// </remarks>
internal sealed class JobViewCounter : BackgroundService, IJobViewCounter
{
    /// <summary>
    /// ⚠️ BOUNDED, and dropping is the correct behaviour when it is full.
    ///
    /// An unbounded channel under a traffic spike is a memory leak that ends in
    /// an OOM — trading a process for a view count. Ten thousand pending uids
    /// is far more than a flush interval can produce legitimately, so a full
    /// channel means something abnormal, and the right answer is to lose views
    /// rather than the service.
    /// </summary>
    private const int Capacity = 10_000;

    private static readonly TimeSpan FlushInterval = TimeSpan.FromSeconds(10);

    private readonly Channel<Guid> _channel = Channel.CreateBounded<Guid>(
        new BoundedChannelOptions(Capacity)
        {
            FullMode = BoundedChannelFullMode.DropWrite,
            SingleReader = true,
            SingleWriter = false,
        });

    private readonly IServiceScopeFactory _scopeFactory;
    private readonly ILogger<JobViewCounter> _logger;

    private long _dropped;

    public JobViewCounter(IServiceScopeFactory scopeFactory, ILogger<JobViewCounter> logger)
    {
        _scopeFactory = scopeFactory;
        _logger = logger;
    }

    /// <inheritdoc />
    public void Record(Guid jobUid)
    {
        /*
          TryWrite, never WriteAsync. This is called from a request a visitor is
          waiting on: it returns immediately whether or not the channel took
          the uid, and a false means the drop counter ticks and nothing else
          happens.
        */
        if (!_channel.Writer.TryWrite(jobUid))
        {
            Interlocked.Increment(ref _dropped);
        }
    }

    protected override async Task ExecuteAsync(CancellationToken stoppingToken)
    {
        /*
          ⚠️ PeriodicTimer rather than Task.Delay in a loop: it does not drift,
          and it cancels cleanly on shutdown.
        */
        using var timer = new PeriodicTimer(FlushInterval);

        while (!stoppingToken.IsCancellationRequested)
        {
            try
            {
                await timer.WaitForNextTickAsync(stoppingToken).ConfigureAwait(false);
                await FlushAsync(stoppingToken).ConfigureAwait(false);
            }
            catch (OperationCanceledException)
            {
                break;
            }
            catch (Exception ex)
            {
                /*
                  🔴 SWALLOWED ON PURPOSE, AND LOGGED.

                  A failed flush must not kill the background service — the next
                  tick should try again. A BackgroundService whose ExecuteAsync
                  throws stops silently for the life of the process, and the
                  only symptom would be view counts that quietly stop moving.
                */
                _logger.LogError(ex, "A job-view flush failed. Counting continues; these views are lost.");
            }
        }

        /*
          One last flush on the way down, so an orderly shutdown keeps the views
          already in the channel. A kill -9 still loses them, which is the cost
          2.81 accepted.
        */
        try
        {
            await FlushAsync(CancellationToken.None).ConfigureAwait(false);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "The final job-view flush failed on shutdown.");
        }
    }

    private async Task FlushAsync(CancellationToken cancellationToken)
    {
        /*
          Drain what is there and COALESCE BY UID. A job viewed two hundred
          times in one window becomes one row with +200, which is the whole
          point of batching: one page latch taken once instead of two hundred
          updates queueing for it.
        */
        var batch = new Dictionary<Guid, int>();

        while (_channel.Reader.TryRead(out var jobUid))
        {
            batch[jobUid] = batch.TryGetValue(jobUid, out var count) ? count + 1 : 1;
        }

        var dropped = Interlocked.Exchange(ref _dropped, 0);

        if (dropped > 0)
        {
            _logger.LogWarning(
                "The job-view channel was full and dropped {Dropped} view(s). That is a traffic "
                + "spike or a stalled flush — the counter is a vanity number, so views are dropped "
                + "rather than memory grown.", dropped);
        }

        if (batch.Count == 0) return;

        /*
          🔴 ITS OWN SCOPE. A BackgroundService is a singleton and the
          repository is scoped — resolving it from the root provider is the
          classic captive-dependency bug, and with a DbConnection on the end of
          it the symptom is a connection held for the life of the process.
        */
        using var scope = _scopeFactory.CreateScope();

        var repository = scope.ServiceProvider.GetRequiredService<IPublicRepository>();

        var updated = await repository.IncrementJobViewsAsync(batch, cancellationToken)
            .ConfigureAwait(false);

        _logger.LogDebug(
            "Flushed views for {Jobs} job(s); {Updated} row(s) updated.", batch.Count, updated);
    }
}
