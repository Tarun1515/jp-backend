using FluentValidation;
using JP.Domain.Public;

namespace JP.App.Api.Validators;

/*==============================================================================
  Request validation for the PUBLIC surface. Phase 7A.

  ----------------------------------------------------------------------------
  🔴 WHY THIS FILE EXISTS, AND WHY IT IS THE FIRST OF ITS KIND ON THIS API
  ----------------------------------------------------------------------------
  JP.App.Api had no validators at all until now, and did not need any: every
  endpoint required a token, every write went through a procedure that checked
  its own arguments, and a caller who sent nonsense was a caller we could name
  and revoke.

  7A adds the first ANONYMOUS WRITE on this API, which changes the calculus:
  there is nobody to name, nobody to revoke, and whatever arrives lands in a
  queue a human has to read.

  ⚠️ FOUND BY THE SUITE, NOT BY REVIEW. public-contract.mjs probed the endpoint
  with an empty body `{}` and got HTTP 200 and a row: Name '', Email '',
  Subject '', Message ''. The DTO's `= string.Empty` initialisers meant every
  field had a valid-looking default, so the model bound cleanly and the insert
  succeeded. The brief asked for validation on this form and it was missing —
  the honeypot and the rate limit were built, and the plainest of the three was
  not.

  ----------------------------------------------------------------------------
  🔒 THE HONEYPOT IS DELIBERATELY NOT VALIDATED HERE
  ----------------------------------------------------------------------------
  There is no rule on Website, and its absence is the design. A rule reading
  "Website must be empty" would return exactly that sentence to whoever filled
  it — which teaches the author of a bot to stop filling the field, and the trap
  stops working the next day. The honeypot is decided in PublicCatalogService,
  silently, with the same 200 a real submission gets.
==============================================================================*/

/// <summary>
/// The contact form. The only anonymous write on this API.
/// </summary>
/// <remarks>
/// ⚠️ EVERY MAXIMUM MATCHES ITS COLUMN in <c>t_app_contact_enquiries</c>
/// (033_public_content.sql): Name 100, Email 256, Subject 200, Message 2000.
/// A validator that allows more than the column holds does not prevent bad
/// data — it converts a clean 400 into a 500 from a truncation error, on an
/// anonymous endpoint, which is the worst of both.
/// </remarks>
public sealed class ContactEnquiryRequestValidator : AbstractValidator<ContactEnquiryRequest>
{
    public ContactEnquiryRequestValidator()
    {
        RuleFor(x => x.Name)
            .NotEmpty().WithMessage("Please tell us your name.")
            .MaximumLength(100).WithMessage("That name is too long.");

        /*
          ⚠️ 256, matching the column — NOT the 150 the SSO's user email uses.
          The two numbers are different because the columns are, and copying the
          SSO's figure here would reject an address this table can store.
        */
        RuleFor(x => x.Email)
            .NotEmpty().WithMessage("An email address is required — it is how we reply.")
            .MaximumLength(256).WithMessage("That email address is too long.")
            .EmailAddress().WithMessage("That email address is not valid.");

        /* The same rule and the same message as the SSO's registration forms. */
        RuleFor(x => x.Mobile)
            .Matches(@"^[6-9]\d{9}$")
            .When(x => !string.IsNullOrWhiteSpace(x.Mobile))
            .WithMessage("Enter a valid 10-digit mobile number.");

        RuleFor(x => x.Subject)
            .NotEmpty().WithMessage("Please give your message a subject.")
            .MaximumLength(200).WithMessage("That subject is too long.");

        /*
          ⚠️ NO MINIMUM LENGTH, deliberately. "Call me" is seven characters and a
          perfectly real enquiry; a floor of ten would refuse it to catch junk
          that NotEmpty already catches. What stops a flood is the 3-per-hour
          limit, and what stops a bot is the honeypot — not a length rule that
          mostly inconveniences people in a hurry.
        */
        RuleFor(x => x.Message)
            .NotEmpty().WithMessage("Please write your message.")
            .MaximumLength(2000).WithMessage("Please keep the message under 2000 characters.");
    }
}
