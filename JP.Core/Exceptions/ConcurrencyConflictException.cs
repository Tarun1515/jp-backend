using System.Net;
using JP.Core.Constants;

namespace JP.Core.Exceptions;

/// <summary>
/// The RowVersion supplied did not match the stored one — another user saved
/// this record first, so the update was refused rather than silently
/// overwriting their work.
/// </summary>
public sealed class ConcurrencyConflictException : AppException
{
    public ConcurrencyConflictException(
        string message = "This record was changed by someone else. Reload and try again.")
        : base(message, ErrorCodes.ConcurrencyConflict, HttpStatusCode.Conflict)
    {
    }
}
