#define PERL_NO_GET_CONTEXT

#include "EXTERN.h"
#include "perl.h"
#include "XSUB.h"

#define NCX_STORAGE "__NAMESPACE_CLEAN_STORAGE_XS"
#define NCX_REMOVE (&PL_sv_yes)
#define NCX_EXCLUDE (&PL_sv_no)

#ifndef hv_deletehek
#define hv_deletehek(hv, hek, flags) \
    hv_common((hv), NULL, HEK_KEY(hek), HEK_LEN(hek), HEK_UTF8(hek), (flags)|HV_DELETE, NULL, HEK_HASH(hek))
#endif

#ifndef hv_storehek
#define hv_storehek(hv, hek, val) \
    hv_common((hv), NULL, HEK_KEY(hek), HEK_LEN(hek), HEK_UTF8(hek), HV_FETCH_ISSTORE|HV_FETCH_JUST_SV, (val), HEK_HASH(hek))
#endif

#ifndef hv_fetchhek_flags
#define hv_fetchhek_flags(hv, hek, flags) \
    ((SV**)hv_common((hv), NULL, HEK_KEY(hek), HEK_LEN(hek), HEK_UTF8(hek), flags, NULL, HEK_HASH(hek)))
#endif

#ifndef SvREFCNT_dec_NN
#define SvREFCNT_dec_NN SvREFCNT_dec
#endif

#ifndef GvCV_set
#define GvCV_set(gv, cv) (GvCV(gv) = cv)
#endif

#ifndef gv_init_sv
#define gv_init_sv(gv, stash, sv, flags) \
    {   STRLEN len;    \
        const char* buf = SvPV_const(sv, len);    \
        gv_init_pvn(gv, stash, buf, len, flags | SvUTF8(sv)); }
#endif

typedef struct {
    HV* storage;
    SV* marker;
} fn_marker;

static int NCX_on_scope_end_normal(aTHX_ SV* sv, MAGIC* mg);
static MGVTBL vtscope_normal = {
    NULL, NULL, NULL, NULL, NCX_on_scope_end_normal
};

static int NCX_on_scope_end_list(aTHX_ SV* sv, MAGIC* mg);
static MGVTBL vtscope_list = {
    NULL, NULL, NULL, NULL, NCX_on_scope_end_list
};

static HE*
NCX_stash_glob(aTHX_ HV* stash, SV* name) {
    HE* he = hv_fetch_ent(stash, name, 1, 0);

    if (!isGV(HeVAL(he))) return NULL;

    return he;
}

inline GV*
NCX_storage_glob(aTHX_ HV* stash) {
    SV** svp = hv_fetch(stash, NCX_STORAGE, strlen(NCX_STORAGE), 1);

    if (!isGV(*svp)) {
        gv_init_pvn((GV*)*svp, stash, NCX_STORAGE, strlen(NCX_STORAGE), GV_ADDMULTI);
    }

    return (GV*)*svp;
}

inline HV*
NCX_storage_hv(aTHX_ HV* stash) {
    GV* glob = NCX_storage_glob(pTHX_ stash);
    return GvHVn(glob);
}

static void
NCX_foreach_sub(aTHX_ HV* stash, void (cb)(aTHX_ HE*, void*), void* data) {
    STRLEN hvmax = HvMAX(stash);
    HE** hvarr = HvARRAY(stash);

    for (STRLEN bucket_num = 0; bucket_num <= hvmax; ++bucket_num) {
        for (HE* he = hvarr[bucket_num]; he; he = HeNEXT(he)) {
            if (HeVAL(he) == &PL_sv_placeholder) continue;

            GV* gv = (GV*)HeVAL(he);
            if (!isGV(gv) || (GvCV(gv) && !GvCVGEN(gv))) {
                cb(pTHX_ he, data);
            }
        }
    }
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
NCX_single_marker(aTHX_ HV* stash, SV* name, SV* marker) {
    HE* he = (HE*)hv_common(stash, name, NULL, 0, 0, HV_FETCH_EMPTY_HE | HV_FETCH_LVALUE, NULL, 0);

    if (HeVAL(he) == NULL) {
        HeVAL(he) = marker;
    }
}

#define NCX_REPLACE_PRE         \
    GV* old_gv = (GV*)HeVAL(he);\
                                \
    if (!isGV(old_gv)) {        \
        hv_deletehek(stash, HeKEY_hek(he), 0);   \
        return;                 \
    }                           \
                                \
    CV* cv = GvCVu(old_gv);     \
    if (!cv) return;            \
                                \
    GV* new_gv = (GV*)newSV(0); \

#define NCX_REPLACE_POST            \
    HeVAL(he) = (SV*)new_gv;        \
                                    \
    GP* swap = GvGP(old_gv);        \
    GvGP_set(old_gv, GvGP(new_gv)); \
    GvGP_set(new_gv, swap);         \
                                    \
    GvCV_set(old_gv, cv);           \
    GvCV_set(new_gv, NULL);         \

    // TODO: update mro all-at-once

static void
NCX_replace_glob_sv(aTHX_ HV* stash, SV* name) {
    HE* he = NCX_stash_glob(pTHX_ stash, name);
    if (!he) return;

    NCX_REPLACE_PRE;

    gv_init_sv(new_gv, stash, name, GV_ADDMULTI);

    NCX_REPLACE_POST;
}

static void
NCX_replace_glob_hek(aTHX_ HV* stash, HEK* hek) {
    HE* he = (HE*)hv_fetchhek_flags(stash, hek, 0);
    if (!he) return;

    NCX_REPLACE_PRE;

    gv_init_pvn(new_gv, stash, HEK_KEY(hek), HEK_LEN(hek), GV_ADDMULTI | HEK_UTF8(hek));

    NCX_REPLACE_POST;
}

static int
NCX_on_scope_end_normal(aTHX_ SV* sv, MAGIC* mg) {
    HV* stash = (HV*)(mg->mg_obj);
    GV* storage_gv = NCX_storage_glob(pTHX_ stash);

    HV* storage = GvHV(storage_gv);
    if (!storage) return 0;

    STRLEN hvmax = HvMAX(storage);
    HE** hvarr = HvARRAY(storage);

    SV* pl_remove = NCX_REMOVE;
    for (STRLEN bucket_num = 0; bucket_num <= hvmax; ++bucket_num) {
        for (const HE* he = hvarr[bucket_num]; he; he = HeNEXT(he)) {
            if (HeVAL(he) == pl_remove) {
                NCX_replace_glob_hek(pTHX_ stash, HeKEY_hek(he));
            }
        }
    }

    SvREFCNT_dec_NN(storage);
    GvHV(storage_gv) = NULL;

    return 0;
}

static void
NCX_register_hook_normal(aTHX_ HV* stash) {
    SV* hints = (SV*)GvHV(PL_hintgv);

    if (SvRMAGICAL(hints)) {
        MAGIC* mg;
        for (mg = SvMAGIC(hints); mg; mg = mg->mg_moremagic) {
            if (mg->mg_virtual == &vtscope_normal && mg->mg_obj == (SV*)stash) {
                return;
            }
        }
    }

    sv_magicext(hints, (SV*)stash, PERL_MAGIC_ext, &vtscope_normal, NULL, 0);
    PL_hints |= HINT_LOCALIZE_HH;
}

static int
NCX_on_scope_end_list(aTHX_ SV* sv, MAGIC* mg) {
    HV* stash = (HV*)(mg->mg_obj);
    AV* list = (AV*)(mg->mg_ptr);

    SV** items = AvARRAY(list);
    SSize_t fill = AvFILLp(list);

    while (fill-- >= 0) {
        NCX_replace_glob_sv(pTHX_ stash, *items++);
    }

    return 0;
}

static void
NCX_register_hook_list(aTHX_ HV* stash, AV* list) {
    sv_magicext((SV*)GvHV(PL_hintgv), (SV*)stash, PERL_MAGIC_ext, &vtscope_list, (const char *)list, HEf_SVKEY);
    PL_hints |= HINT_LOCALIZE_HH;
}

MODULE = namespace::clean::xs     PACKAGE = namespace::clean::xs
PROTOTYPES: DISABLE

void
import(SV* self, ...)
PPCODE:
{
    HV* stash = CopSTASH(PL_curcop);;

    ++SP;
    SV* except = NULL;
    SSize_t processed;

    for (processed = 1; processed < items; processed += 2) {
        SV* arg = *++SP;
        if (!SvPOK(arg)) break;

        const char* buf = SvPVX_const(arg);
        if (!SvCUR(arg) || buf[0] != '-') break;

        if (processed + 1 > items) {
            croak("Not enough arguments for %s option in import() call", buf);
        }

        if (strEQ(buf, "-cleanee")) {
            stash = gv_stashsv(*++SP, GV_ADD);

        } else if (strEQ(buf, "-except")) {
            except = *++SP;

        } else {
            croak("Unknown argument %s in import() call", buf);
        }
    }

    if (processed < items) {
        AV* list = newAV();
        av_extend(list, items - processed - 1);

        SV** list_data = AvARRAY(list);
        while (++processed <= items) {
            *list_data++ = POPs;
        }

        NCX_register_hook_list(pTHX_ stash, list);
        SvREFCNT_dec_NN(list); /* refcnt owned by magic now */

    } else {
        HV* storage = NCX_storage_hv(pTHX_ stash);
        if (except) {
            if (SvROK(except) && SvTYPE(SvRV(except)) == SVt_PVAV) {
                AV* except_av = (AV*)SvRV(except);
                SSize_t len = av_len(except_av);

                for (SSize_t i = 0; i <= len; ++i) {
                    SV** svp = av_fetch(except_av, i, 0);
                    if (svp) NCX_single_marker(pTHX_ stash, *svp, NCX_EXCLUDE);
                }

            } else {
                NCX_single_marker(pTHX_ stash, except, NCX_EXCLUDE);
            }
        }

        fn_marker m = {storage, NCX_REMOVE};

        NCX_foreach_sub(pTHX_ stash, NCX_cb_add_marker, &m);
        NCX_register_hook_normal(pTHX_ stash);
    }

    XSRETURN_YES;
}

void
unimport(SV* self, ...)
PPCODE:
{
    HV* stash;
    if (items > 2) {
        SP += 2;
        SV* arg = POPs;

        if (SvPOK(arg) && strEQ(SvPVX(arg), "-cleanee")) {
            stash = gv_stashsv(POPs, 0);
        } else {
            croak("Unknown argument %s in unimport() call", SvPV_nolen(arg));
        }
    } else {
        stash = CopSTASH(PL_curcop);
    }

    if (stash) {
        HV* storage = NCX_storage_hv(pTHX_ stash);
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
        SP += 3;

        while (--items >= 2) {
            NCX_replace_glob_sv(pTHX_ stash, POPs);
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
        HV* storage = NCX_storage_hv(pTHX_ stash);

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

