using Microsoft.AspNetCore.Builder;
using Microsoft.AspNetCore.Http;

namespace JP.Infrastructure.Middleware;

/// <summary>
/// The response headers both APIs send on everything. Phase 8A.
/// </summary>
/// <remarks>
/// <para>
/// 🔴 THESE DID NOT EXIST BEFORE 8A. Not one of them — no nosniff, no
/// referrer policy, no frame refusal, no CSP — across either API, for eight
/// phases. Nothing failed, because a missing response header never does: it
/// only changes what a browser is willing to do with an answer it already
/// has.
/// </para>
/// <para>
/// ⚠️ WHAT THESE APIS ACTUALLY SERVE decides what the headers should say.
/// Both are JSON APIs behind a token. They render no HTML, embed nothing, and
/// are never framed — so the strict answer is available here in a way it is
/// not on jp-public, which serves real pages and needs a CSP that permits its
/// own scripts.
/// </para>
/// <list type="bullet">
/// <item>
/// <c>X-Content-Type-Options: nosniff</c> — a JSON body a browser decides to
/// treat as HTML is the whole of MIME confusion. Nothing here is ever meant to
/// be interpreted as markup.
/// </item>
/// <item>
/// <c>Referrer-Policy: no-referrer</c> — a uid in a path is an identifier, and
/// a Referer header carries the whole URL to wherever the next request goes.
/// 2.47 made uids the public contract; this stops them travelling.
/// </item>
/// <item>
/// <c>X-Frame-Options: DENY</c> and <c>frame-ancestors 'none'</c> — both,
/// deliberately. The CSP directive is the modern one and the header is what
/// older browsers honour; neither is a cost.
/// </item>
/// <item>
/// <c>Content-Security-Policy: default-src 'none'; frame-ancestors 'none';
/// base-uri 'none'; form-action 'none'</c> — an API that loads nothing should
/// be allowed to load nothing. If a response here ever does render in a
/// browser, this is what stops it fetching anything.
/// </item>
/// <item>
/// <c>Cross-Origin-Resource-Policy: same-origin</c> — refuses to be embedded
/// as a subresource by another site. CORS still governs the apps' fetches,
/// which is a different question and is answered in Program.cs.
/// </item>
/// </list>
/// <para>
/// 🔴 SWAGGER IS EXEMPTED FROM THE CSP, AND ONLY FROM THE CSP. Swagger UI is
/// real HTML with its own scripts and styles, so <c>default-src 'none'</c>
/// would serve a blank page in Development — which is exactly the kind of
/// "security change that broke the thing nobody tests" this project tries not
/// to ship. The other four headers still apply to it, and Swagger is not
/// mapped outside Development at all.
/// </para>
/// <para>
/// ⚠️ NO Strict-Transport-Security HERE. It is added by <c>UseHsts</c> in
/// non-development only, which is where it belongs: an HSTS header on
/// http://localhost pins a developer's browser to HTTPS for a host that does
/// not serve it.
/// </para>
/// </remarks>
public static class SecurityHeadersMiddleware
{
    /// <summary>
    /// Adds the standard security headers to every response.
    /// </summary>
    /// <remarks>
    /// ⚠️ Set in <c>OnStarting</c> rather than before <c>next()</c>. A handler
    /// that has already begun writing cannot accept new headers, and the
    /// failure is an InvalidOperationException on a response that was
    /// otherwise fine.
    /// </remarks>
    public static IApplicationBuilder UseJpSecurityHeaders(this IApplicationBuilder app) =>
        app.Use(async (context, next) =>
        {
            context.Response.OnStarting(() =>
            {
                var headers = context.Response.Headers;

                headers["X-Content-Type-Options"] = "nosniff";
                headers["Referrer-Policy"] = "no-referrer";
                headers["X-Frame-Options"] = "DENY";
                headers["Cross-Origin-Resource-Policy"] = "same-origin";

                /*
                  Swagger's own page needs its scripts; everything else here is
                  JSON and needs nothing at all. The path check is deliberately
                  on the REQUEST path rather than the content type, because the
                  content type is not known until the body is written.
                */
                var isSwagger = context.Request.Path
                    .StartsWithSegments("/swagger", StringComparison.OrdinalIgnoreCase);

                if (!isSwagger)
                {
                    headers["Content-Security-Policy"] =
                        "default-src 'none'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";
                }

                return Task.CompletedTask;
            });

            await next().ConfigureAwait(false);
        });
}
