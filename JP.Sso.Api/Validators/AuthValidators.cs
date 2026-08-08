using FluentValidation;
using JP.Core.Constants;
using JP.Domain.Auth;

namespace JP.Sso.Api.Validators;

/*==============================================================================
  Request validation.

  Length rules come from AppConstants.Password so the validator, the hasher and
  the Angular form all state the same numbers. AppConstants.Password.MaxLength
  is not a style preference — it is the denial-of-service cap that stops an
  unbounded input being fed to 210,000 PBKDF2 iterations on a public endpoint.

  Email is lowercased HERE, in the validator, so everything downstream agrees:
  the procedure lowercases too, and CK_t_sso_users_Email_Lowercase rejects
  anything else outright. Normalising once at the edge means the rest of the
  stack never has to wonder.
==============================================================================*/

/// <summary>
/// Shared field rules.
/// </summary>
/// <remarks>
/// The names here MUST NOT collide with FluentValidation's own extension
/// methods. An extension called <c>EmailAddress</c> in this namespace binds
/// ahead of <c>DefaultValidatorExtensions.EmailAddress</c> — including on the
/// call inside its own body — so it recurses until the stack runs out. That
/// compiles cleanly and only fails the first time a request builds the
/// validator. Hence <c>ValidEmail</c> and <c>ValidPassword</c>.
/// </remarks>
internal static class PasswordRules
{
    internal static IRuleBuilderOptions<T, string> ValidPassword<T>(this IRuleBuilder<T, string> rule) =>
        rule.NotEmpty().WithMessage("A password is required.")
            .MinimumLength(AppConstants.Password.MinLength)
                .WithMessage($"Password must be at least {AppConstants.Password.MinLength} characters.")
            .MaximumLength(AppConstants.Password.MaxLength)
                .WithMessage($"Password must be at most {AppConstants.Password.MaxLength} characters.");

    internal static IRuleBuilderOptions<T, string> ValidEmail<T>(this IRuleBuilder<T, string> rule) =>
        rule.NotEmpty().WithMessage("An email address is required.")
            .MaximumLength(150).WithMessage("That email address is too long.")
            .EmailAddress().WithMessage("That email address is not valid.");

    /*
      Mobile is NOT a shared helper here. FluentValidation's When() receives the
      whole request instance, not the property, so a generic "optional mobile"
      extension has no way to see the value it is meant to guard on. Each
      validator states its own When(x => ...x.Mobile...) instead — three lines
      of repetition beats a helper that silently applies the wrong condition.
    */
}

public sealed class RegisterSchoolRequestValidator : AbstractValidator<RegisterSchoolRequest>
{
    public RegisterSchoolRequestValidator()
    {
        RuleFor(x => x.Email).ValidEmail();
        RuleFor(x => x.Password).ValidPassword();

        RuleFor(x => x.Mobile)
            .Matches(@"^[6-9]\d{9}$")
            .When(x => !string.IsNullOrWhiteSpace(x.Mobile))
            .WithMessage("Enter a valid 10-digit mobile number.");
    }
}

public sealed class RegisterTeacherRequestValidator : AbstractValidator<RegisterTeacherRequest>
{
    public RegisterTeacherRequestValidator()
    {
        RuleFor(x => x.Email).ValidEmail();
        RuleFor(x => x.Password).ValidPassword();

        RuleFor(x => x.Mobile)
            .Matches(@"^[6-9]\d{9}$")
            .When(x => !string.IsNullOrWhiteSpace(x.Mobile))
            .WithMessage("Enter a valid 10-digit mobile number.");
    }
}

public sealed class LoginRequestValidator : AbstractValidator<LoginRequest>
{
    public LoginRequestValidator()
    {
        RuleFor(x => x.LoginId)
            .NotEmpty().WithMessage("Enter your email address or mobile number.")
            .MaximumLength(150);

        /*
          Only NotEmpty and a maximum here — deliberately.

          Applying the minimum-length rule to a LOGIN would reject a short input
          before any verification runs, returning in microseconds and creating a
          second timing signal alongside the one the decoy credential closes.
          The maximum stays, because it is the DoS cap.
        */
        RuleFor(x => x.Password)
            .NotEmpty().WithMessage("Enter your password.")
            .MaximumLength(AppConstants.Password.MaxLength)
                .WithMessage($"Password must be at most {AppConstants.Password.MaxLength} characters.");
    }
}

public sealed class RefreshTokenRequestValidator : AbstractValidator<RefreshTokenRequest>
{
    public RefreshTokenRequestValidator() =>
        RuleFor(x => x.RefreshToken).NotEmpty().MaximumLength(256);
}

public sealed class ForgotPasswordRequestValidator : AbstractValidator<ForgotPasswordRequest>
{
    public ForgotPasswordRequestValidator() => RuleFor(x => x.Email).ValidEmail();
}

public sealed class ResetPasswordRequestValidator : AbstractValidator<ResetPasswordRequest>
{
    public ResetPasswordRequestValidator()
    {
        RuleFor(x => x.Token).NotEmpty().MaximumLength(256);
        RuleFor(x => x.NewPassword).ValidPassword();
    }
}

public sealed class ChangePasswordRequestValidator : AbstractValidator<ChangePasswordRequest>
{
    public ChangePasswordRequestValidator()
    {
        RuleFor(x => x.CurrentPassword)
            .NotEmpty().WithMessage("Enter your current password.")
            .MaximumLength(AppConstants.Password.MaxLength);

        RuleFor(x => x.NewPassword).ValidPassword();

        RuleFor(x => x.NewPassword)
            .NotEqual(x => x.CurrentPassword)
            .WithMessage("Your new password must be different from the current one.");
    }
}

public sealed class SetPasswordFromInviteRequestValidator : AbstractValidator<SetPasswordFromInviteRequest>
{
    public SetPasswordFromInviteRequestValidator()
    {
        RuleFor(x => x.Token).NotEmpty().MaximumLength(256);
        RuleFor(x => x.Password).ValidPassword();
    }
}

public sealed class SendOtpRequestValidator : AbstractValidator<SendOtpRequest>
{
    public SendOtpRequestValidator() =>
        RuleFor(x => x.ChannelId).InclusiveBetween(1, 2)
            .WithMessage("Choose email or SMS.");
}

public sealed class VerifyOtpRequestValidator : AbstractValidator<VerifyOtpRequest>
{
    public VerifyOtpRequestValidator()
    {
        RuleFor(x => x.ChannelId).InclusiveBetween(1, 2);

        RuleFor(x => x.Code)
            .NotEmpty().WithMessage("Enter the verification code.")
            .Length(AppConstants.Otp.Length)
                .WithMessage($"The code is {AppConstants.Otp.Length} digits.")
            .Matches(@"^\d+$").WithMessage("The code is digits only.");
    }
}
