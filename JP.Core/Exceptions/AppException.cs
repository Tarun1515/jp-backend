using System.Net;
using JP.Core.Constants;

namespace JP.Core.Exceptions;

/// <summary>
/// Base for every deliberate, expected failure in the application.
/// </summary>
/// <remarks>
/// The global exception handler translates these straight into a
/// <see cref="Common.Response{T}"/> using <see cref="Code"/> and
/// <see cref="Exception.Message"/>, and the message IS shown to the end user.
/// <para>
/// Anything that is not an <see cref="AppException"/> is treated as a bug: it
/// is logged with its stack trace and returned as a generic
/// <see cref="ErrorCodes.InternalError"/> with no internal detail leaked.
/// </para>
/// </remarks>
public class AppException : Exception
{
    public AppException(string message, string code = ErrorCodes.BusinessRuleViolated,
        HttpStatusCode statusCode = HttpStatusCode.BadRequest)
        : base(message)
    {
        Code = code;
        StatusCode = statusCode;
    }

    public AppException(string message, Exception innerException,
        string code = ErrorCodes.BusinessRuleViolated,
        HttpStatusCode statusCode = HttpStatusCode.BadRequest)
        : base(message, innerException)
    {
        Code = code;
        StatusCode = statusCode;
    }

    /// <summary>Machine-readable code from <see cref="ErrorCodes"/>.</summary>
    public string Code { get; }

    /// <summary>HTTP status the response should carry.</summary>
    public HttpStatusCode StatusCode { get; }
}
