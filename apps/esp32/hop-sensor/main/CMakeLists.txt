# The `main` component: the ESP-IDF app entrypoint (app_main). It calls libhop through the C ABI, so
# it depends on the `libhop` component (which carries hop.h + the cross-compiled static library).
idf_component_register(
    SRCS "hop_main.c"
    INCLUDE_DIRS "."
    REQUIRES libhop
)
