#ifndef MONITOROS_IMAC5K_KMS_H
#define MONITOROS_IMAC5K_KMS_H

#include <stdint.h>

#include <xf86drmMode.h>

#define MONITOROS_WIDTH 5120u
#define MONITOROS_HEIGHT 2880u
#define MONITOROS_TILE_WIDTH 2560u

struct monitoros_scanout_target {
    uint32_t connector_id;
    uint32_t crtc_id;
    drmModeModeInfo mode;
};

int monitoros_find_scanout_target(int fd,
                                  struct monitoros_scanout_target *target);
int monitoros_restore_crtc(int fd,
                           const struct monitoros_scanout_target *target,
                           const drmModeCrtc *previous);

#endif
