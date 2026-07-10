# The `libhop` ESP-IDF component (core-ffi-03): wraps the cross-compiled `minimal` libhop static
# library (built by ../../build-libhop-esp.sh) as a prebuilt library the app links against, and
# exposes the generated C ABI header (hop.h) as this component's public include dir.
#
# Layout (populated by build-libhop-esp.sh; both are .gitignored placeholders until then):
#   include/hop.h   - the generated cbindgen header (copied from sdk/hop.h)
#   lib/libhop.a    - libhop cross-compiled for the selected chip's Rust target
#
# The register call has no SRCS: this component contributes a header include path and a prebuilt
# archive. libhop is pure Rust + core algorithms (no OS calls beyond alloc), so it links cleanly into
# an ESP-IDF image once the archive is built for the matching target triple.

idf_component_register(
    INCLUDE_DIRS "include"
)

set(LIBHOP_ARCHIVE "${COMPONENT_DIR}/lib/libhop.a")

if(EXISTS "${LIBHOP_ARCHIVE}")
    # Link the prebuilt archive into the app. INTERFACE so consumers of this component pick it up.
    target_link_libraries(${COMPONENT_LIB} INTERFACE "${LIBHOP_ARCHIVE}")
else()
    message(WARNING
        "libhop archive not found at ${LIBHOP_ARCHIVE}. "
        "Run ../../build-libhop-esp.sh (with your target, e.g. esp32c3) before `idf.py build`.")
endif()
