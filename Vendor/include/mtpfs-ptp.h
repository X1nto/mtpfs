/*
 * libmtp's internal PTP layer, exposed to Swift as its own module.
 *
 * WHY WE NEED IT
 * --------------
 * Two things live here and nowhere else:
 *
 *   1. ptp_mtp_getobjectproplist_level() — one GetObjPropList for a whole directory. The public
 *      API costs 2N+1 USB round trips for N entries (LIBMTP_Get_Children, then a GetObjectInfo
 *      *and* a GetObjPropList per child inside LIBMTP_Get_Filemetadata). ~401 blocking round
 *      trips for a 200-file folder; this replaces the per-child traffic with one transaction.
 *   2. The PTP_RC_* / PTP_OPC_* / PTP_OFC_* constants, so error mapping and property decoding
 *      use upstream's names instead of hand-copied magic numbers that can silently drift.
 *
 * WHY THE SYMBOLS ARE REACHABLE AT ALL
 * ------------------------------------
 * libmtp installs only libmtp.h (src/Makefile.am: `include_HEADERS = libmtp.h`) and filters its
 * exported symbol table with `-export-symbols libmtp.sym`. But that is a libtool *shared library*
 * flag — `ar` does not filter, so every ptp_* symbol is a plain global in the static archive we
 * link. Verify with `nm -gU Vendor/lib/libmtp.a`. ptp.c/ptp.h are copied verbatim from
 * libgphoto2 (libmtp's src/README), which is why libmtp declines to own the API — not because it
 * is unusable.
 *
 * WHY mtpfs-libmtp-config.h COMES FIRST — DO NOT REORDER
 * -----------------------------------------------------
 * PTPParams carries two iconv_t members behind
 *     #if defined(HAVE_ICONV) && defined(HAVE_LANGINFO_H)
 * and libmtp's config.h defines both on macOS. Measured: sizeof(PTPParams) is 672 with config.h
 * and 656 without — every field past that point shifts by 16 bytes. ptp_operation_issupported is
 * a static inline *in this header*, so compiling against the wrong layout would not fail to
 * build, it would silently read the wrong offsets.
 *
 * Both files are copied out of the same build tree that produced libmtp.a by
 * Scripts/build-vendor-libs.sh, which also static-asserts the two sizes. They cannot drift
 * independently.
 *
 * This is a separate module from CLibMTP so a ~4600-line header only reaches the files that
 * actually need the PTP layer.
 */

#ifndef MTPFS_PTP_H
#define MTPFS_PTP_H

#include "mtpfs-libmtp-config.h"
#include "ptp.h"

#endif /* MTPFS_PTP_H */
