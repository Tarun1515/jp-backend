using System.Net;
using JP.Core.Constants;

namespace JP.Core.Exceptions;

/// <summary>The requested record does not exist, or is soft-deleted.</summary>
/// <remarks>
/// Also the correct exception when a record exists but belongs to another
/// organisation. Answering "forbidden" there would confirm the id is real and
/// hand an attacker a way to probe for valid ids.
/// </remarks>
public sealed class NotFoundException : AppException
{
    public NotFoundException(string message = "The requested record was not found.")
        : base(message, ErrorCodes.NotFound, HttpStatusCode.NotFound)
    {
    }

    public NotFoundException(string entityName, object key)
        : base($"{entityName} '{key}' was not found.", ErrorCodes.NotFound, HttpStatusCode.NotFound)
    {
    }
}
