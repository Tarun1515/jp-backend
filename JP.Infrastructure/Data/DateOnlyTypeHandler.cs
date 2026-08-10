using System.Data;
using Dapper;

namespace JP.Infrastructure.Data;

/// <summary>
/// Maps SQL Server <c>date</c> to <see cref="DateOnly"/> in both directions.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 WITHOUT THIS, READING A CALENDAR DATE THROWS.
/// </para>
/// <para>
/// Decision 2.28 says a calendar date is a <c>date</c> column and a
/// <see cref="DateOnly"/> in C#, because a date of birth is not an instant and
/// storing it as one makes it shift by timezone. Dapper's default materialiser
/// does not convert the <see cref="DateTime"/> the reader hands back into a
/// <see cref="DateOnly"/>, so the read fails with
/// <c>Error parsing column (DOB=… - DateTime)</c>.
/// </para>
/// <para>
/// That failure is worse than it sounds. It happens AFTER the write: a teacher
/// verification request was submitted, committed, and then the read-back that
/// fetches its request number threw — so the applicant saw an error for
/// something that had actually succeeded, and a retry hit the idempotency guard
/// instead of fixing anything.
/// </para>
/// <para>
/// Registered once at startup, so it applies to every repository rather than
/// being remembered per query.
/// </para>
/// </remarks>
internal sealed class DateOnlyTypeHandler : SqlMapper.TypeHandler<DateOnly>
{
    public override DateOnly Parse(object value) => value switch
    {
        DateTime dateTime => DateOnly.FromDateTime(dateTime),
        DateOnly dateOnly => dateOnly,
        string text => DateOnly.Parse(text, System.Globalization.CultureInfo.InvariantCulture),
        _ => throw new DataException($"Cannot convert {value?.GetType().Name ?? "null"} to DateOnly."),
    };

    public override void SetValue(IDbDataParameter parameter, DateOnly value)
    {
        parameter.DbType = DbType.Date;
        parameter.Value = value.ToDateTime(TimeOnly.MinValue);
    }
}

/// <summary>Same for <see cref="TimeOnly"/>, against a <c>time</c> column.</summary>
internal sealed class TimeOnlyTypeHandler : SqlMapper.TypeHandler<TimeOnly>
{
    public override TimeOnly Parse(object value) => value switch
    {
        TimeSpan span => TimeOnly.FromTimeSpan(span),
        DateTime dateTime => TimeOnly.FromDateTime(dateTime),
        TimeOnly timeOnly => timeOnly,
        string text => TimeOnly.Parse(text, System.Globalization.CultureInfo.InvariantCulture),
        _ => throw new DataException($"Cannot convert {value?.GetType().Name ?? "null"} to TimeOnly."),
    };

    public override void SetValue(IDbDataParameter parameter, TimeOnly value)
    {
        parameter.DbType = DbType.Time;
        parameter.Value = value.ToTimeSpan();
    }
}
