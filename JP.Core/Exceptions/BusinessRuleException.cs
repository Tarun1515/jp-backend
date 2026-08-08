using System.Net;
using JP.Core.Constants;

namespace JP.Core.Exceptions;

/// <summary>
/// A domain rule rejected the operation — duplicate email, password reuse,
/// applying to the same job twice, and so on.
/// </summary>
/// <remarks>
/// This is the exception a stored procedure's THROW normally surfaces as. The
/// message is user-facing, so write it for the person on the screen.
/// </remarks>
public sealed class BusinessRuleException : AppException
{
    public BusinessRuleException(string message, string code = ErrorCodes.BusinessRuleViolated)
        : base(message, code, HttpStatusCode.BadRequest)
    {
    }

    public BusinessRuleException(string message, string code, HttpStatusCode statusCode)
        : base(message, code, statusCode)
    {
    }
}
