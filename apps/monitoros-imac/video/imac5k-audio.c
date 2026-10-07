#define _GNU_SOURCE

#include "imac5k-audio.h"

#include <alsa/asoundlib.h>
#include <errno.h>
#include <fcntl.h>
#include <netinet/in.h>
#include <poll.h>
#include <pthread.h>
#include <samplerate.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <unistd.h>

#define AUDIO_PORT 5204u
#define AUDIO_MAGIC "MOSAUD02"
#define AUDIO_HEADER_SIZE 40u
#define AUDIO_SOURCE_SAMPLE_RATE 48000u
#define AUDIO_SINK_SAMPLE_RATE 48000u
#define AUDIO_CHANNELS 2u
#define AUDIO_FORMAT_S16_LE 1u
#define AUDIO_MAX_BLOCK_FRAMES 1024u
#define AUDIO_OUTPUT_CAPACITY_FRAMES 2048u
#define AUDIO_TARGET_DELAY_FRAMES 2880L
#define AUDIO_LATENCY_US 80000u
#define AUDIO_MAX_RATE_CORRECTION_PPM 1500.0
#define AUDIO_RATE_PPM_PER_FRAME 3.0
#define AUDIO_PTS_TOLERANCE_NS 2000000ULL
#define AUDIO_CLOCK_STALE_NS 100000000ULL

struct audio_header {
    uint64_t sequence;
    uint64_t pts_nanos;
    uint32_t frame_count;
};

struct monitoros_audio_sink {
    int listener_fd;
    pthread_t thread;
    bool thread_started;
    atomic_bool shutdown;
    atomic_bool active;
    atomic_uint_fast64_t master_pts_nanos;
    atomic_uint_fast64_t master_update_monotonic_nanos;
    atomic_int_fast64_t buffer_error_frames;
};

static uint64_t monotonic_nanos(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0u;
    }

    return (uint64_t)now.tv_sec * 1000000000ULL +
           (uint64_t)now.tv_nsec;
}

static bool audio_clock_is_fresh(
    uint64_t now_nanos,
    uint64_t update_nanos)
{
    return update_nanos != 0u &&
           now_nanos >= update_nanos &&
           now_nanos - update_nanos <= AUDIO_CLOCK_STALE_NS;
}

static uint16_t read_be16(const uint8_t *bytes)
{
    return (uint16_t)(((uint16_t)bytes[0] << 8) | (uint16_t)bytes[1]);
}

static uint32_t read_be32(const uint8_t *bytes)
{
    return ((uint32_t)bytes[0] << 24) |
           ((uint32_t)bytes[1] << 16) |
           ((uint32_t)bytes[2] << 8) |
           (uint32_t)bytes[3];
}

static uint64_t read_be64(const uint8_t *bytes)
{
    uint64_t value = 0u;
    for (size_t i = 0; i < 8u; ++i) {
        value = (value << 8) | (uint64_t)bytes[i];
    }
    return value;
}

static void write_be16(uint8_t *bytes, uint16_t value)
{
    bytes[0] = (uint8_t)((value >> 8) & 0xffu);
    bytes[1] = (uint8_t)(value & 0xffu);
}

static void write_be32(uint8_t *bytes, uint32_t value)
{
    bytes[0] = (uint8_t)((value >> 24) & 0xffu);
    bytes[1] = (uint8_t)((value >> 16) & 0xffu);
    bytes[2] = (uint8_t)((value >> 8) & 0xffu);
    bytes[3] = (uint8_t)(value & 0xffu);
}

static void write_be64(uint8_t *bytes, uint64_t value)
{
    for (size_t i = 0; i < 8u; ++i) {
        const unsigned shift = (unsigned)(7u - i) * 8u;
        bytes[i] = (uint8_t)((value >> shift) & 0xffu);
    }
}

static int parse_audio_header(
    const uint8_t bytes[AUDIO_HEADER_SIZE],
    struct audio_header *header)
{
    if (memcmp(bytes, AUDIO_MAGIC, 8u) != 0) {
        return -1;
    }
    if (read_be32(bytes + 8u) != AUDIO_HEADER_SIZE) {
        return -1;
    }

    const uint32_t frame_count = read_be32(bytes + 28u);
    const uint32_t sample_rate = read_be32(bytes + 32u);
    const uint16_t channels = read_be16(bytes + 36u);
    const uint16_t format = read_be16(bytes + 38u);

    if (frame_count == 0u ||
        frame_count > AUDIO_MAX_BLOCK_FRAMES ||
        sample_rate != AUDIO_SOURCE_SAMPLE_RATE ||
        channels != AUDIO_CHANNELS ||
        format != AUDIO_FORMAT_S16_LE) {
        return -1;
    }

    header->sequence = read_be64(bytes + 12u);
    header->pts_nanos = read_be64(bytes + 20u);
    header->frame_count = frame_count;
    return 0;
}

static int create_listener(void)
{
    const int fd = socket(AF_INET6, SOCK_STREAM | SOCK_CLOEXEC, 0);
    if (fd < 0) {
        return -1;
    }

    int reuse = 1;
    int dual_stack = 0;
    if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR,
                   &reuse, sizeof(reuse)) != 0 ||
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY,
                   &dual_stack, sizeof(dual_stack)) != 0) {
        close(fd);
        return -1;
    }

    struct sockaddr_in6 address = {
        .sin6_family = AF_INET6,
        .sin6_port = htons((uint16_t)AUDIO_PORT),
        .sin6_addr = IN6ADDR_ANY_INIT,
    };
    if (bind(fd, (const struct sockaddr *)&address, sizeof(address)) != 0 ||
        listen(fd, 2) != 0) {
        close(fd);
        return -1;
    }
    return fd;
}

static int receive_exact(
    struct monitoros_audio_sink *sink,
    int fd,
    void *buffer,
    size_t size)
{
    uint8_t *bytes = buffer;
    size_t offset = 0u;

    while (offset < size) {
        if (atomic_load_explicit(&sink->shutdown, memory_order_relaxed)) {
            return -2;
        }

        const ssize_t received =
            recv(fd, bytes + offset, size - offset, 0);
        if (received > 0) {
            offset += (size_t)received;
            continue;
        }
        if (received == 0) {
            return 0;
        }
        if (errno == EINTR) {
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            continue;
        }
        return -1;
    }

    return 1;
}

static int configure_pcm(
    snd_pcm_t **out_pcm,
    snd_pcm_uframes_t *out_buffer_frames,
    snd_pcm_uframes_t *out_period_frames)
{
    const char *device = "pipewire";
    snd_pcm_t *pcm = NULL;
    int result = snd_pcm_open(
        &pcm, device, SND_PCM_STREAM_PLAYBACK, 0);
    if (result < 0) {
        fprintf(stderr,
                "speaker audio: snd_pcm_open(%s) failed: %s\n",
                device, snd_strerror(result));
        return -1;
    }

    result = snd_pcm_set_params(
        pcm,
        SND_PCM_FORMAT_S16_LE,
        SND_PCM_ACCESS_RW_INTERLEAVED,
        AUDIO_CHANNELS,
        AUDIO_SINK_SAMPLE_RATE,
        0,
        AUDIO_LATENCY_US);
    if (result < 0) {
        fprintf(stderr,
                "speaker audio: PipeWire PCM params failed: %s\n",
                snd_strerror(result));
        snd_pcm_close(pcm);
        return -1;
    }

    snd_pcm_uframes_t buffer_frames = 0u;
    snd_pcm_uframes_t period_frames = 0u;
    result = snd_pcm_get_params(pcm, &buffer_frames, &period_frames);
    if (result < 0) {
        fprintf(stderr,
                "speaker audio: snd_pcm_get_params failed: %s\n",
                snd_strerror(result));
        snd_pcm_close(pcm);
        return -1;
    }

    snd_pcm_sw_params_t *sw = NULL;
    snd_pcm_sw_params_alloca(&sw);
    result = snd_pcm_sw_params_current(pcm, sw);
    if (result >= 0) {
        snd_pcm_uframes_t threshold =
            (snd_pcm_uframes_t)AUDIO_TARGET_DELAY_FRAMES;
        if (buffer_frames > period_frames &&
            threshold > buffer_frames - period_frames) {
            threshold = buffer_frames - period_frames;
        }
        if (threshold < period_frames) {
            threshold = period_frames;
        }

        result = snd_pcm_sw_params_set_start_threshold(
            pcm, sw, threshold);
        if (result >= 0) {
            result = snd_pcm_sw_params_set_avail_min(
                pcm, sw, period_frames);
        }
        if (result >= 0) {
            result = snd_pcm_sw_params(pcm, sw);
        }
    }
    if (result < 0) {
        fprintf(stderr,
                "speaker audio: software params failed: %s\n",
                snd_strerror(result));
        snd_pcm_close(pcm);
        return -1;
    }

    result = snd_pcm_prepare(pcm);
    if (result < 0) {
        fprintf(stderr,
                "speaker audio: snd_pcm_prepare failed: %s\n",
                snd_strerror(result));
        snd_pcm_close(pcm);
        return -1;
    }

    *out_pcm = pcm;
    *out_buffer_frames = buffer_frames;
    *out_period_frames = period_frames;
    return 0;
}

static int write_pcm_frames(
    snd_pcm_t *pcm,
    const int16_t *samples,
    snd_pcm_uframes_t frames)
{
    snd_pcm_uframes_t offset = 0u;

    while (offset < frames) {
        const snd_pcm_sframes_t written = snd_pcm_writei(
            pcm,
            samples + (size_t)offset * AUDIO_CHANNELS,
            frames - offset);
        if (written > 0) {
            offset += (snd_pcm_uframes_t)written;
            continue;
        }
        if (written == -EINTR) {
            continue;
        }
        if (written == -EPIPE || written == -ESTRPIPE) {
            const int recovered =
                snd_pcm_recover(pcm, (int)written, 1);
            if (recovered >= 0) {
                continue;
            }
        }
        fprintf(stderr,
                "speaker audio: snd_pcm_writei failed: %s\n",
                snd_strerror((int)written));
        return -1;
    }
    return 0;
}

static double base_rate_ratio(void)
{
    return (double)AUDIO_SINK_SAMPLE_RATE /
           (double)AUDIO_SOURCE_SAMPLE_RATE;
}

static double clamp_rate_correction(double correction)
{
    const double delta =
        AUDIO_MAX_RATE_CORRECTION_PPM / 1000000.0;
    if (correction < 1.0 - delta) {
        return 1.0 - delta;
    }
    if (correction > 1.0 + delta) {
        return 1.0 + delta;
    }
    return correction;
}

static double rate_ratio_for_delay(snd_pcm_sframes_t delay_frames)
{
    const double error =
        (double)AUDIO_TARGET_DELAY_FRAMES - (double)delay_frames;
    const double ppm = error * AUDIO_RATE_PPM_PER_FRAME;
    const double correction =
        clamp_rate_correction(1.0 + ppm / 1000000.0);
    return base_rate_ratio() * correction;
}

static uint64_t frame_duration_nanos(uint64_t frames)
{
    return (frames * 1000000000ULL) / AUDIO_SOURCE_SAMPLE_RATE;
}

static void update_master_clock(
    struct monitoros_audio_sink *sink,
    snd_pcm_t *pcm,
    const struct audio_header *header,
    double ratio)
{
    snd_pcm_sframes_t delay_frames = 0;
    if (snd_pcm_delay(pcm, &delay_frames) < 0) {
        return;
    }
    if (delay_frames < 0) {
        delay_frames = 0;
    }

    atomic_store_explicit(
        &sink->buffer_error_frames,
        (int64_t)delay_frames - AUDIO_TARGET_DELAY_FRAMES,
        memory_order_relaxed);
    atomic_store_explicit(
        &sink->master_update_monotonic_nanos,
        monotonic_nanos(),
        memory_order_release);

    if (snd_pcm_state(pcm) != SND_PCM_STATE_RUNNING) {
        // Freeze the media clock at the first queued audio PTS while ALSA
        // fills its start threshold. Updating it for every queued block would
        // let video advance through the prebuffer before any sound is audible.
        if (!atomic_load_explicit(
                &sink->active, memory_order_acquire)) {
            atomic_store_explicit(
                &sink->master_pts_nanos,
                header->pts_nanos,
                memory_order_release);
            atomic_store_explicit(
                &sink->active, true, memory_order_release);
        }
        return;
    }

    const uint64_t block_end =
        header->pts_nanos + frame_duration_nanos(header->frame_count);
    const double source_delay_frames =
        (double)delay_frames / ratio;
    const uint64_t source_delay_nanos =
        (uint64_t)(
            source_delay_frames * 1000000000.0 /
            (double)AUDIO_SOURCE_SAMPLE_RATE);

    const uint64_t master =
        block_end > source_delay_nanos
            ? block_end - source_delay_nanos
            : 0u;

    atomic_store_explicit(
        &sink->master_pts_nanos, master, memory_order_release);
    atomic_store_explicit(
        &sink->active, true, memory_order_release);
}

static int play_client(
    struct monitoros_audio_sink *sink,
    int client_fd)
{
    snd_pcm_t *pcm = NULL;
    snd_pcm_uframes_t buffer_frames = 0u;
    snd_pcm_uframes_t period_frames = 0u;
    if (configure_pcm(
            &pcm, &buffer_frames, &period_frames) != 0) {
        return -1;
    }

    int src_error = 0;
    SRC_STATE *resampler =
        src_new(SRC_LINEAR, AUDIO_CHANNELS, &src_error);
    if (resampler == NULL) {
        fprintf(stderr,
                "speaker audio: resampler init failed: %s\n",
                src_strerror(src_error));
        snd_pcm_close(pcm);
        return -1;
    }

    printf(
        "speaker audio: client connected; PipeWire PCM "
        "source=%uHz sink=%uHz buffer=%lu period=%lu "
        "target=%ld frames\n",
        AUDIO_SOURCE_SAMPLE_RATE,
        AUDIO_SINK_SAMPLE_RATE,
        (unsigned long)buffer_frames,
        (unsigned long)period_frames,
        AUDIO_TARGET_DELAY_FRAMES);
    fflush(stdout);

    uint8_t payload[AUDIO_MAX_BLOCK_FRAMES * AUDIO_CHANNELS * 2u];
    int16_t input_short[AUDIO_MAX_BLOCK_FRAMES * AUDIO_CHANNELS];
    float input_float[AUDIO_MAX_BLOCK_FRAMES * AUDIO_CHANNELS];
    float output_float[
        AUDIO_OUTPUT_CAPACITY_FRAMES * AUDIO_CHANNELS
    ];
    int16_t output_short[
        AUDIO_OUTPUT_CAPACITY_FRAMES * AUDIO_CHANNELS
    ];

    bool have_previous = false;
    uint64_t previous_sequence = 0u;
    uint64_t expected_pts = 0u;
    uint64_t block_count = 0u;

    for (;;) {
        if (atomic_load_explicit(&sink->shutdown, memory_order_relaxed)) {
            break;
        }

        uint8_t raw_header[AUDIO_HEADER_SIZE];
        const int header_result = receive_exact(
            sink, client_fd, raw_header, sizeof(raw_header));
        if (header_result <= 0) {
            break;
        }

        struct audio_header header = {0};
        if (parse_audio_header(raw_header, &header) != 0) {
            fprintf(stderr, "speaker audio: invalid audio block header\n");
            break;
        }

        const size_t payload_bytes =
            (size_t)header.frame_count * AUDIO_CHANNELS * 2u;
        const int payload_result = receive_exact(
            sink, client_fd, payload, payload_bytes);
        if (payload_result <= 0) {
            break;
        }

        bool discontinuity = false;
        if (have_previous) {
            if (header.sequence != previous_sequence + 1u) {
                discontinuity = true;
            }

            const uint64_t difference =
                header.pts_nanos > expected_pts
                    ? header.pts_nanos - expected_pts
                    : expected_pts - header.pts_nanos;
            if (difference > AUDIO_PTS_TOLERANCE_NS) {
                discontinuity = true;
            }
        }

        if (discontinuity) {
            fprintf(stderr,
                    "speaker audio: timeline discontinuity; "
                    "restarting playout buffer\n");
            (void)snd_pcm_drop(pcm);
            (void)snd_pcm_prepare(pcm);
            src_reset(resampler);
            atomic_store_explicit(
                &sink->active, false, memory_order_release);
        }

        previous_sequence = header.sequence;
        expected_pts =
            header.pts_nanos + frame_duration_nanos(header.frame_count);
        have_previous = true;

        const size_t sample_count =
            (size_t)header.frame_count * AUDIO_CHANNELS;
        int input_peak = 0;
        for (size_t i = 0u; i < sample_count; ++i) {
            const uint16_t value =
                (uint16_t)payload[i * 2u] |
                ((uint16_t)payload[i * 2u + 1u] << 8);
            input_short[i] = (int16_t)value;
            const int sample = (int)input_short[i];
            const int magnitude = sample < 0 ? -sample : sample;
            if (magnitude > input_peak) {
                input_peak = magnitude;
            }
        }
        src_short_to_float_array(
            input_short, input_float, (int)sample_count);

        snd_pcm_sframes_t delay_frames = AUDIO_TARGET_DELAY_FRAMES;
        if (snd_pcm_state(pcm) == SND_PCM_STATE_RUNNING) {
            if (snd_pcm_delay(pcm, &delay_frames) < 0 ||
                delay_frames < 0) {
                delay_frames = AUDIO_TARGET_DELAY_FRAMES;
            }
        }
        const double ratio = rate_ratio_for_delay(delay_frames);

        SRC_DATA data = {
            .data_in = input_float,
            .data_out = output_float,
            .input_frames = (long)header.frame_count,
            .output_frames = AUDIO_OUTPUT_CAPACITY_FRAMES,
            .src_ratio = ratio,
            .end_of_input = 0,
        };
        const int process_result =
            src_process(resampler, &data);
        if (process_result != 0 ||
            data.input_frames_used != (long)header.frame_count) {
            fprintf(stderr,
                    "speaker audio: resampler failed: %s\n",
                    src_strerror(process_result));
            break;
        }

        const size_t output_samples =
            (size_t)data.output_frames_gen * AUDIO_CHANNELS;
        src_float_to_short_array(
            output_float, output_short, (int)output_samples);

        int output_peak = 0;
        for (size_t i = 0u; i < output_samples; ++i) {
            const int sample = (int)output_short[i];
            const int magnitude = sample < 0 ? -sample : sample;
            if (magnitude > output_peak) {
                output_peak = magnitude;
            }
        }

        if (write_pcm_frames(
                pcm,
                output_short,
                (snd_pcm_uframes_t)data.output_frames_gen) != 0) {
            break;
        }

        update_master_clock(sink, pcm, &header, ratio);
        block_count += 1u;

        if ((block_count % 750u) == 0u) {
            const int64_t error_frames = atomic_load_explicit(
                &sink->buffer_error_frames, memory_order_relaxed);
            snd_pcm_sframes_t observed_delay = 0;
            if (snd_pcm_delay(pcm, &observed_delay) < 0) {
                observed_delay = -1;
            }
            printf(
                "speaker audio: buffer_error=%.3f ms "
                "rate_adjust=%+.1f ppm input_peak=%d "
                "output_peak=%d pcm=%s delay=%ld\n",
                (double)error_frames * 1000.0 /
                    (double)AUDIO_SINK_SAMPLE_RATE,
                (ratio / base_rate_ratio() - 1.0) *
                    1000000.0,
                input_peak,
                output_peak,
                snd_pcm_state_name(snd_pcm_state(pcm)),
                (long)observed_delay);
            fflush(stdout);
        }
    }

    atomic_store_explicit(
        &sink->active, false, memory_order_release);
    (void)snd_pcm_drop(pcm);
    src_delete(resampler);
    snd_pcm_close(pcm);
    return 0;
}

static void *audio_thread_main(void *opaque)
{
    struct monitoros_audio_sink *sink = opaque;

    while (!atomic_load_explicit(
        &sink->shutdown, memory_order_relaxed)) {
        struct pollfd descriptor = {
            .fd = sink->listener_fd,
            .events = POLLIN,
        };
        const int poll_result = poll(&descriptor, 1, 100);
        if (poll_result == 0) {
            continue;
        }
        if (poll_result < 0) {
            if (errno == EINTR) {
                continue;
            }
            break;
        }
        if ((descriptor.revents & POLLIN) == 0) {
            continue;
        }

        const int client_fd =
            accept4(sink->listener_fd, NULL, NULL, SOCK_CLOEXEC);
        if (client_fd < 0) {
            if (errno == EINTR) {
                continue;
            }
            fprintf(stderr,
                    "speaker audio: accept failed: %s\n",
                    strerror(errno));
            continue;
        }

        struct timeval timeout = {
            .tv_sec = 0,
            .tv_usec = 200000,
        };
        (void)setsockopt(
            client_fd, SOL_SOCKET, SO_RCVTIMEO,
            &timeout, sizeof(timeout));

        (void)play_client(sink, client_fd);
        close(client_fd);
        atomic_store_explicit(
            &sink->active, false, memory_order_release);
    }

    return NULL;
}

int monitoros_audio_sink_create(struct monitoros_audio_sink **out_sink)
{
    if (out_sink == NULL) {
        errno = EINVAL;
        return -1;
    }

    struct monitoros_audio_sink *sink =
        calloc(1u, sizeof(*sink));
    if (sink == NULL) {
        return -1;
    }

    sink->listener_fd = create_listener();
    if (sink->listener_fd < 0) {
        free(sink);
        return -1;
    }

    atomic_init(&sink->shutdown, false);
    atomic_init(&sink->active, false);
    atomic_init(&sink->master_pts_nanos, 0u);
    atomic_init(&sink->master_update_monotonic_nanos, 0u);
    atomic_init(&sink->buffer_error_frames, 0);

    const int thread_result =
        pthread_create(&sink->thread, NULL, audio_thread_main, sink);
    if (thread_result != 0) {
        close(sink->listener_fd);
        free(sink);
        errno = thread_result;
        return -1;
    }
    sink->thread_started = true;

    printf(
        "speaker audio: listening on [::]:%u "
        "for timestamped 48 kHz stereo s16le "
        "(PipeWire sink 48 kHz)\n",
        AUDIO_PORT);
    fflush(stdout);

    *out_sink = sink;
    return 0;
}

void monitoros_audio_sink_destroy(struct monitoros_audio_sink *sink)
{
    if (sink == NULL) {
        return;
    }

    atomic_store_explicit(
        &sink->shutdown, true, memory_order_relaxed);

    if (sink->thread_started) {
        (void)pthread_join(sink->thread, NULL);
    }
    if (sink->listener_fd >= 0) {
        close(sink->listener_fd);
    }
    free(sink);
}

bool monitoros_audio_sink_master_pts(
    const struct monitoros_audio_sink *sink,
    uint64_t *source_pts_nanos)
{
    if (sink == NULL ||
        source_pts_nanos == NULL ||
        !atomic_load_explicit(&sink->active, memory_order_acquire)) {
        return false;
    }

    const uint64_t updated = atomic_load_explicit(
        &sink->master_update_monotonic_nanos,
        memory_order_acquire);
    if (!audio_clock_is_fresh(monotonic_nanos(), updated)) {
        return false;
    }

    *source_pts_nanos = atomic_load_explicit(
        &sink->master_pts_nanos, memory_order_acquire);
    return true;
}

double monitoros_audio_sink_buffer_error_ms(
    const struct monitoros_audio_sink *sink)
{
    if (sink == NULL) {
        return 0.0;
    }

    const int64_t frames = atomic_load_explicit(
        &sink->buffer_error_frames, memory_order_relaxed);
    return (double)frames * 1000.0 / (double)AUDIO_SINK_SAMPLE_RATE;
}

int monitoros_audio_self_test(void)
{
    uint8_t bytes[AUDIO_HEADER_SIZE] = {0};
    memcpy(bytes, AUDIO_MAGIC, 8u);
    write_be32(bytes + 8u, AUDIO_HEADER_SIZE);
    write_be64(bytes + 12u, 7u);
    write_be64(bytes + 20u, 123456789u);
    write_be32(bytes + 28u, 128u);
    write_be32(bytes + 32u, AUDIO_SOURCE_SAMPLE_RATE);
    write_be16(bytes + 36u, AUDIO_CHANNELS);
    write_be16(bytes + 38u, AUDIO_FORMAT_S16_LE);

    struct audio_header header = {0};
    if (parse_audio_header(bytes, &header) != 0 ||
        header.sequence != 7u ||
        header.pts_nanos != 123456789u ||
        header.frame_count != 128u) {
        fprintf(stderr,
                "audio self-test failed: valid block rejected\n");
        return 1;
    }

    bytes[0] = 'X';
    if (parse_audio_header(bytes, &header) == 0) {
        fprintf(stderr,
                "audio self-test failed: invalid magic accepted\n");
        return 1;
    }
    bytes[0] = 'M';

    write_be32(bytes + 32u, 44100u);
    if (parse_audio_header(bytes, &header) == 0) {
        fprintf(stderr,
                "audio self-test failed: invalid rate accepted\n");
        return 1;
    }

    if (!audio_clock_is_fresh(
            1000000000ULL,
            1000000000ULL - AUDIO_CLOCK_STALE_NS) ||
        audio_clock_is_fresh(
            1000000000ULL,
            1000000000ULL - AUDIO_CLOCK_STALE_NS - 1u) ||
        audio_clock_is_fresh(999u, 1000u) ||
        audio_clock_is_fresh(1000u, 0u)) {
        fprintf(stderr,
                "audio self-test failed: clock freshness boundary\n");
        return 1;
    }

    const double base_ratio = base_rate_ratio();
    const double target_ratio =
        rate_ratio_for_delay(AUDIO_TARGET_DELAY_FRAMES);
    const double low_buffer_ratio =
        rate_ratio_for_delay(AUDIO_TARGET_DELAY_FRAMES - 100L);
    const double high_buffer_ratio =
        rate_ratio_for_delay(AUDIO_TARGET_DELAY_FRAMES + 100L);

    if (AUDIO_TARGET_DELAY_FRAMES != 2880L ||
        AUDIO_SOURCE_SAMPLE_RATE != AUDIO_SINK_SAMPLE_RATE ||
        target_ratio != base_ratio ||
        low_buffer_ratio <= base_ratio ||
        high_buffer_ratio >= base_ratio) {
        fprintf(stderr,
                "audio self-test failed: 48k->44.1k rate controller\n");
        return 1;
    }

    return 0;
}
