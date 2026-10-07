#ifndef MONITOROS_IMAC5K_AUDIO_H
#define MONITOROS_IMAC5K_AUDIO_H

#include <stdbool.h>
#include <stdint.h>

struct monitoros_audio_sink;

int monitoros_audio_sink_create(struct monitoros_audio_sink **out_sink);
void monitoros_audio_sink_destroy(struct monitoros_audio_sink *sink);

bool monitoros_audio_sink_master_pts(
    const struct monitoros_audio_sink *sink,
    uint64_t *source_pts_nanos);

double monitoros_audio_sink_buffer_error_ms(
    const struct monitoros_audio_sink *sink);

int monitoros_audio_self_test(void);

#endif
