using FluentValidation;
using JP.Core.Common;
using Microsoft.AspNetCore.Mvc;
using Microsoft.AspNetCore.Mvc.Filters;

namespace JP.Infrastructure.Filters;

/*==============================================================================
  Runs the FluentValidation validators for every bound action argument.

  ----------------------------------------------------------------------------
  WHY A FILTER RATHER THAN FluentValidation.AspNetCore
  ----------------------------------------------------------------------------
  The FluentValidation.AspNetCore auto-validation package is DEPRECATED by its
  own maintainers (11.3.0 is the last release; the README recommends moving
  off it). Taking a dependency on an abandoned package to save twenty lines is
  not a trade worth making on the authentication surface.

  ----------------------------------------------------------------------------
  WHY IT SHORT-CIRCUITS ITSELF INSTEAD OF ADDING TO ModelState
  ----------------------------------------------------------------------------
  [ApiController]'s automatic 400 comes from ModelStateInvalidFilter, which
  runs at Order = -2000 — BEFORE this one. Adding errors to ModelState here
  would be too late: the framework has already decided the model was fine and
  the action would run anyway. So this filter produces the response itself,
  in exactly the shape InvalidModelStateResponseFactory produces, and both
  paths therefore return the same envelope.
==============================================================================*/

/// <summary>
/// Validates action arguments with any registered <see cref="IValidator{T}"/>.
/// </summary>
public sealed class FluentValidationFilter : IAsyncActionFilter
{
    private readonly IServiceProvider _services;

    public FluentValidationFilter(IServiceProvider services) => _services = services;

    public async Task OnActionExecutionAsync(ActionExecutingContext context, ActionExecutionDelegate next)
    {
        ArgumentNullException.ThrowIfNull(context);
        ArgumentNullException.ThrowIfNull(next);

        Dictionary<string, List<string>>? failures = null;

        foreach (var argument in context.ActionArguments.Values)
        {
            if (argument is null)
            {
                continue;
            }

            // IValidator<T> is resolved by the argument's RUNTIME type, so a
            // validator registered for the concrete request class is found
            // without the action having to declare anything.
            var validatorType = typeof(IValidator<>).MakeGenericType(argument.GetType());

            if (_services.GetService(validatorType) is not IValidator validator)
            {
                continue;
            }

            var validationContext = new ValidationContext<object>(argument);

            var result = await validator
                .ValidateAsync(validationContext, context.HttpContext.RequestAborted)
                .ConfigureAwait(false);

            if (result.IsValid)
            {
                continue;
            }

            failures ??= new Dictionary<string, List<string>>(StringComparer.OrdinalIgnoreCase);

            foreach (var error in result.Errors)
            {
                if (!failures.TryGetValue(error.PropertyName, out var messages))
                {
                    messages = [];
                    failures[error.PropertyName] = messages;
                }

                messages.Add(error.ErrorMessage);
            }
        }

        if (failures is not null)
        {
            var errors = failures.ToDictionary(
                pair => pair.Key,
                pair => pair.Value.ToArray(),
                StringComparer.OrdinalIgnoreCase);

            context.Result = new BadRequestObjectResult(ApiResponse.ValidationFailure(errors));

            return;
        }

        await next().ConfigureAwait(false);
    }
}
