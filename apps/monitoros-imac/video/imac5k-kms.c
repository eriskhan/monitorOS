#include "imac5k-kms.h"

#include <stdbool.h>
#include <stdio.h>

#include <xf86drmMode.h>

static const char *connection_name(drmModeConnection connection)
{
    switch (connection) {
    case DRM_MODE_CONNECTED:
        return "connected";
    case DRM_MODE_DISCONNECTED:
        return "disconnected";
    case DRM_MODE_UNKNOWNCONNECTION:
        return "unknown";
    }

    return "invalid";
}

static uint32_t find_crtc(int fd, const drmModeRes *resources,
                          const drmModeConnector *connector)
{
    if (connector->encoder_id != 0) {
        drmModeEncoder *encoder = drmModeGetEncoder(fd, connector->encoder_id);
        if (encoder != NULL) {
            const uint32_t crtc_id = encoder->crtc_id;
            drmModeFreeEncoder(encoder);
            if (crtc_id != 0) {
                return crtc_id;
            }
        }
    }

    for (int encoder_index = 0; encoder_index < connector->count_encoders;
         ++encoder_index) {
        drmModeEncoder *encoder =
            drmModeGetEncoder(fd, connector->encoders[encoder_index]);
        if (encoder == NULL) {
            continue;
        }

        for (int crtc_index = 0; crtc_index < resources->count_crtcs;
             ++crtc_index) {
            if ((encoder->possible_crtcs & (1u << crtc_index)) != 0) {
                const uint32_t crtc_id = resources->crtcs[crtc_index];
                drmModeFreeEncoder(encoder);
                return crtc_id;
            }
        }

        drmModeFreeEncoder(encoder);
    }

    return 0;
}

static bool mode_is_target(const drmModeModeInfo *mode)
{
    return mode->hdisplay == MONITOROS_WIDTH &&
           mode->vdisplay == MONITOROS_HEIGHT;
}

int monitoros_find_scanout_target(int fd,
                                  struct monitoros_scanout_target *target)
{
    drmModeRes *resources = drmModeGetResources(fd);
    if (resources == NULL) {
        return -1;
    }

    bool found = false;

    for (int i = 0; i < resources->count_connectors; ++i) {
        drmModeConnector *connector =
            drmModeGetConnector(fd, resources->connectors[i]);
        if (connector == NULL) {
            fprintf(stderr, "warning: failed to inspect connector %u\n",
                    resources->connectors[i]);
            continue;
        }

        printf("connector %u: %s, type=%u, modes=%d\n",
               connector->connector_id, connection_name(connector->connection),
               connector->connector_type, connector->count_modes);

        if (connector->connection == DRM_MODE_CONNECTED) {
            for (int mode_index = 0; mode_index < connector->count_modes;
                 ++mode_index) {
                const drmModeModeInfo *mode = &connector->modes[mode_index];
                const bool preferred =
                    (mode->type & DRM_MODE_TYPE_PREFERRED) != 0;

                printf("  %ux%u @ %d Hz%s\n", mode->hdisplay, mode->vdisplay,
                       mode->vrefresh, preferred ? " preferred" : "");

                if (!mode_is_target(mode)) {
                    continue;
                }

                const uint32_t crtc_id =
                    find_crtc(fd, resources, connector);
                if (crtc_id == 0) {
                    fprintf(stderr,
                            "warning: 5120x2880 connector %u has no usable CRTC\n",
                            connector->connector_id);
                    continue;
                }

                if (!found || preferred) {
                    target->connector_id = connector->connector_id;
                    target->crtc_id = crtc_id;
                    target->mode = *mode;
                    found = true;
                }

                if (preferred) {
                    break;
                }
            }
        }

        drmModeFreeConnector(connector);
    }

    drmModeFreeResources(resources);
    return found ? 0 : -1;
}

int monitoros_restore_crtc(int fd,
                           const struct monitoros_scanout_target *target,
                           const drmModeCrtc *previous)
{
    uint32_t connector_id = target->connector_id;

    if (previous->mode_valid) {
        drmModeModeInfo mode = previous->mode;
        return drmModeSetCrtc(fd, previous->crtc_id, previous->buffer_id,
                              previous->x, previous->y, &connector_id, 1,
                              &mode);
    }

    return drmModeSetCrtc(fd, previous->crtc_id, 0, 0, 0, NULL, 0, NULL);
}
