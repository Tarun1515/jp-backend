using JP.Core.Constants;

namespace JP.Core.Common;

/// <summary>
/// The single response envelope for every API endpoint in the system.
/// No controller ever returns a bare DTO.
/// </summary>
/// <remarks>
/// <para>
/// Shape on the wire (System.Text.Json camel-cases these):
/// <c>{ status, code, message, data, totalRecords }</c>
/// </para>
/// <para>
/// <see cref="Code"/> is the machine-readable half of the envelope and is the
/// only field a client should branch on. <see cref="Message"/> is for humans
/// and may be reworded or localised at any time, so switching on it would be a
/// bug waiting to happen.
/// </para>
/// <para>
/// Build these with <see cref="ApiResponse"/> rather than by hand.
/// </para>
/// </remarks>
public sealed class Response<T>
{
    /// <summary><see cref="ResponseStatus.Success"/> (1) or <see cref="ResponseStatus.Failure"/> (0).</summary>
    public int Status { get; set; }

    /// <summary>
    /// Machine-readable outcome code from <see cref="ErrorCodes"/>, for example
    /// <c>ACCOUNT_PENDING</c>. Always <see langword="null"/> on success.
    /// </summary>
    public string? Code { get; set; }

    /// <summary>Human-readable message, safe to show to an end user.</summary>
    public string Message { get; set; } = string.Empty;

    /// <summary>The payload. <see langword="null"/> on failure.</summary>
    public T? Data { get; set; }

    /// <summary>
    /// Total rows matching the query before paging was applied. Meaningful on
    /// list endpoints; stays 0 elsewhere.
    /// </summary>
    public long TotalRecords { get; set; }

    /// <summary>Field-level validation errors, keyed by property name.</summary>
    public IDictionary<string, string[]>? Errors { get; set; }
}

/// <summary>Status values carried in <see cref="Response{T}.Status"/>.</summary>
public static class ResponseStatus
{
    public const int Failure = 0;
    public const int Success = 1;
}

/// <summary>
/// Factory methods for building a <see cref="Response{T}"/>.
/// </summary>
/// <remarks>
/// Named <c>ApiResponse</c> rather than the more obvious <c>Response</c>
/// because ASP.NET Core's <c>ControllerBase</c> already has a <c>Response</c>
/// property holding the <c>HttpResponse</c>. A static class of that name would
/// be shadowed inside every single controller, and <c>Response.Success(...)</c>
/// would fail to compile in the one place it is most used.
/// </remarks>
public static class ApiResponse
{
    public const string DefaultSuccessMessage = "Success";

    /// <summary>A successful response carrying a payload.</summary>
    public static Response<T> Success<T>(T data, string message = DefaultSuccessMessage) => new()
    {
        Status = ResponseStatus.Success,
        Message = message,
        Data = data,
    };

    /// <summary>A successful response with no payload.</summary>
    public static Response<object?> Success(string message = DefaultSuccessMessage) => new()
    {
        Status = ResponseStatus.Success,
        Message = message,
        Data = null,
    };

    /// <summary>
    /// A successful list response. <paramref name="totalRecords"/> is the count
    /// before paging, which the client needs to render a pager.
    /// </summary>
    public static Response<T> Paged<T>(T data, long totalRecords, string message = DefaultSuccessMessage) => new()
    {
        Status = ResponseStatus.Success,
        Message = message,
        Data = data,
        TotalRecords = totalRecords,
    };

    /// <summary>A failed response.</summary>
    public static Response<T> Failure<T>(string message, string? code = null) => new()
    {
        Status = ResponseStatus.Failure,
        Code = code,
        Message = message,
        Data = default,
    };

    /// <summary>A failed response with no payload type in play.</summary>
    public static Response<object?> Failure(string message, string? code = null) => new()
    {
        Status = ResponseStatus.Failure,
        Code = code,
        Message = message,
        Data = null,
    };

    /// <summary>A failed response carrying field-level validation errors.</summary>
    public static Response<object?> ValidationFailure(
        IDictionary<string, string[]> errors,
        string message = "One or more fields are invalid.") => new()
    {
        Status = ResponseStatus.Failure,
        Code = ErrorCodes.ValidationFailed,
        Message = message,
        Data = null,
        Errors = errors,
    };
}
