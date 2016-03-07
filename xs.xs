#define PERL_NO_GET_CONTEXT

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#define NCX_STORAGE "__NAMESPACE_CLEAN_STORAGE_XS"
#define NCX_REMOVE (&PL_sv_yes)
#define NCX_EXCLUDE (&PL_sv_no)

#ifndef hv_storehek
#define hv_storehek(hv, hek, val) \
    hv_common((hv), NULL, HEK_KEY(hek), HEK_LEN(hek), HEK_UTF8(hek), HV_FETCH_ISSTORE|HV_FETCH_JUST_SV, (val), HEK_HASH(hek))
#endif

#ifndef hv_fetchhek_flags
#define hv_fetchhek_flags(hv, hek, flags) \
    ((SV**)hv_common((hv), NULL, HEK_KEY(hek), HEK_LEN(hek), HEK_UTF8(hek), flags, NULL, HEK_HASH(hek)))
#endif

typedef struct {
    HV* storage;
    SV* marker;
} fn_marker;

static HV*
NCX_get_storage(aTHX_ HV* stash) {

    return NULL;
}

static void
NCX_foreach_sub(aTHX_ HV* stash, void (cb)(aTHX_ HE*, void*), void* data) {

}

static void
NCX_cb_get_functions(aTHX_ HE* slot, void* hv) {
    GV* gv = (GV*)HeVAL(slot);
    hv_storehek((HV*)hv, HeKEY_hek(slot), newRV_inc((SV*)GvCV(gv)));
}

static void
NCX_cb_add_marker(aTHX_ HE* slot, void* data) {
    fn_marker* m = (fn_marker*)data;

    HE* he = (HE*)hv_fetchhek_flags(m->storage, HeKEY_hek(slot), HV_FETCH_EMPTY_HE | HV_FETCH_LVALUE);

    if (HeVAL(he) == NULL) {
        HeVAL(he) = m->marker;
    }
}

static void
NCX_replace_glob(aTHX_ HV* stash, SV* name) {

}

static void
NCX_register_hook(aTHX) {
}

MODULE = namespace::clean::xs     PACKAGE = namespace::clean::xs
PROTOTYPES: DISABLE

void
import(SV* self, ...)
PPCODE:
{
    HV* stash;
    if (items > 2) {
    } else {
        stash = CopSTASH(PL_curcop);
    }

    HV* storage = NCX_get_storage(pTHX_ stash);
    fn_marker m = {storage, NCX_REMOVE};

    NCX_foreach_sub(pTHX_ stash, NCX_cb_add_marker, &m);

    XSRETURN_YES;
}

void
unimport(SV* self, ...)
PPCODE:
{
    HV* stash;
    if (items > 2) {
        SV* arg = *++SP;

        if (SvPOK(arg) && strEQ(SvPVX(arg), "-cleanee")) {
            stash = gv_stashsv(*++SP, 0);
        } else {
            croak("Unknown argument %s for unimport() call", SvPV_nolen(arg));
        }
    } else {
        stash = CopSTASH(PL_curcop);
    }

    if (stash) {
        HV* storage = NCX_get_storage(pTHX_ stash);
        fn_marker m = {storage, NCX_EXCLUDE};

        NCX_foreach_sub(pTHX_ stash, NCX_cb_add_marker, &m);
    }

    XSRETURN_YES;
}

void
clean_subroutines(SV* self, SV* package, ...)
PPCODE:
{
    HV* stash = gv_stashsv(package, 0);
    if (stash) {
        SP += 2;

        while (--items >= 2) {
            NCX_replace_glob(pTHX_ stash, POPs);
        }
    }

    XSRETURN_UNDEF;
}

void
get_functions(SV* self, SV* package)
PPCODE:
{
    HV* hv = newHV();
    
    HV* stash = gv_stashsv(package, 0);
    if (stash) {
        NCX_foreach_sub(pTHX_ stash, NCX_cb_get_functions, hv);
    }

    PUSHs(sv_2mortal(newRV_noinc((SV*)hv)));
    XSRETURN(1);
}

void
get_class_store(SV* self, SV* package)
PPCODE:
{
    HV* hv = newHV();

    HV* stash = gv_stashsv(package, 0);
    if (stash) {
        HV* storage = NCX_get_storage(pTHX_ stash);

        HV* exclude = newHV();
        hv_store(hv, "exclude", 7, newRV_noinc((SV*)exclude), 0);

        HV* remove = newHV();
        hv_store(hv, "remove", 6, newRV_noinc((SV*)remove), 0);

        hv_iterinit(storage);
        HE* he;
        while ((he = hv_iternext(storage))) {
            hv_storehek(HeVAL(he) == NCX_EXCLUDE ? exclude : remove, HeKEY_hek(he), &PL_sv_undef);
        }
    }

    PUSHs(sv_2mortal(newRV_noinc((SV*)hv)));
    XSRETURN(1);
}

