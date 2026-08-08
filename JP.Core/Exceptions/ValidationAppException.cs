using System.Net;
using JP.Core.Constants;

namespace JP.Core.Exceptions;

/// <summary>
/// Input failed validation. Carries per-field messages so the Angular form can
/// mark the individual controls rather than showing one banner.
/// </summary>
public sealed class ValidationAppException : AppException
{
    public ValidationAppException(IDictionary<string, string[]> errors,
        string message = "One or more fields are invalid.")
        : base(message, ErrorCodes.ValidationFailed, HttpStatusCode.BadRequest)
    {
        Errors = errors;
    }

    public ValidationAppException(string field, string error)
        : this(new Dictionary<string, string[]>(StringComparer.OrdinalIgnoreCase)
        {
            [field] = [error],
        })
    {
    }

    /// <summary>Field name to the messages describing what is wrong with it.</summary>
    public IDictionary<string, string[]> Errors { get; }
}
