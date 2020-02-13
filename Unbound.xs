#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#include <unbound.h>    /* unbound API */
#include <fcntl.h>
#include <stdio.h>
#include <string.h>

// Perl does define a STRINGIFY macro that does the same thing,
// but that may or may not be intended for public use. So:
#define MY_STRINGIFY_BACKEND(s) #s
#define MY_STRINGIFY(s) MY_STRINGIFY_BACKEND(s)

#define HAS_WHY_BOGUS           (UNBOUND_VERSION_MAJOR > 1 || UNBOUND_VERSION_MINOR > 4)
#define HAS_TTL                 (UNBOUND_VERSION_MAJOR > 1 || UNBOUND_VERSION_MINOR > 4 || UNBOUND_VERSION_MICRO > 19)
#define HAS_UB_CTX_ADD_TA_AUTR  (UNBOUND_VERSION_MAJOR > 1 || UNBOUND_VERSION_MINOR > 5)
#define HAS_UB_VERSION          (UNBOUND_VERSION_MAJOR > 1 || UNBOUND_VERSION_MINOR > 4 || UNBOUND_VERSION_MICRO >= 15)

#define BUILT_UNBOUND_VERSION MY_STRINGIFY(UNBOUND_VERSION_MAJOR) "." MY_STRINGIFY(UNBOUND_VERSION_MINOR) "." MY_STRINGIFY(UNBOUND_VERSION_MICRO)

SV* _ub_result_to_svhv_and_free (struct ub_result* result) {
    SV *val;

    AV *data = newAV();
    unsigned int i = 0;

    if (result->data != NULL) {
        while (result->data[i] != NULL) {
            val = newSVpvn(result->data[i], result->len[i]);
            av_push(data, val);
            i++;
        }
    }

    HV * rh = newHV();

    val = newSVpv(result->qname, 0);
    hv_stores(rh, "qname", val);

    val = newSViv(result->qtype);
    hv_stores(rh, "qtype", val);

    val = newSViv(result->qclass);
    hv_stores(rh, "qclass", val);

    hv_stores(rh, "data", newRV_inc((SV *)data));

    val = newSVpv(result->canonname, 0);
    hv_stores(rh, "canonname", val);

    val = newSViv(result->rcode);
    hv_stores(rh, "rcode", val);

    val = newSViv(result->havedata);
    hv_stores(rh, "havedata", val);

    val = newSViv(result->nxdomain);
    hv_stores(rh, "nxdomain", val);

    val = newSViv(result->secure);
    hv_stores(rh, "secure", val);

    val = newSViv(result->bogus);
    hv_stores(rh, "bogus", val);

    hv_stores(rh, "why_bogus",
#if HAS_WHY_BOGUS
        newSVpv(result->why_bogus, 0)
#else
        &PL_sv_undef
#endif
    );

    hv_stores(rh, "ttl",
#if HAS_TTL
        newSViv(result->ttl)
#else
        &PL_sv_undef
#endif
    );

    val = newSVpvn(result->answer_packet, result->answer_len);
    hv_stores(rh, "answer_packet", val);

    ub_resolve_free(result);

    return (SV *)rh;
}

void _async_resolve_callback(void* mydata, int err, struct ub_result* result) {
    SV *result_sv = (SV *) mydata;

    if (err) {
        SvUPGRADE( result_sv, SVt_IV );
        SvIV_set( result_sv, err );
        SvIOK_on( result_sv );
    }
    else {
        SV * svres = _ub_result_to_svhv_and_free(result);

        SvUPGRADE( result_sv, SVt_RV );
        SvRV_set( result_sv, svres );
        SvROK_on( result_sv );
    }

    return;
}

MODULE = DNS::Unbound           PACKAGE = DNS::Unbound

PROTOTYPES: DISABLE

struct ub_ctx*
_create_context()
    CODE:
        struct ub_ctx* my_ctx = ub_ctx_create();

        if (!my_ctx) {
            croak("Failed to create Unbound context!");
        }

        RETVAL = my_ctx;
    OUTPUT:
        RETVAL

int
_ub_ctx_set_option( struct ub_ctx *ctx, const char* opt, const char* val)
    CODE:
        RETVAL = ub_ctx_set_option(ctx, opt, val);
    OUTPUT:
        RETVAL

void
_ub_ctx_debuglevel( struct ub_ctx *ctx, int d )
    CODE:
        ub_ctx_debuglevel(ctx, d);

void
_ub_ctx_debugout( struct ub_ctx *ctx, int fd, const char *mode )
    CODE:
        FILE *fstream;

        // Since libunbound does equality checks against stderr,
        // let’s ensure we use that same pointer.
        if (fd == fileno(stderr)) {
            fstream = stderr;
        }
        else if (fd == fileno(stdout)) {
            fstream = stdout;
        }
        else {

            // Linux doesn’t care, but MacOS will segfault if you
            // setvbuf() on an append stream opened on a non-append fd.
            fstream = fdopen( fd, mode );

            if (fstream == NULL) {
                fprintf(stderr, "fdopen failed!!\n");
            }

            setvbuf(fstream, NULL, _IONBF, 0);
        }

        ub_ctx_debugout( ctx, fstream );

const char*
_get_fd_mode_for_fdopen(int fd)
    CODE:
        int flags = fcntl( fd, F_GETFL );

        if ( flags == -1 ) {
            SETERRNO( errno, 0 );
            RETVAL = "";
        }
        else {
            RETVAL = (flags & O_APPEND) ? "a" : "w";
        }
    OUTPUT:
        RETVAL


SV*
_ub_ctx_get_option( struct ub_ctx *ctx, const char* opt)
    CODE:
        char *str;

        int fate = ub_ctx_get_option(ctx, opt, &str);

        if (fate) {

            // On failure, return a plain SV that gives the error.
            RETVAL = newSViv(fate);
        }
        else {
            SV *val = newSVpv(str, 0);

            // On success, return a reference to an SV that gives the value.
            RETVAL = newRV_inc(val);
        }

        free(str);
    OUTPUT:
        RETVAL

int
_ub_ctx_add_ta( struct ub_ctx *ctx, char *ta )
    CODE:
        RETVAL = ub_ctx_add_ta( ctx, ta );
    OUTPUT:
        RETVAL

#if HAS_UB_CTX_ADD_TA_AUTR
int
_ub_ctx_add_ta_autr( struct ub_ctx *ctx, char *fname )
    CODE:
        RETVAL = ub_ctx_add_ta_autr( ctx, fname );
    OUTPUT:
        RETVAL

#endif

int
_ub_ctx_resolvconf( struct ub_ctx *ctx, SV *fname_sv )
    CODE:
        char *fname = SvOK(fname_sv) ? SvPV_nolen(fname_sv) : NULL;

        RETVAL = ub_ctx_resolvconf( ctx, fname );
    OUTPUT:
        RETVAL

int
_ub_ctx_hosts( struct ub_ctx *ctx, SV *fname_sv )
    CODE:
        char *fname = SvOK(fname_sv) ? SvPV_nolen(fname_sv) : NULL;

        RETVAL = ub_ctx_hosts( ctx, fname );
    OUTPUT:
        RETVAL

int
_ub_ctx_add_ta_file( struct ub_ctx *ctx, char *fname )
    CODE:
        RETVAL = ub_ctx_add_ta_file( ctx, fname );
    OUTPUT:
        RETVAL

int
_ub_ctx_trustedkeys( struct ub_ctx *ctx, char *fname )
    CODE:
        RETVAL = ub_ctx_trustedkeys( ctx, fname );
    OUTPUT:
        RETVAL

const char *
_ub_strerror( int err )
    CODE:
        RETVAL = ub_strerror(err);
    OUTPUT:
        RETVAL

int
_ub_ctx_async( struct ub_ctx *ctx, int dothread )
    CODE:
        RETVAL = ub_ctx_async( ctx, dothread );
    OUTPUT:
        RETVAL

int
_ub_poll( struct ub_ctx *ctx )
    CODE:
        RETVAL = ub_poll(ctx);
    OUTPUT:
        RETVAL

int
_ub_wait( struct ub_ctx *ctx )
    CODE:
        RETVAL = ub_wait(ctx);
    OUTPUT:
        RETVAL

int
_ub_process( struct ub_ctx *ctx )
    CODE:
        RETVAL = ub_process(ctx);
    OUTPUT:
        RETVAL

#if UNBOUND_VERSION_MAJOR > 1 || UNBOUND_VERSION_MINOR > 3
int
_ub_cancel( struct ub_ctx *ctx, int async_id )
    CODE:
        RETVAL = ub_cancel(ctx, async_id);
    OUTPUT:
        RETVAL

#endif

int
_ub_fd( struct ub_ctx *ctx )
    CODE:
        RETVAL = ub_fd(ctx);
    OUTPUT:
        RETVAL

SV*
_resolve_async( struct ub_ctx *ctx, const char *name, int type, int class, SV *result )
    CODE:
        int async_id = 0;

        // A few different approaches were tried here, including passing
        // coderefs to ub_resolve_async, but the one thing that seems to
        // work is passing a pointer to the result SV, which the async
        // callback then receives; that callback then populates the SV
        // with either the result hashref (success) or the failure number.
        // This does mean that it has to be Perl that checks for whether
        // the result SV is populated--which seems to work just fine.

        int reserr = ub_resolve_async(
            ctx,
            name, type, class,
            (void *) result, _async_resolve_callback, &async_id
        );

        AV *ret = newAV();
        av_push( ret, newSViv(reserr) );
        av_push( ret, newSViv(async_id) );

        RETVAL = newRV_inc((SV *)ret);
    OUTPUT:
        RETVAL

SV*
_resolve( struct ub_ctx *ctx, SV *name, int type, int class = 1 )
    CODE:
        struct ub_result* result;
        int retval;

        retval = ub_resolve(ctx, SvPV_nolen(name), type, class, &result);

        if (retval != 0) {
            RETVAL = newSViv(retval);
        }
        else {
            SV *svhv = _ub_result_to_svhv_and_free(result);
            RETVAL = newRV_inc(svhv);
        }

    OUTPUT:
        RETVAL

BOOT:
    HV *stash = gv_stashpvn("DNS::Unbound", 12, FALSE);
#if HAS_UB_VERSION
    newCONSTSUB(stash, "unbound_version", newSVpv( ub_version(), 0 ));
#else
    newCONSTSUB(stash, "unbound_version", newSVpv( BUILT_UNBOUND_VERSION, 0 ));
#endif

void
_destroy_context( struct ub_ctx *ctx )
    CODE:

        // Workaround for https://github.com/NLnetLabs/unbound/issues/39:
        ub_ctx_debugout(ctx, stderr);

        ub_ctx_delete(ctx);
