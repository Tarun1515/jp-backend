using System.Net;
using JP.Core.Constants;

namespace JP.Core.Exceptions;

/// <summary>Authenticated, but not allowed to perform this action.</summary>
public sealed class ForbiddenException : AppException
{
    public ForbiddenException(string message = "You do not have permission to perform this action.",
        string code = ErrorCodes.Forbidden)
        : base(message, code, HttpStatusCode.Forbidden)
    {
    }
}
