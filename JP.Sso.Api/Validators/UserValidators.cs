using FluentValidation;
using JP.Domain.Roles;
using JP.Domain.Users;

namespace JP.Sso.Api.Validators;

public sealed class InviteUserRequestValidator : AbstractValidator<InviteUserRequest>
{
    public InviteUserRequestValidator()
    {
        RuleFor(x => x.Email).ValidEmail();

        RuleFor(x => x.Mobile)
            .Matches(@"^[6-9]\d{9}$")
            .When(x => !string.IsNullOrWhiteSpace(x.Mobile))
            .WithMessage("Enter a valid 10-digit mobile number.");

        RuleFor(x => x.RoleCode)
            .NotEmpty().WithMessage("Choose a role for this person.")
            .MaximumLength(50)
            .Matches("^[A-Z][A-Z0-9_]*$")
            .WithMessage("A role code is upper case letters, digits and underscores.");
    }
}

public sealed class UpdateUserStatusRequestValidator : AbstractValidator<UpdateUserStatusRequest>
{
    public UpdateUserStatusRequestValidator()
    {
        /*
          1, 2, 3, 4 and 6 only — never 5 (Locked). Locking is produced by the
          login path; an administrator suspends (4). The procedure rejects 5 as
          well, so this is the friendly half of a rule enforced in both places.
        */
        RuleFor(x => x.NewStatusId)
            .Must(id => id is 1 or 2 or 3 or 4 or 6)
            .WithMessage("Choose pending, active, rejected, suspended or resubmit-required.");

        RuleFor(x => x.RowVersion)
            .GreaterThan(0)
            .WithMessage("The record version is missing. Reload the page and try again.");

        RuleFor(x => x.Remarks).MaximumLength(500);
    }
}

public sealed class UnlockUserRequestValidator : AbstractValidator<UnlockUserRequest>
{
    public UnlockUserRequestValidator() => RuleFor(x => x.Remarks).MaximumLength(500);
}

public sealed class UserListRequestValidator : AbstractValidator<UserListRequest>
{
    public UserListRequestValidator()
    {
        RuleFor(x => x.UserTypeId).InclusiveBetween(1, 3).When(x => x.UserTypeId.HasValue);
        RuleFor(x => x.StatusId).InclusiveBetween(1, 6).When(x => x.StatusId.HasValue);
        RuleFor(x => x.Search).MaximumLength(150);

        RuleFor(x => x.ToDate)
            .GreaterThanOrEqualTo(x => x.FromDate!.Value)
            .When(x => x.FromDate.HasValue && x.ToDate.HasValue)
            .WithMessage("The end date cannot be before the start date.");

        // The procedure resolves SortBy through a CASE whitelist, so an
        // unrecognised value is harmless rather than injectable. Rejecting it
        // here just gives a clearer answer than silently sorting by CreatedOn.
        RuleFor(x => x.SortBy)
            .Must(s => s is null or "Email" or "Mobile" or "CreatedOn" or "LastLoginOn" or "StatusId")
            .WithMessage("Sort by email, mobile, created date, last login or status.");

        RuleFor(x => x.SortDirection)
            .Must(d => d is null || d.Equals("ASC", StringComparison.OrdinalIgnoreCase)
                                 || d.Equals("DESC", StringComparison.OrdinalIgnoreCase))
            .WithMessage("Sort direction is ASC or DESC.");
    }
}

public sealed class CreateRoleRequestValidator : AbstractValidator<CreateRoleRequest>
{
    public CreateRoleRequestValidator()
    {
        RuleFor(x => x.RoleCode)
            .NotEmpty().WithMessage("A role code is required.")
            .MaximumLength(50)
            .Matches("^[A-Z][A-Z0-9_]*$")
            .WithMessage("A role code is upper case letters, digits and underscores, e.g. DEPUTY_HEAD.");

        RuleFor(x => x.RoleName)
            .NotEmpty().WithMessage("A role name is required.")
            .MaximumLength(100);

        RuleFor(x => x.PermissionCodes)
            .NotEmpty().WithMessage("Choose at least one permission for this role.");

        RuleForEach(x => x.PermissionCodes)
            .NotEmpty()
            .MaximumLength(50)
            .Matches(@"^[A-Z][A-Z0-9_]*\.[A-Z][A-Z0-9_]*$")
            .WithMessage("Permission codes look like MODULE.ACTION.");
    }
}
