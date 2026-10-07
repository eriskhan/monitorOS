#define _GNU_SOURCE

#include <arpa/inet.h>
#include <errno.h>
#include <fcntl.h>
#include <netdb.h>
#include <poll.h>
#include <pthread.h>
#include <signal.h>
#include <stdbool.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <time.h>
#include <unistd.h>

#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <drm_fourcc.h>
#include <gbm.h>
#include <xf86drm.h>
#include <xf86drmMode.h>

#include "imac5k-audio.h"
#include "imac5k-kms.h"

#ifndef EGL_PLATFORM_GBM_KHR
#define EGL_PLATFORM_GBM_KHR 0x31D7
#endif

#ifndef EGL_BUFFER_AGE_EXT
#define EGL_BUFFER_AGE_EXT 0x313D
#endif

#define DEFAULT_BIND "[::]:5202"
#define FRAME_HEADER_SIZE 64u
#define FRAME_MAGIC_V2 "MOS5K002"
#define FRAME_FOURCC_YUVF 0x79757666u
#define FRAME_YUV422_STRIDE 10240u
#define FRAME_YUV422_BYTES 29491200u
#define FRAME_RECT_DESCRIPTOR_SIZE 16u
#define FRAME_MAX_RECTS 64u
#define FRAME_MAILBOX_SLOTS 3u
#define DAMAGE_HISTORY_SLOTS 8u
#define REDRAW_MAX_RECTS (FRAME_MAX_RECTS * DAMAGE_HISTORY_SLOTS)
#define VIDEO_AUDIO_PRESENT_LEAD_NS 8000000ULL
#define VIDEO_AUDIO_MAX_WAIT_NS 8000000ULL
#define VIDEO_AUDIO_DROP_LATE_MS 25.0
#define BRIGHTNESS_FINE_STEPS 64u
#define BRIGHTNESS_SOFTWARE_FLOOR_UNIT 13u

static volatile sig_atomic_t stop_requested = 0;

struct frame_header {
    uint64_t frame_id;
    uint64_t pts_nanos;
    uint32_t width;
    uint32_t height;
    uint32_t fourcc;
    uint32_t plane_count;
    uint32_t stride_y;
    uint32_t stride_uv;
    uint32_t size_y;
    uint32_t size_uv;
    uint32_t rect_count;
};

struct frame_rect {
    uint32_t x;
    uint32_t y;
    uint32_t width;
    uint32_t height;
};

struct damage_set {
    bool full;
    uint32_t rect_count;
    struct frame_rect rects[FRAME_MAX_RECTS];
};

struct drm_fb {
    uint32_t fb_id;
};

struct timing_stat {
    uint64_t count;
    double sum_ms;
    double max_ms;
};

struct stream_metrics {
    uint64_t frames;
    uint64_t sync_drops;
    uint64_t presentation_skips;
    uint64_t presentation_order_errors;
    uint64_t previous_frame_id;
    bool have_previous_frame_id;
    double first_wall_seconds;
    double last_wall_seconds;
    struct timing_stat audio_sync_wait;
    uint64_t audio_sync_wait_caps;
    struct timing_stat render;
    struct timing_stat flip;
    struct timing_stat total;
};

enum frame_slot_state {
    FRAME_SLOT_FREE = 0,
    FRAME_SLOT_RECEIVING,
    FRAME_SLOT_READY,
    FRAME_SLOT_DISPLAY,
};

struct frame_slot {
    struct frame_header header;
    struct frame_rect rects[FRAME_MAX_RECTS];
    uint8_t *plane_y;
    double receive_ms;
    enum frame_slot_state state;
};

struct frame_mailbox {
    pthread_mutex_t mutex;
    pthread_cond_t ready;
    pthread_cond_t free_slot;
    struct frame_slot slots[FRAME_MAILBOX_SLOTS];
    int ready_queue[FRAME_MAILBOX_SLOTS];
    size_t ready_head;
    size_t ready_tail;
    size_t ready_count;
    size_t max_ready_count;
    uint64_t received_frames;
    uint64_t received_full_frames;
    uint64_t received_delta_frames;
    uint64_t received_delta_rects;
    uint64_t transport_sequence_errors;
    uint64_t previous_received_id;
    bool have_previous_received_id;
    uint64_t first_pts_nanos;
    uint64_t last_pts_nanos;
    struct timing_stat receive;
    struct timing_stat free_slot_wait;
    bool closed;
    bool failed;
    int client_fd;
};

struct renderer {
    int drm_fd;
    const struct monitoros_scanout_target *target;
    struct gbm_device *gbm_device;
    struct gbm_surface *gbm_surface;
    EGLDisplay egl_display;
    EGLConfig egl_config;
    EGLContext egl_context;
    EGLSurface egl_surface;
    GLuint program_yuv422;
    GLuint vertex_buffer;
    GLuint texture_yuv422;
    GLint uniform_yuv422;
    GLint uniform_brightness_yuv422;
    bool has_buffer_age;
    struct damage_set damage_history[DAMAGE_HISTORY_SLOTS];
    size_t damage_history_next;
    size_t damage_history_count;
    uint64_t full_redraw_frames;
    uint64_t partial_redraw_frames;
    uint64_t partial_redraw_rects;
    uint64_t buffer_age_zero_frames;
    uint64_t buffer_age_history_fallbacks;
    uint64_t buffer_age_query_failures;
    EGLint max_buffer_age;
    struct gbm_bo *current_bo;
    struct gbm_bo *pending_bo;
    bool modeset_active;
    bool flip_pending;
    int brightness_fd;
    uint8_t brightness_unit;
    bool brightness_redraw_pending;
};

static uint8_t brightness_software_unit(uint8_t fine_unit)
{
    return (uint32_t)fine_unit < BRIGHTNESS_SOFTWARE_FLOOR_UNIT
        ? fine_unit
        : (uint8_t)BRIGHTNESS_SOFTWARE_FLOOR_UNIT;
}

static double brightness_software_scale(uint8_t fine_unit)
{
    return (double)brightness_software_unit(fine_unit) /
           (double)BRIGHTNESS_SOFTWARE_FLOOR_UNIT;
}

static int renderer_drain_brightness(struct renderer *renderer)
{
    if (renderer->brightness_fd < 0) {
        return 0;
    }

    const uint8_t previous_software_unit =
        brightness_software_unit(renderer->brightness_unit);
    uint8_t buffer[64];
    bool changed = false;

    for (;;) {
        const ssize_t count =
            read(renderer->brightness_fd, buffer, sizeof(buffer));
        if (count > 0) {
            for (ssize_t i = 0; i < count; ++i) {
                if ((uint32_t)buffer[i] <= BRIGHTNESS_FINE_STEPS) {
                    renderer->brightness_unit = buffer[i];
                    changed = true;
                } else {
                    fprintf(stderr,
                            "ignoring invalid logical brightness unit %u\n",
                            (unsigned)buffer[i]);
                }
            }
            continue;
        }
        if (count == 0) {
            close(renderer->brightness_fd);
            renderer->brightness_fd = -1;
            break;
        }
        if (errno == EINTR) {
            continue;
        }
        if (errno == EAGAIN || errno == EWOULDBLOCK) {
            break;
        }
        fprintf(stderr, "brightness pipe read failed: %s\n", strerror(errno));
        return -1;
    }

    if (changed) {
        const uint8_t software_unit =
            brightness_software_unit(renderer->brightness_unit);
        if (software_unit != previous_software_unit) {
            renderer->brightness_redraw_pending = true;
        }
    }
    return 0;
}

static int renderer_configure_brightness(
    struct renderer *renderer,
    int brightness_fd)
{
    renderer->brightness_fd = brightness_fd;
    renderer->brightness_unit = BRIGHTNESS_FINE_STEPS;
    renderer->brightness_redraw_pending = false;

    if (brightness_fd >= 0) {
        const int flags = fcntl(brightness_fd, F_GETFL);
        if (flags < 0 ||
            fcntl(brightness_fd, F_SETFL, flags | O_NONBLOCK) != 0) {
            fprintf(stderr,
                    "failed to configure brightness pipe: %s\n",
                    strerror(errno));
            return -1;
        }
    }

    printf(
        "brightness output: fd=%d floor=%u/%u software_dim=shader\n",
        brightness_fd,
        BRIGHTNESS_SOFTWARE_FLOOR_UNIT,
        BRIGHTNESS_FINE_STEPS);

    return renderer_drain_brightness(renderer);
}

static void handle_signal(int signal_number)
{
    (void)signal_number;
    stop_requested = 1;
}

static int disable_target_crtc(
    int fd,
    const struct monitoros_scanout_target *target)
{
    return drmModeSetCrtc(fd, target->crtc_id, 0, 0, 0, NULL, 0, NULL);
}

static double monotonic_seconds(void)
{
    struct timespec now;
    if (clock_gettime(CLOCK_MONOTONIC, &now) != 0) {
        return 0.0;
    }

    return (double)now.tv_sec + (double)now.tv_nsec / 1000000000.0;
}

static double wait_for_audio_timeline(
    const struct monitoros_audio_sink *audio_sink,
    uint64_t frame_pts_nanos,
    double *waited_ms,
    bool *wait_cap_reached)
{
    uint64_t audio_pts_nanos = 0u;
    const double wait_start = monotonic_seconds();
    const double wait_deadline =
        wait_start + (double)VIDEO_AUDIO_MAX_WAIT_NS / 1000000000.0;

    *wait_cap_reached = false;

    while (!stop_requested &&
           monitoros_audio_sink_master_pts(
               audio_sink, &audio_pts_nanos)) {
        const uint64_t target =
            audio_pts_nanos + VIDEO_AUDIO_PRESENT_LEAD_NS;
        if (frame_pts_nanos <= target) {
            break;
        }

        const double now = monotonic_seconds();
        if (now >= wait_deadline) {
            *wait_cap_reached = true;
            break;
        }

        uint64_t wait_nanos = frame_pts_nanos - target;
        const uint64_t remaining_nanos =
            (uint64_t)((wait_deadline - now) * 1000000000.0);
        if (wait_nanos > remaining_nanos) {
            wait_nanos = remaining_nanos;
        }
        if (wait_nanos > 2000000ULL) {
            wait_nanos = 2000000ULL;
        }
        if (wait_nanos < 100000ULL) {
            wait_nanos = 100000ULL;
        }

        struct timespec delay = {
            .tv_sec = 0,
            .tv_nsec = (long)wait_nanos,
        };
        while (nanosleep(&delay, &delay) != 0 &&
               errno == EINTR && !stop_requested) {
        }
    }

    *waited_ms =
        (monotonic_seconds() - wait_start) * 1000.0;

    if (monitoros_audio_sink_master_pts(
            audio_sink, &audio_pts_nanos)) {
        return (
            (double)((int64_t)frame_pts_nanos -
                     (int64_t)audio_pts_nanos)) /
            1000000.0;
    }
    return 0.0;
}

static void timing_add(struct timing_stat *stat, double milliseconds)
{
    stat->count += 1;
    stat->sum_ms += milliseconds;
    if (milliseconds > stat->max_ms) {
        stat->max_ms = milliseconds;
    }
}

static double timing_mean(const struct timing_stat *stat)
{
    return stat->count == 0 ? 0.0 : stat->sum_ms / (double)stat->count;
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
    uint64_t value = 0;
    for (size_t i = 0; i < 8; ++i) {
        value = (value << 8) | (uint64_t)bytes[i];
    }
    return value;
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
    for (size_t i = 0; i < 8; ++i) {
        const unsigned shift = (unsigned)(7u - i) * 8u;
        bytes[i] = (uint8_t)((value >> shift) & 0xffu);
    }
}

static int parse_frame_header(const uint8_t bytes[FRAME_HEADER_SIZE],
                              struct frame_header *header)
{
    if (memcmp(bytes, FRAME_MAGIC_V2, 8) != 0) {
        fprintf(stderr, "invalid transport magic\n");
        return -1;
    }

    const uint32_t header_size = read_be32(bytes + 8);
    if (header_size != FRAME_HEADER_SIZE) {
        fprintf(stderr, "unsupported transport header size %u\n", header_size);
        return -1;
    }

    header->frame_id = read_be64(bytes + 12);
    header->pts_nanos = read_be64(bytes + 20);
    header->width = read_be32(bytes + 28);
    header->height = read_be32(bytes + 32);
    header->fourcc = read_be32(bytes + 36);
    header->plane_count = read_be32(bytes + 40);
    header->stride_y = read_be32(bytes + 44);
    header->stride_uv = read_be32(bytes + 48);
    header->size_y = read_be32(bytes + 52);
    header->size_uv = read_be32(bytes + 56);
    header->rect_count = read_be32(bytes + 60);

    if (header->width != MONITOROS_WIDTH ||
        header->height != MONITOROS_HEIGHT) {
        fprintf(stderr, "unexpected frame geometry %ux%u\n",
                header->width, header->height);
        return -1;
    }

    if (header->fourcc != FRAME_FOURCC_YUVF) {
        fprintf(stderr,
                "unsupported frame format fourcc=0x%08x planes=%u\n",
                header->fourcc, header->plane_count);
        return -1;
    }

    if (header->plane_count != 1u ||
        header->stride_y != FRAME_YUV422_STRIDE ||
        header->stride_uv != 0u ||
        header->size_uv != 0u ||
        header->rect_count > FRAME_MAX_RECTS) {
        fprintf(stderr,
                "unexpected yuvf layout planes=%u strides=%u/%u "
                "sizes=%u/%u rects=%u\n",
                header->plane_count, header->stride_y, header->stride_uv,
                header->size_y, header->size_uv, header->rect_count);
        return -1;
    }

    if (header->rect_count == 0u) {
        if (header->size_y != FRAME_YUV422_BYTES) {
            fprintf(stderr,
                    "unexpected full yuvf payload size=%u\n",
                    header->size_y);
            return -1;
        }
    } else if (header->size_y == 0u ||
               header->size_y >= FRAME_YUV422_BYTES) {
        fprintf(stderr,
                "unexpected delta yuvf payload size=%u rects=%u\n",
                header->size_y, header->rect_count);
        return -1;
    }

    return 0;
}

static int split_bind_target(const char *text,
                             char *host, size_t host_size,
                             char *service, size_t service_size)
{
    if (text[0] != '[') {
        return -1;
    }

    const char *closing = strchr(text + 1, ']');
    if (closing == NULL || closing == text + 1 ||
        closing[1] != ':' || closing[2] == '\0') {
        return -1;
    }

    const char *host_start = text + 1;
    const char *service_start = closing + 2;
    const size_t host_length = (size_t)(closing - host_start);
    const size_t service_length = strlen(service_start);
    if (host_length >= host_size || service_length >= service_size) {
        return -1;
    }

    memcpy(host, host_start, host_length);
    host[host_length] = '\0';
    memcpy(service, service_start, service_length + 1u);
    return 0;
}

static int create_listener(const char *bind_address)
{
    char host[NI_MAXHOST];
    char service[NI_MAXSERV];
    if (split_bind_target(bind_address, host, sizeof(host),
                          service, sizeof(service)) != 0) {
        fprintf(stderr,
                "invalid --bind value %s; expected [IPv6%%scope]:PORT\n",
                bind_address);
        return -1;
    }

    struct addrinfo hints = {
        .ai_family = AF_INET6,
        .ai_socktype = SOCK_STREAM,
        .ai_protocol = IPPROTO_TCP,
        .ai_flags = AI_NUMERICHOST | AI_NUMERICSERV,
    };
    struct addrinfo *addresses = NULL;
    const int resolve_result =
        getaddrinfo(host, service, &hints, &addresses);
    if (resolve_result != 0) {
        fprintf(stderr, "invalid --bind value %s: %s\n",
                bind_address, gai_strerror(resolve_result));
        return -1;
    }

    int fd = -1;
    for (struct addrinfo *candidate = addresses;
         candidate != NULL;
         candidate = candidate->ai_next) {
        if (candidate->ai_family != AF_INET6) {
            continue;
        }

        fd = socket(candidate->ai_family,
                    SOCK_STREAM | SOCK_CLOEXEC, IPPROTO_TCP);
        if (fd < 0) {
            continue;
        }

        int reuse = 1;
        if (setsockopt(fd, SOL_SOCKET, SO_REUSEADDR,
                       &reuse, sizeof(reuse)) != 0) {
            perror("setsockopt(SO_REUSEADDR)");
            close(fd);
            fd = -1;
            continue;
        }

        int v6only = 1;
        if (setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY,
                       &v6only, sizeof(v6only)) != 0) {
            perror("setsockopt(IPV6_V6ONLY)");
            close(fd);
            fd = -1;
            continue;
        }

        if (bind(fd, candidate->ai_addr, candidate->ai_addrlen) != 0) {
            fprintf(stderr, "failed to bind %s: %s\n",
                    bind_address, strerror(errno));
            close(fd);
            fd = -1;
            continue;
        }

        if (listen(fd, 1) != 0) {
            perror("listen");
            close(fd);
            fd = -1;
            continue;
        }

        break;
    }

    freeaddrinfo(addresses);
    return fd;
}

static int receive_exact(int fd, void *buffer, size_t length)
{
    uint8_t *bytes = buffer;
    size_t offset = 0;

    while (offset < length) {
        const ssize_t received = recv(fd, bytes + offset, length - offset, 0);
        if (received > 0) {
            offset += (size_t)received;
            continue;
        }
        if (received == 0) {
            return offset == 0 ? 0 : -2;
        }
        if (errno == EINTR && stop_requested) {
            return -3;
        }
        if (errno == EINTR) {
            continue;
        }
        return -1;
    }

    return 1;
}


static int parse_frame_rects(const uint8_t *bytes,
                             struct frame_slot *slot)
{
    uint64_t expected_payload = 0u;

    for (uint32_t i = 0; i < slot->header.rect_count; ++i) {
        const uint8_t *descriptor =
            bytes + (size_t)i * FRAME_RECT_DESCRIPTOR_SIZE;
        struct frame_rect *rect = &slot->rects[i];
        rect->x = read_be32(descriptor);
        rect->y = read_be32(descriptor + 4);
        rect->width = read_be32(descriptor + 8);
        rect->height = read_be32(descriptor + 12);

        if (rect->width == 0u || rect->height == 0u ||
            (rect->x & 1u) != 0u || (rect->width & 1u) != 0u ||
            rect->x >= MONITOROS_WIDTH ||
            rect->y >= MONITOROS_HEIGHT ||
            rect->width > MONITOROS_WIDTH - rect->x ||
            rect->height > MONITOROS_HEIGHT - rect->y) {
            fprintf(stderr,
                    "invalid yuvf delta rect %u: x=%u y=%u w=%u h=%u\n",
                    i, rect->x, rect->y, rect->width, rect->height);
            return -1;
        }

        expected_payload +=
            (uint64_t)rect->width * (uint64_t)rect->height * 2u;
    }

    if (expected_payload != slot->header.size_y) {
        fprintf(stderr,
                "delta payload mismatch expected=%llu header=%u rects=%u\n",
                (unsigned long long)expected_payload,
                slot->header.size_y, slot->header.rect_count);
        return -1;
    }

    return 0;
}

static int frame_mailbox_init(struct frame_mailbox *mailbox, int client_fd)
{
    memset(mailbox, 0, sizeof(*mailbox));
    mailbox->client_fd = client_fd;

    if (pthread_mutex_init(&mailbox->mutex, NULL) != 0) {
        return -1;
    }
    if (pthread_cond_init(&mailbox->ready, NULL) != 0) {
        pthread_mutex_destroy(&mailbox->mutex);
        return -1;
    }
    if (pthread_cond_init(&mailbox->free_slot, NULL) != 0) {
        pthread_cond_destroy(&mailbox->ready);
        pthread_mutex_destroy(&mailbox->mutex);
        return -1;
    }

    for (size_t i = 0; i < FRAME_MAILBOX_SLOTS; ++i) {
        mailbox->slots[i].plane_y = malloc(FRAME_YUV422_BYTES);
        mailbox->slots[i].state = FRAME_SLOT_FREE;
        if (mailbox->slots[i].plane_y == NULL) {
            for (size_t j = 0; j <= i; ++j) {
                free(mailbox->slots[j].plane_y);
            }
            pthread_cond_destroy(&mailbox->free_slot);
            pthread_cond_destroy(&mailbox->ready);
            pthread_mutex_destroy(&mailbox->mutex);
            return -1;
        }
    }

    return 0;
}

static void frame_mailbox_destroy(struct frame_mailbox *mailbox)
{
    for (size_t i = 0; i < FRAME_MAILBOX_SLOTS; ++i) {
        free(mailbox->slots[i].plane_y);
    }
    pthread_cond_destroy(&mailbox->free_slot);
    pthread_cond_destroy(&mailbox->ready);
    pthread_mutex_destroy(&mailbox->mutex);
}

static void frame_mailbox_close(struct frame_mailbox *mailbox, bool failed)
{
    pthread_mutex_lock(&mailbox->mutex);
    mailbox->closed = true;
    mailbox->failed = mailbox->failed || failed;
    pthread_cond_broadcast(&mailbox->ready);
    pthread_cond_broadcast(&mailbox->free_slot);
    pthread_mutex_unlock(&mailbox->mutex);
}

static struct frame_slot *frame_mailbox_begin_receive(
    struct frame_mailbox *mailbox)
{
    pthread_mutex_lock(&mailbox->mutex);

    struct frame_slot *slot = NULL;
    while (slot == NULL && !mailbox->closed && !stop_requested) {
        for (size_t i = 0; i < FRAME_MAILBOX_SLOTS; ++i) {
            if (mailbox->slots[i].state == FRAME_SLOT_FREE) {
                slot = &mailbox->slots[i];
                slot->state = FRAME_SLOT_RECEIVING;
                break;
            }
        }

        if (slot == NULL) {
            struct timespec deadline;
            if (clock_gettime(CLOCK_REALTIME, &deadline) != 0) {
                break;
            }
            deadline.tv_nsec += 100000000L;
            if (deadline.tv_nsec >= 1000000000L) {
                deadline.tv_sec += 1;
                deadline.tv_nsec -= 1000000000L;
            }
            (void)pthread_cond_timedwait(
                &mailbox->free_slot, &mailbox->mutex, &deadline);
        }
    }

    pthread_mutex_unlock(&mailbox->mutex);
    return slot;
}

static void frame_mailbox_cancel_receive(struct frame_mailbox *mailbox,
                                         struct frame_slot *slot)
{
    pthread_mutex_lock(&mailbox->mutex);
    if (slot != NULL && slot->state == FRAME_SLOT_RECEIVING) {
        slot->state = FRAME_SLOT_FREE;
        pthread_cond_signal(&mailbox->free_slot);
    }
    pthread_mutex_unlock(&mailbox->mutex);
}

static int frame_slot_index(const struct frame_mailbox *mailbox,
                            const struct frame_slot *slot)
{
    for (size_t i = 0; i < FRAME_MAILBOX_SLOTS; ++i) {
        if (&mailbox->slots[i] == slot) {
            return (int)i;
        }
    }

    return -1;
}

static int frame_mailbox_publish(struct frame_mailbox *mailbox,
                                 struct frame_slot *slot,
                                 double receive_ms)
{
    pthread_mutex_lock(&mailbox->mutex);

    const int slot_index = frame_slot_index(mailbox, slot);
    if (slot_index < 0 || slot->state != FRAME_SLOT_RECEIVING) {
        pthread_mutex_unlock(&mailbox->mutex);
        return -1;
    }

    if (mailbox->have_previous_received_id) {
        if (slot->header.frame_id != mailbox->previous_received_id + 1u) {
            mailbox->transport_sequence_errors += 1u;
        }
    } else {
        if (slot->header.frame_id != 0u) {
            mailbox->transport_sequence_errors += 1u;
        }
        mailbox->first_pts_nanos = slot->header.pts_nanos;
        mailbox->have_previous_received_id = true;
    }

    mailbox->previous_received_id = slot->header.frame_id;
    mailbox->last_pts_nanos = slot->header.pts_nanos;
    mailbox->received_frames += 1u;
    if (slot->header.rect_count == 0u) {
        mailbox->received_full_frames += 1u;
    } else {
        mailbox->received_delta_frames += 1u;
        mailbox->received_delta_rects += slot->header.rect_count;
    }
    timing_add(&mailbox->receive, receive_ms);
    slot->receive_ms = receive_ms;

    if (mailbox->ready_count >= FRAME_MAILBOX_SLOTS) {
        pthread_mutex_unlock(&mailbox->mutex);
        return -1;
    }

    slot->state = FRAME_SLOT_READY;
    mailbox->ready_queue[mailbox->ready_tail] = slot_index;
    mailbox->ready_tail =
        (mailbox->ready_tail + 1u) % FRAME_MAILBOX_SLOTS;
    mailbox->ready_count += 1u;
    if (mailbox->ready_count > mailbox->max_ready_count) {
        mailbox->max_ready_count = mailbox->ready_count;
    }

    pthread_cond_signal(&mailbox->ready);
    pthread_mutex_unlock(&mailbox->mutex);
    return 0;
}

static struct frame_slot *frame_mailbox_acquire_next(
    struct frame_mailbox *mailbox)
{
    pthread_mutex_lock(&mailbox->mutex);

    while (mailbox->ready_count == 0u &&
           !mailbox->closed && !stop_requested) {
        struct timespec deadline;
        if (clock_gettime(CLOCK_REALTIME, &deadline) != 0) {
            pthread_mutex_unlock(&mailbox->mutex);
            return NULL;
        }

        deadline.tv_nsec += 100000000L;
        if (deadline.tv_nsec >= 1000000000L) {
            deadline.tv_sec += 1;
            deadline.tv_nsec -= 1000000000L;
        }

        (void)pthread_cond_timedwait(&mailbox->ready, &mailbox->mutex,
                                     &deadline);
    }

    struct frame_slot *slot = NULL;
    if (mailbox->ready_count > 0u) {
        const int slot_index = mailbox->ready_queue[mailbox->ready_head];
        mailbox->ready_head =
            (mailbox->ready_head + 1u) % FRAME_MAILBOX_SLOTS;
        mailbox->ready_count -= 1u;
        slot = &mailbox->slots[(size_t)slot_index];
        slot->state = FRAME_SLOT_DISPLAY;
    }

    pthread_mutex_unlock(&mailbox->mutex);
    return slot;
}

static bool frame_mailbox_has_ready(struct frame_mailbox *mailbox)
{
    pthread_mutex_lock(&mailbox->mutex);
    const bool has_ready = mailbox->ready_count > 0u;
    pthread_mutex_unlock(&mailbox->mutex);
    return has_ready;
}

static void frame_mailbox_release_display(struct frame_mailbox *mailbox,
                                          struct frame_slot *slot)
{
    pthread_mutex_lock(&mailbox->mutex);
    if (slot != NULL && slot->state == FRAME_SLOT_DISPLAY) {
        slot->state = FRAME_SLOT_FREE;
        pthread_cond_signal(&mailbox->free_slot);
    }
    pthread_mutex_unlock(&mailbox->mutex);
}

static void *receiver_thread_main(void *data)
{
    struct frame_mailbox *mailbox = data;

    while (!stop_requested) {
        const double slot_wait_start = monotonic_seconds();
        struct frame_slot *slot = frame_mailbox_begin_receive(mailbox);
        const double slot_wait_end = monotonic_seconds();
        timing_add(
            &mailbox->free_slot_wait,
            (slot_wait_end - slot_wait_start) * 1000.0
        );
        if (slot == NULL) {
            pthread_mutex_lock(&mailbox->mutex);
            const bool closed = mailbox->closed;
            pthread_mutex_unlock(&mailbox->mutex);

            if (stop_requested || closed) {
                frame_mailbox_close(mailbox, false);
                return NULL;
            }

            fprintf(stderr,
                    "frame mailbox failed while waiting for a free slot\n");
            frame_mailbox_close(mailbox, true);
            return NULL;
        }

        uint8_t raw_header[FRAME_HEADER_SIZE];
        const int header_result =
            receive_exact(mailbox->client_fd, raw_header, sizeof(raw_header));
        if (header_result == 0) {
            frame_mailbox_cancel_receive(mailbox, slot);
            frame_mailbox_close(mailbox, false);
            return NULL;
        }
        if (header_result == -3 && stop_requested) {
            frame_mailbox_cancel_receive(mailbox, slot);
            frame_mailbox_close(mailbox, false);
            return NULL;
        }
        if (header_result != 1) {
            fprintf(stderr, "failed to receive complete frame header\n");
            frame_mailbox_cancel_receive(mailbox, slot);
            frame_mailbox_close(mailbox, true);
            return NULL;
        }

        if (parse_frame_header(raw_header, &slot->header) != 0) {
            frame_mailbox_cancel_receive(mailbox, slot);
            frame_mailbox_close(mailbox, true);
            return NULL;
        }

        const double receive_start = monotonic_seconds();

        if (slot->header.rect_count > 0u) {
            uint8_t raw_rects[
                FRAME_MAX_RECTS * FRAME_RECT_DESCRIPTOR_SIZE
            ];
            const size_t rect_bytes =
                (size_t)slot->header.rect_count *
                FRAME_RECT_DESCRIPTOR_SIZE;
            if (receive_exact(mailbox->client_fd, raw_rects,
                              rect_bytes) != 1 ||
                parse_frame_rects(raw_rects, slot) != 0) {
                if (!stop_requested) {
                    fprintf(stderr,
                            "failed to receive/parse delta descriptors\n");
                }
                frame_mailbox_cancel_receive(mailbox, slot);
                frame_mailbox_close(mailbox, !stop_requested);
                return NULL;
            }
        }

        if (receive_exact(mailbox->client_fd, slot->plane_y,
                          slot->header.size_y) != 1) {
            if (!stop_requested) {
                fprintf(stderr, "failed to receive complete frame payload\n");
            }
            frame_mailbox_cancel_receive(mailbox, slot);
            frame_mailbox_close(mailbox, !stop_requested);
            return NULL;
        }
        const double receive_end = monotonic_seconds();
        const double receive_ms =
            (receive_end - receive_start) * 1000.0;

        if (receive_ms > 16.667) {
            const uint64_t payload_bytes =
                (uint64_t)slot->header.size_y +
                (uint64_t)slot->header.rect_count *
                    FRAME_RECT_DESCRIPTOR_SIZE;
            const double receive_gbps =
                receive_ms > 0.0
                    ? (double)payload_bytes * 8.0 / receive_ms / 1000000.0
                    : 0.0;
            fprintf(stderr,
                    "slow receive pipeline: frame=%llu type=%s rects=%u "
                    "bytes=%.2fMiB receive=%.3fms rate=%.2fGb/s\n",
                    (unsigned long long)slot->header.frame_id,
                    slot->header.rect_count == 0u ? "FULL" : "DELTA",
                    slot->header.rect_count,
                    (double)payload_bytes / (1024.0 * 1024.0),
                    receive_ms,
                    receive_gbps);
        }

        if (frame_mailbox_publish(
                mailbox, slot, receive_ms) != 0) {
            fprintf(stderr, "failed to publish received frame\n");
            frame_mailbox_cancel_receive(mailbox, slot);
            frame_mailbox_close(mailbox, true);
            return NULL;
        }
    }

    frame_mailbox_close(mailbox, false);
    return NULL;
}

static GLuint compile_shader(GLenum type, const char *source)
{
    const GLuint shader = glCreateShader(type);
    if (shader == 0) {
        return 0;
    }

    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);

    GLint compiled = GL_FALSE;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    if (compiled == GL_TRUE) {
        return shader;
    }

    GLint length = 0;
    glGetShaderiv(shader, GL_INFO_LOG_LENGTH, &length);
    if (length > 1) {
        char *log = malloc((size_t)length);
        if (log != NULL) {
            glGetShaderInfoLog(shader, length, NULL, log);
            fprintf(stderr, "shader compile failed: %s\n", log);
            free(log);
        }
    }

    glDeleteShader(shader);
    return 0;
}

static GLuint create_program(const char *fragment_source)
{
    static const char *vertex_source =
        "attribute vec2 a_position;\n"
        "attribute vec2 a_texcoord;\n"
        "varying vec2 v_texcoord;\n"
        "void main() {\n"
        "  gl_Position = vec4(a_position, 0.0, 1.0);\n"
        "  v_texcoord = a_texcoord;\n"
        "}\n";

    const GLuint vertex = compile_shader(GL_VERTEX_SHADER, vertex_source);
    if (vertex == 0) {
        return 0;
    }

    const GLuint fragment = compile_shader(GL_FRAGMENT_SHADER, fragment_source);
    if (fragment == 0) {
        glDeleteShader(vertex);
        return 0;
    }

    const GLuint program = glCreateProgram();
    if (program == 0) {
        glDeleteShader(fragment);
        glDeleteShader(vertex);
        return 0;
    }

    glAttachShader(program, vertex);
    glAttachShader(program, fragment);
    glBindAttribLocation(program, 0, "a_position");
    glBindAttribLocation(program, 1, "a_texcoord");
    glLinkProgram(program);

    glDeleteShader(fragment);
    glDeleteShader(vertex);

    GLint linked = GL_FALSE;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    if (linked == GL_TRUE) {
        return program;
    }

    GLint length = 0;
    glGetProgramiv(program, GL_INFO_LOG_LENGTH, &length);
    if (length > 1) {
        char *log = malloc((size_t)length);
        if (log != NULL) {
            glGetProgramInfoLog(program, length, NULL, log);
            fprintf(stderr, "program link failed: %s\n", log);
            free(log);
        }
    }

    glDeleteProgram(program);
    return 0;
}

static GLuint create_yuv422_program(void)
{
    static const char *fragment_source =
        "precision highp float;\n"
        "uniform sampler2D u_packed422;\n"
        "uniform float u_brightness;\n"
        "varying vec2 v_texcoord;\n"
        "void main() {\n"
        "  float pixel_x = floor(gl_FragCoord.x);\n"
        "  float pair_x = floor(pixel_x * 0.5);\n"
        "  float sample_x = (pair_x + 0.5) / 2560.0;\n"
        "  vec4 yuv_pair = texture2D(u_packed422, vec2(sample_x, v_texcoord.y));\n"
        "  float y = mod(pixel_x, 2.0) < 1.0 ? yuv_pair.r : yuv_pair.b;\n"
        "  float u = yuv_pair.g - 0.5;\n"
        "  float v = yuv_pair.a - 0.5;\n"
        "  vec3 rgb;\n"
        "  rgb.r = y + 1.5748 * v;\n"
        "  rgb.g = y - 0.187324 * u - 0.468124 * v;\n"
        "  rgb.b = y + 1.8556 * u;\n"
        "  gl_FragColor = vec4(clamp(rgb, 0.0, 1.0) * u_brightness, 1.0);\n"
        "}\n";

    return create_program(fragment_source);
}

static int choose_egl_config(EGLDisplay display, EGLConfig *config_out)
{
    const EGLint attributes[] = {
        EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
        EGL_RED_SIZE, 8,
        EGL_GREEN_SIZE, 8,
        EGL_BLUE_SIZE, 8,
        EGL_ALPHA_SIZE, 0,
        EGL_NONE,
    };

    EGLint config_count = 0;
    if (!eglGetConfigs(display, NULL, 0, &config_count) || config_count <= 0) {
        return -1;
    }

    EGLConfig *configs = calloc((size_t)config_count, sizeof(*configs));
    if (configs == NULL) {
        return -1;
    }

    EGLint matched = 0;
    if (!eglChooseConfig(display, attributes, configs, config_count, &matched) ||
        matched <= 0) {
        free(configs);
        return -1;
    }

    int result = -1;
    for (EGLint i = 0; i < matched; ++i) {
        EGLint visual_id = 0;
        if (eglGetConfigAttrib(display, configs[i], EGL_NATIVE_VISUAL_ID,
                               &visual_id) &&
            (uint32_t)visual_id == GBM_FORMAT_XRGB8888) {
            *config_out = configs[i];
            result = 0;
            break;
        }
    }

    free(configs);
    return result;
}

static void drm_fb_destroy_callback(struct gbm_bo *bo, void *data)
{
    struct drm_fb *framebuffer = data;
    if (framebuffer == NULL) {
        return;
    }

    const int fd = gbm_device_get_fd(gbm_bo_get_device(bo));
    if (framebuffer->fb_id != 0) {
        (void)drmModeRmFB(fd, framebuffer->fb_id);
    }
    free(framebuffer);
}

static struct drm_fb *framebuffer_for_bo(struct gbm_bo *bo)
{
    struct drm_fb *framebuffer = gbm_bo_get_user_data(bo);
    if (framebuffer != NULL) {
        return framebuffer;
    }

    framebuffer = calloc(1, sizeof(*framebuffer));
    if (framebuffer == NULL) {
        return NULL;
    }

    const int fd = gbm_device_get_fd(gbm_bo_get_device(bo));
    const uint32_t width = gbm_bo_get_width(bo);
    const uint32_t height = gbm_bo_get_height(bo);
    const uint32_t format = gbm_bo_get_format(bo);
    const uint32_t handle = gbm_bo_get_handle(bo).u32;
    const uint32_t stride = gbm_bo_get_stride(bo);
    const uint64_t modifier = gbm_bo_get_modifier(bo);

    const uint32_t handles[4] = {handle, 0, 0, 0};
    const uint32_t pitches[4] = {stride, 0, 0, 0};
    const uint32_t offsets[4] = {0, 0, 0, 0};
    const uint64_t modifiers[4] = {modifier, 0, 0, 0};

    int result = -1;
    if (modifier != DRM_FORMAT_MOD_INVALID &&
        modifier != DRM_FORMAT_MOD_LINEAR) {
        result = drmModeAddFB2WithModifiers(
            fd, width, height, format, handles, pitches, offsets, modifiers,
            &framebuffer->fb_id, DRM_MODE_FB_MODIFIERS);
    }

    if (result != 0) {
        result = drmModeAddFB2(fd, width, height, format, handles, pitches,
                               offsets, &framebuffer->fb_id, 0);
    }

    if (result != 0) {
        fprintf(stderr, "failed to create KMS framebuffer: %s\n",
                strerror(errno));
        free(framebuffer);
        return NULL;
    }

    gbm_bo_set_user_data(bo, framebuffer, drm_fb_destroy_callback);
    return framebuffer;
}

static int renderer_init(struct renderer *renderer, int drm_fd,
                         const struct monitoros_scanout_target *target)
{
    memset(renderer, 0, sizeof(*renderer));
    renderer->brightness_fd = -1;
    renderer->drm_fd = drm_fd;
    renderer->target = target;
    renderer->egl_display = EGL_NO_DISPLAY;
    renderer->egl_context = EGL_NO_CONTEXT;
    renderer->egl_surface = EGL_NO_SURFACE;

    renderer->gbm_device = gbm_create_device(drm_fd);
    if (renderer->gbm_device == NULL) {
        fprintf(stderr, "gbm_create_device failed\n");
        return -1;
    }

    renderer->gbm_surface = gbm_surface_create(
        renderer->gbm_device, MONITOROS_WIDTH, MONITOROS_HEIGHT,
        GBM_FORMAT_XRGB8888, GBM_BO_USE_SCANOUT | GBM_BO_USE_RENDERING);
    if (renderer->gbm_surface == NULL) {
        fprintf(stderr, "gbm_surface_create failed\n");
        return -1;
    }

    PFNEGLGETPLATFORMDISPLAYEXTPROC get_platform_display =
        (PFNEGLGETPLATFORMDISPLAYEXTPROC)
            eglGetProcAddress("eglGetPlatformDisplayEXT");

    if (get_platform_display != NULL) {
        renderer->egl_display = get_platform_display(
            EGL_PLATFORM_GBM_KHR, renderer->gbm_device, NULL);
    } else {
        renderer->egl_display =
            eglGetDisplay((EGLNativeDisplayType)renderer->gbm_device);
    }

    if (renderer->egl_display == EGL_NO_DISPLAY) {
        fprintf(stderr, "failed to get EGL display for GBM\n");
        return -1;
    }

    EGLint egl_major = 0;
    EGLint egl_minor = 0;
    if (!eglInitialize(renderer->egl_display, &egl_major, &egl_minor)) {
        fprintf(stderr, "eglInitialize failed: 0x%04x\n",
                (unsigned)eglGetError());
        return -1;
    }

    if (!eglBindAPI(EGL_OPENGL_ES_API)) {
        fprintf(stderr, "eglBindAPI(EGL_OPENGL_ES_API) failed\n");
        return -1;
    }

    if (choose_egl_config(renderer->egl_display, &renderer->egl_config) != 0) {
        fprintf(stderr, "no EGL XRGB8888 window config found\n");
        return -1;
    }

    const EGLint context_attributes[] = {
        EGL_CONTEXT_CLIENT_VERSION, 2,
        EGL_NONE,
    };
    renderer->egl_context = eglCreateContext(
        renderer->egl_display, renderer->egl_config, EGL_NO_CONTEXT,
        context_attributes);
    if (renderer->egl_context == EGL_NO_CONTEXT) {
        fprintf(stderr, "eglCreateContext failed: 0x%04x\n",
                (unsigned)eglGetError());
        return -1;
    }

    renderer->egl_surface = eglCreateWindowSurface(
        renderer->egl_display, renderer->egl_config,
        (EGLNativeWindowType)renderer->gbm_surface, NULL);
    if (renderer->egl_surface == EGL_NO_SURFACE) {
        fprintf(stderr, "eglCreateWindowSurface failed: 0x%04x\n",
                (unsigned)eglGetError());
        return -1;
    }

    if (!eglMakeCurrent(renderer->egl_display, renderer->egl_surface,
                        renderer->egl_surface, renderer->egl_context)) {
        fprintf(stderr, "eglMakeCurrent failed: 0x%04x\n",
                (unsigned)eglGetError());
        return -1;
    }

    const char *egl_extensions =
        eglQueryString(renderer->egl_display, EGL_EXTENSIONS);
    renderer->has_buffer_age =
        extension_list_contains(egl_extensions, "EGL_EXT_buffer_age");

    (void)eglSwapInterval(renderer->egl_display, 0);

    GLint max_texture_size = 0;
    glGetIntegerv(GL_MAX_TEXTURE_SIZE, &max_texture_size);
    if (max_texture_size < (GLint)MONITOROS_WIDTH) {
        fprintf(stderr,
                "GL_MAX_TEXTURE_SIZE=%d is below required width %u\n",
                max_texture_size, MONITOROS_WIDTH);
        return -1;
    }

    renderer->program_yuv422 = create_yuv422_program();
    if (renderer->program_yuv422 == 0) {
        return -1;
    }

    renderer->uniform_yuv422 =
        glGetUniformLocation(renderer->program_yuv422, "u_packed422");
    renderer->uniform_brightness_yuv422 =
        glGetUniformLocation(renderer->program_yuv422, "u_brightness");
    if (renderer->uniform_yuv422 < 0 ||
        renderer->uniform_brightness_yuv422 < 0) {
        fprintf(stderr, "failed to resolve shader uniforms\n");
        return -1;
    }

    /*
     * Texture row zero is the top of the ScreenCaptureKit image. OpenGL's
     * framebuffer origin is bottom-left, so the bottom vertices sample v=1
     * and the top vertices sample v=0.
     */
    static const GLfloat vertices[] = {
        -1.0f, -1.0f, 0.0f, 1.0f,
         1.0f, -1.0f, 1.0f, 1.0f,
        -1.0f,  1.0f, 0.0f, 0.0f,
         1.0f,  1.0f, 1.0f, 0.0f,
    };

    glGenBuffers(1, &renderer->vertex_buffer);
    glBindBuffer(GL_ARRAY_BUFFER, renderer->vertex_buffer);
    glBufferData(GL_ARRAY_BUFFER, (GLsizeiptr)sizeof(vertices), vertices,
                 GL_STATIC_DRAW);

    glGenTextures(1, &renderer->texture_yuv422);
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, renderer->texture_yuv422);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_NEAREST);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    glTexImage2D(GL_TEXTURE_2D, 0, GL_RGBA,
                 (GLsizei)(MONITOROS_WIDTH / 2u),
                 (GLsizei)MONITOROS_HEIGHT, 0,
                 GL_RGBA, GL_UNSIGNED_BYTE, NULL);

    if (glGetError() != GL_NO_ERROR) {
        fprintf(stderr, "OpenGL texture setup failed\n");
        return -1;
    }

    printf("EGL: %d.%d, vendor=%s\n",
           egl_major, egl_minor, eglQueryString(renderer->egl_display,
                                                 EGL_VENDOR));
    printf("GLES renderer: %s\n",
           (const char *)glGetString(GL_RENDERER));
    printf("GLES version: %s\n",
           (const char *)glGetString(GL_VERSION));
    printf("EGL buffer age: %s\n",
           renderer->has_buffer_age ? "EGL_EXT_buffer_age" : "unavailable");
    return 0;
}

static void renderer_destroy(struct renderer *renderer)
{
    if (renderer->egl_display != EGL_NO_DISPLAY &&
        renderer->egl_context != EGL_NO_CONTEXT) {
        (void)eglMakeCurrent(renderer->egl_display, renderer->egl_surface,
                             renderer->egl_surface, renderer->egl_context);

        if (renderer->texture_yuv422 != 0) {
            glDeleteTextures(1, &renderer->texture_yuv422);
        }
        if (renderer->vertex_buffer != 0) {
            glDeleteBuffers(1, &renderer->vertex_buffer);
        }
        if (renderer->program_yuv422 != 0) {
            glDeleteProgram(renderer->program_yuv422);
        }
    }

    if (renderer->pending_bo != NULL && renderer->gbm_surface != NULL) {
        gbm_surface_release_buffer(renderer->gbm_surface,
                                   renderer->pending_bo);
        renderer->pending_bo = NULL;
    }

    if (renderer->current_bo != NULL && renderer->gbm_surface != NULL) {
        gbm_surface_release_buffer(renderer->gbm_surface,
                                   renderer->current_bo);
        renderer->current_bo = NULL;
    }

    if (renderer->egl_display != EGL_NO_DISPLAY) {
        (void)eglMakeCurrent(renderer->egl_display, EGL_NO_SURFACE,
                             EGL_NO_SURFACE, EGL_NO_CONTEXT);
        if (renderer->egl_surface != EGL_NO_SURFACE) {
            (void)eglDestroySurface(renderer->egl_display,
                                    renderer->egl_surface);
        }
        if (renderer->egl_context != EGL_NO_CONTEXT) {
            (void)eglDestroyContext(renderer->egl_display,
                                    renderer->egl_context);
        }
        (void)eglTerminate(renderer->egl_display);
    }

    if (renderer->gbm_surface != NULL) {
        gbm_surface_destroy(renderer->gbm_surface);
    }
    if (renderer->gbm_device != NULL) {
        gbm_device_destroy(renderer->gbm_device);
    }
}

static void page_flip_handler(int fd, unsigned int frame,
                              unsigned int seconds, unsigned int useconds,
                              void *data)
{
    (void)fd;
    (void)frame;
    (void)seconds;
    (void)useconds;

    struct renderer *renderer = data;
    renderer->flip_pending = false;
}

static int renderer_complete_pending_flip(struct renderer *renderer,
                                          bool interruptible,
                                          double *wait_ms)
{
    if (!renderer->flip_pending) {
        *wait_ms = 0.0;
        return 0;
    }

    const double wait_start = monotonic_seconds();
    drmEventContext context = {
        .version = 2,
        .page_flip_handler = page_flip_handler,
    };

    while (renderer->flip_pending) {
        struct pollfd descriptor = {
            .fd = renderer->drm_fd,
            .events = POLLIN,
        };

        const int result = poll(&descriptor, 1, -1);
        if (result > 0) {
            if ((descriptor.revents & POLLIN) != 0) {
                if (drmHandleEvent(renderer->drm_fd, &context) != 0) {
                    return -1;
                }
            }
            continue;
        }
        if (result < 0 && errno == EINTR) {
            if (interruptible && stop_requested) {
                return -2;
            }
            continue;
        }
        return -1;
    }

    if (renderer->pending_bo == NULL) {
        fprintf(stderr, "page flip completed without a pending GBM buffer\n");
        return -1;
    }

    if (renderer->current_bo != NULL) {
        gbm_surface_release_buffer(renderer->gbm_surface,
                                   renderer->current_bo);
    }
    renderer->current_bo = renderer->pending_bo;
    renderer->pending_bo = NULL;

    *wait_ms = (monotonic_seconds() - wait_start) * 1000.0;
    return 0;
}

static int renderer_present(struct renderer *renderer,
                            const struct frame_slot *slot,
                            bool present_to_kms,
                            double *render_ms)
{
    const struct frame_header *header = &slot->header;
    const uint8_t *plane_y = slot->plane_y;
    struct damage_set current_damage;
    damage_set_from_slot(slot, &current_damage);
    if (renderer->brightness_redraw_pending) {
        current_damage.full = true;
        current_damage.rect_count = 0u;
    }
    const double render_start = monotonic_seconds();

    glPixelStorei(GL_UNPACK_ALIGNMENT, 1);
    glActiveTexture(GL_TEXTURE2);
    glBindTexture(GL_TEXTURE_2D, renderer->texture_yuv422);

    if (header->rect_count == 0u) {
        glTexSubImage2D(GL_TEXTURE_2D, 0, 0, 0,
                        (GLsizei)(MONITOROS_WIDTH / 2u),
                        (GLsizei)MONITOROS_HEIGHT,
                        GL_RGBA, GL_UNSIGNED_BYTE, plane_y);
    } else {
        size_t payload_offset = 0u;
        for (uint32_t i = 0; i < header->rect_count; ++i) {
            const struct frame_rect *rect = &slot->rects[i];
            glTexSubImage2D(
                GL_TEXTURE_2D, 0,
                (GLint)(rect->x / 2u),
                (GLint)rect->y,
                (GLsizei)(rect->width / 2u),
                (GLsizei)rect->height,
                GL_RGBA, GL_UNSIGNED_BYTE,
                plane_y + payload_offset);
            payload_offset +=
                (size_t)rect->width *
                (size_t)rect->height * 2u;
        }
    }

    glUseProgram(renderer->program_yuv422);
    glUniform1i(renderer->uniform_yuv422, 2);
    glUniform1f(
        renderer->uniform_brightness_yuv422,
        (GLfloat)brightness_software_scale(renderer->brightness_unit));

    glViewport(0, 0, (GLsizei)MONITOROS_WIDTH,
               (GLsizei)MONITOROS_HEIGHT);

    glBindBuffer(GL_ARRAY_BUFFER, renderer->vertex_buffer);
    glEnableVertexAttribArray(0);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE,
                          4 * (GLsizei)sizeof(GLfloat),
                          (const void *)0);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE,
                          4 * (GLsizei)sizeof(GLfloat),
                          (const void *)(2 * sizeof(GLfloat)));

    EGLint buffer_age = 0;
    if (renderer->has_buffer_age) {
        if (!eglQuerySurface(renderer->egl_display, renderer->egl_surface,
                             EGL_BUFFER_AGE_EXT, &buffer_age)) {
            renderer->buffer_age_query_failures += 1u;
            buffer_age = 0;
        }
    }

    if (buffer_age > renderer->max_buffer_age) {
        renderer->max_buffer_age = buffer_age;
    }

    struct frame_rect redraw_rects[REDRAW_MAX_RECTS];
    size_t redraw_count = 0u;
    const bool partial_redraw =
        renderer->has_buffer_age &&
        build_partial_redraw_rects(
            renderer, &current_damage, buffer_age,
            redraw_rects, REDRAW_MAX_RECTS, &redraw_count);

    if (partial_redraw) {
        glEnable(GL_SCISSOR_TEST);
        for (size_t i = 0; i < redraw_count; ++i) {
            GLint x = 0;
            GLint y = 0;
            GLsizei width = 0;
            GLsizei height = 0;
            frame_rect_to_gl_scissor(
                &redraw_rects[i], &x, &y, &width, &height);
            glScissor(x, y, width, height);
            glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
        }
        glDisable(GL_SCISSOR_TEST);
    } else {
        glDisable(GL_SCISSOR_TEST);
        glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    }

    const GLenum gl_error = glGetError();
    if (gl_error != GL_NO_ERROR) {
        fprintf(stderr, "OpenGL render failed: 0x%04x\n", gl_error);
        return -1;
    }

    if (!eglSwapBuffers(renderer->egl_display, renderer->egl_surface)) {
        fprintf(stderr, "eglSwapBuffers failed: 0x%04x\n",
                (unsigned)eglGetError());
        return -1;
    }

    if (renderer->brightness_redraw_pending) {
        renderer->brightness_redraw_pending = false;
    }

    if (partial_redraw) {
        renderer->partial_redraw_frames += 1u;
        renderer->partial_redraw_rects += redraw_count;
    } else {
        renderer->full_redraw_frames += 1u;
        if (renderer->has_buffer_age && buffer_age == 0) {
            renderer->buffer_age_zero_frames += 1u;
        } else if (renderer->has_buffer_age &&
                   buffer_age > 0 &&
                   !current_damage.full) {
            renderer->buffer_age_history_fallbacks += 1u;
        }
    }
    damage_history_push(renderer, &current_damage);

    struct gbm_bo *next_bo =
        gbm_surface_lock_front_buffer(renderer->gbm_surface);
    if (next_bo == NULL) {
        fprintf(stderr, "gbm_surface_lock_front_buffer failed\n");
        return -1;
    }

    const double render_end = monotonic_seconds();
    *render_ms = (render_end - render_start) * 1000.0;

    if (!present_to_kms) {
        // The GL texture state now includes this delta, but the corresponding
        // scanout is obsolete. Releasing the swapped BO lets the next queued
        // frame catch up without losing stateful yuvf updates.
        gbm_surface_release_buffer(renderer->gbm_surface, next_bo);
        return 0;
    }

    struct drm_fb *framebuffer = framebuffer_for_bo(next_bo);
    if (framebuffer == NULL) {
        gbm_surface_release_buffer(renderer->gbm_surface, next_bo);
        return -1;
    }

    if (renderer->flip_pending || renderer->pending_bo != NULL) {
        fprintf(stderr, "renderer attempted to queue a second pending flip\n");
        gbm_surface_release_buffer(renderer->gbm_surface, next_bo);
        return -1;
    }

    if (!renderer->modeset_active) {
        uint32_t connector_id = renderer->target->connector_id;
        drmModeModeInfo mode = renderer->target->mode;
        if (drmModeSetCrtc(renderer->drm_fd, renderer->target->crtc_id,
                           framebuffer->fb_id, 0, 0, &connector_id, 1,
                           &mode) != 0) {
            fprintf(stderr, "initial drmModeSetCrtc failed: %s\n",
                    strerror(errno));
            gbm_surface_release_buffer(renderer->gbm_surface, next_bo);
            return -1;
        }

        renderer->current_bo = next_bo;
        renderer->modeset_active = true;
        return 0;
    }

    renderer->pending_bo = next_bo;
    renderer->flip_pending = true;
    if (drmModePageFlip(renderer->drm_fd, renderer->target->crtc_id,
                        framebuffer->fb_id, DRM_MODE_PAGE_FLIP_EVENT,
                        renderer) != 0) {
        fprintf(stderr, "drmModePageFlip failed: %s\n", strerror(errno));
        renderer->flip_pending = false;
        renderer->pending_bo = NULL;
        gbm_surface_release_buffer(renderer->gbm_surface, next_bo);
        return -1;
    }

    return 0;
}

static void metrics_record(struct stream_metrics *metrics,
                           const struct frame_header *header,
                           double wall_seconds,
                           double render_ms,
                           double flip_ms,
                           double total_ms)
{
    if (metrics->have_previous_frame_id) {
        if (header->frame_id <= metrics->previous_frame_id) {
            metrics->presentation_order_errors += 1u;
        } else if (header->frame_id > metrics->previous_frame_id + 1u) {
            metrics->presentation_skips +=
                header->frame_id - metrics->previous_frame_id - 1u;
        }
    } else {
        metrics->first_wall_seconds = wall_seconds;
        metrics->have_previous_frame_id = true;
    }

    metrics->previous_frame_id = header->frame_id;
    metrics->last_wall_seconds = wall_seconds;
    metrics->frames += 1u;

    timing_add(&metrics->render, render_ms);
    timing_add(&metrics->flip, flip_ms);
    timing_add(&metrics->total, total_ms);
}

static void print_metrics(const struct stream_metrics *metrics,
                          const struct frame_mailbox *mailbox,
                          const struct renderer *renderer)
{
    double source_seconds = 0.0;
    if (mailbox->received_frames > 1u &&
        mailbox->last_pts_nanos > mailbox->first_pts_nanos) {
        source_seconds =
            (double)(mailbox->last_pts_nanos - mailbox->first_pts_nanos) /
            1000000000.0;
    }

    double wall_seconds = 0.0;
    if (metrics->frames > 1u &&
        metrics->last_wall_seconds > metrics->first_wall_seconds) {
        wall_seconds =
            metrics->last_wall_seconds - metrics->first_wall_seconds;
    }

    const double source_fps =
        source_seconds > 0.0
            ? (double)(mailbox->received_frames - 1u) / source_seconds
            : 0.0;
    const double presented_fps =
        wall_seconds > 0.0
            ? (double)(metrics->frames - 1u) / wall_seconds
            : 0.0;

    printf("\nmonitorOS 5K stream viewer\n");
    printf("---------------------------\n");
    printf("received frames: %llu\n",
           (unsigned long long)mailbox->received_frames);
    printf("full updates: %llu\n",
           (unsigned long long)mailbox->received_full_frames);
    printf("delta updates: %llu rects=%llu\n",
           (unsigned long long)mailbox->received_delta_frames,
           (unsigned long long)mailbox->received_delta_rects);
    printf("transport sequence errors: %llu\n",
           (unsigned long long)mailbox->transport_sequence_errors);
    printf("source cadence: %.3f fps\n", source_fps);
    printf("presented frames: %llu\n",
           (unsigned long long)metrics->frames);
    printf("receiver max queued updates: %zu\n",
           mailbox->max_ready_count);
    printf("A/V sync catch-up drops: %llu\n",
           (unsigned long long)metrics->sync_drops);
    printf("presentation skipped frame IDs: %llu\n",
           (unsigned long long)metrics->presentation_skips);
    printf("presentation order errors: %llu\n",
           (unsigned long long)metrics->presentation_order_errors);
    printf("local present cadence: %.3f fps\n", presented_fps);
    printf("receiver: mean=%.3f ms max=%.3f ms\n",
           timing_mean(&mailbox->receive), mailbox->receive.max_ms);
    printf("receiver free-slot wait: mean=%.3f ms max=%.3f ms\n",
           timing_mean(&mailbox->free_slot_wait),
           mailbox->free_slot_wait.max_ms);
    printf("GPU upload+render: mean=%.3f ms max=%.3f ms\n",
           timing_mean(&metrics->render), metrics->render.max_ms);
    printf("Radeon redraws: full=%llu partial=%llu rects=%llu\n",
           (unsigned long long)renderer->full_redraw_frames,
           (unsigned long long)renderer->partial_redraw_frames,
           (unsigned long long)renderer->partial_redraw_rects);
    printf("EGL buffer age: supported=%s max=%d zero=%llu "
           "history_fallbacks=%llu query_failures=%llu\n",
           renderer->has_buffer_age ? "yes" : "no",
           renderer->max_buffer_age,
           (unsigned long long)renderer->buffer_age_zero_frames,
           (unsigned long long)renderer->buffer_age_history_fallbacks,
           (unsigned long long)renderer->buffer_age_query_failures);
    printf("A/V sync wait: mean=%.3f ms max=%.3f ms caps=%llu\n",
           timing_mean(&metrics->audio_sync_wait),
           metrics->audio_sync_wait.max_ms,
           (unsigned long long)metrics->audio_sync_wait_caps);
    printf("KMS flip wait: mean=%.3f ms max=%.3f ms\n",
           timing_mean(&metrics->flip), metrics->flip.max_ms);
    printf("display-thread work: mean=%.3f ms max=%.3f ms\n",
           timing_mean(&metrics->total), metrics->total.max_ms);
}

static void usage(const char *program)
{
    printf("usage: %s [--device /dev/dri/cardN] [--bind TARGET] "
           "[--brightness-fd FD] [--self-test]\n",
           program);
    puts("");
    puts("receives monitorOS 5120x2880 packed 4:2:2/yuvf updates");
    puts("them to XRGB with Radeon GLES before stitched-panel page flips");
    printf("default bind: %s\n", DEFAULT_BIND);
    puts("--self-test validates transport and damage history without DRM access");
}

int main(int argc, char **argv)
{
    const char *device = "/dev/dri/card0";
    const char *bind_address = DEFAULT_BIND;
    int brightness_fd = -1;
    bool run_self_test = false;

    for (int i = 1; i < argc; ++i) {
        if (strcmp(argv[i], "--device") == 0) {
            if (++i >= argc) {
                fprintf(stderr, "--device requires a path\n");
                return 64;
            }
            device = argv[i];
        } else if (strcmp(argv[i], "--bind") == 0) {
            if (++i >= argc) {
                fputs("--bind requires HOST:PORT or [IPv6%scope]:PORT\n", stderr);
                return 64;
            }
            bind_address = argv[i];
        } else if (strcmp(argv[i], "--brightness-fd") == 0) {
            if (++i >= argc) {
                fputs("--brightness-fd requires a file descriptor\n", stderr);
                return 64;
            }
            char *end = NULL;
            errno = 0;
            const long parsed = strtol(argv[i], &end, 10);
            if (errno != 0 || end == argv[i] || *end != '\0' ||
                parsed < 0 || parsed > INT32_MAX) {
                fprintf(stderr,
                        "invalid --brightness-fd value: %s\n",
                        argv[i]);
                return 64;
            }
            brightness_fd = (int)parsed;
        } else if (strcmp(argv[i], "--self-test") == 0) {
            run_self_test = true;
        } else if (strcmp(argv[i], "--help") == 0 ||
                   strcmp(argv[i], "-h") == 0) {
            usage(argv[0]);
            return 0;
        } else {
            fprintf(stderr, "unknown argument: %s\n", argv[i]);
            usage(argv[0]);
            return 64;
        }
    }

    if (run_self_test) {
        return self_test();
    }

    struct sigaction action = {
        .sa_handler = handle_signal,
    };
    sigemptyset(&action.sa_mask);
    if (sigaction(SIGINT, &action, NULL) != 0 ||
        sigaction(SIGTERM, &action, NULL) != 0) {
        perror("sigaction");
        return 1;
    }

    int result = 1;
    int drm_fd = -1;
    int listener_fd = -1;
    int client_fd = -1;
    struct frame_mailbox frame_mailbox = {0};
    bool frame_mailbox_initialized = false;
    pthread_t receiver_thread;
    bool receiver_started = false;
    struct renderer renderer = {0};
    struct monitoros_scanout_target target = {0};
    struct stream_metrics metrics = {0};
    struct monitoros_audio_sink *audio_sink = NULL;

    drm_fd = open(device, O_RDWR | O_CLOEXEC);
    if (drm_fd < 0) {
        fprintf(stderr, "failed to open %s: %s\n", device, strerror(errno));
        goto cleanup;
    }

    if (drmIsMaster(drm_fd) != 1) {
        fprintf(stderr,
                "stream viewer requires DRM master; run from a text console "
                "with the compositor/display manager stopped\n");
        goto cleanup;
    }

    if (monitoros_find_scanout_target(drm_fd, &target) != 0) {
        fprintf(stderr,
                "no connected 5120x2880 stitched mode found on %s\n", device);
        goto cleanup;
    }

    printf("target: connector=%u crtc=%u mode=%ux%u@%d\n",
           target.connector_id, target.crtc_id, target.mode.hdisplay,
           target.mode.vdisplay, target.mode.vrefresh);

    if (disable_target_crtc(drm_fd, &target) != 0) {
        fprintf(stderr, "failed to power down idle panel CRTC %u: %s\n",
                target.crtc_id, strerror(errno));
        goto cleanup;
    }
    puts("idle panel scanout disabled; waiting for source");

    if (renderer_init(&renderer, drm_fd, &target) != 0) {
        goto cleanup;
    }
    if (renderer_configure_brightness(&renderer, brightness_fd) != 0) {
        goto cleanup;
    }

    if (monitoros_audio_sink_create(&audio_sink) != 0) {
        fprintf(stderr,
                "failed to start speaker audio sink: %s\n",
                strerror(errno));
        goto cleanup;
    }

    listener_fd = create_listener(bind_address);
    if (listener_fd < 0) {
        goto cleanup;
    }

    printf("listening on %s for 5120x2880 yuvf frames\n", bind_address);
    fflush(stdout);

    client_fd = accept4(listener_fd, NULL, NULL, SOCK_CLOEXEC);
    if (client_fd < 0) {
        if (errno == EINTR && stop_requested) {
            result = 0;
            goto cleanup;
        }
        perror("accept4");
        goto cleanup;
    }

    int receive_buffer_bytes = 0;
    socklen_t receive_buffer_length = sizeof(receive_buffer_bytes);
    if (getsockopt(client_fd, SOL_SOCKET, SO_RCVBUF,
                   &receive_buffer_bytes, &receive_buffer_length) == 0) {
        printf("transport socket: SO_RCVBUF=%d bytes\n",
               receive_buffer_bytes);
    } else {
        fprintf(stderr, "warning: getsockopt(SO_RCVBUF) failed: %s\n",
                strerror(errno));
    }

    puts("transport connected; starting dedicated receiver thread");
    fflush(stdout);

    if (frame_mailbox_init(&frame_mailbox, client_fd) != 0) {
        fprintf(stderr, "failed to allocate/init ordered frame mailbox\n");
        goto cleanup;
    }
    frame_mailbox_initialized = true;

    const int thread_result =
        pthread_create(&receiver_thread, NULL, receiver_thread_main,
                       &frame_mailbox);
    if (thread_result != 0) {
        fprintf(stderr, "pthread_create(receiver) failed: %s\n",
                strerror(thread_result));
        goto cleanup;
    }
    receiver_started = true;

    while (!stop_requested) {
        struct frame_slot *slot = frame_mailbox_acquire_next(&frame_mailbox);
        if (slot == NULL) {
            pthread_mutex_lock(&frame_mailbox.mutex);
            const bool closed = frame_mailbox.closed;
            const bool failed = frame_mailbox.failed;
            pthread_mutex_unlock(&frame_mailbox.mutex);

            if (stop_requested) {
                result = 0;
            } else if (closed) {
                if (failed) {
                    fprintf(stderr, "receiver thread terminated with an error\n");
                } else {
                    puts("transport closed by sender");
                    result = metrics.frames > 0u ? 0 : 1;
                }
            }
            break;
        }

        const double frame_start = monotonic_seconds();
        double audio_sync_wait_ms = 0.0;
        bool audio_sync_wait_cap = false;
        const double audio_sync_ms =
            wait_for_audio_timeline(
                audio_sink,
                slot->header.pts_nanos,
                &audio_sync_wait_ms,
                &audio_sync_wait_cap);
        timing_add(
            &metrics.audio_sync_wait,
            audio_sync_wait_ms);
        if (audio_sync_wait_cap) {
            metrics.audio_sync_wait_caps += 1u;
        }

        /*
         * Delta updates are stateful, so every received update must be applied
         * in order. If the display side falls behind, the bounded receiver FIFO
         * backpressures TCP; the source mailbox then coalesces later SCK damage
         * into the newest pending update.
         */
        double flip_ms = 0.0;
        const int flip_result =
            renderer_complete_pending_flip(&renderer, true, &flip_ms);
        if (flip_result == -2 && stop_requested) {
            result = 0;
            break;
        }
        if (flip_result != 0) {
            break;
        }

        if (renderer_drain_brightness(&renderer) != 0) {
            break;
        }

        const bool drop_late_frame =
            audio_sync_ms < -VIDEO_AUDIO_DROP_LATE_MS &&
            frame_mailbox_has_ready(&frame_mailbox);

        double render_ms = 0.0;
        const int present_result =
            renderer_present(
                &renderer,
                slot,
                !drop_late_frame,
                &render_ms);
        if (present_result != 0) {
            break;
        }

        if (drop_late_frame) {
            metrics.sync_drops += 1u;
            frame_mailbox_release_display(&frame_mailbox, slot);
            continue;
        }

        const double frame_end = monotonic_seconds();
        const double total_ms =
            (frame_end - frame_start) * 1000.0;

        if (audio_sync_wait_ms > 4.0 ||
            render_ms > 25.0 ||
            flip_ms > 25.0 ||
            total_ms > 33.0) {
            fprintf(stderr,
                    "slow display: frame=%llu sync_wait=%.3f ms "
                    "render=%.3f ms flip=%.3f ms total=%.3f ms%s\n",
                    (unsigned long long)slot->header.frame_id,
                    audio_sync_wait_ms,
                    render_ms,
                    flip_ms,
                    total_ms,
                    audio_sync_wait_cap ? " sync-cap" : "");
        }

        metrics_record(
            &metrics, &slot->header, frame_end,
            render_ms, flip_ms, total_ms);

        if (metrics.frames == 1u) {
            printf("first frame visible: id=%llu pts=%llu\n",
                   (unsigned long long)slot->header.frame_id,
                   (unsigned long long)slot->header.pts_nanos);
        } else if ((metrics.frames % 60u) == 0u) {
            pthread_mutex_lock(&frame_mailbox.mutex);
            const uint64_t received_frames = frame_mailbox.received_frames;
            const size_t queued_updates = frame_mailbox.ready_count;
            const struct timing_stat receive_stat = frame_mailbox.receive;
            pthread_mutex_unlock(&frame_mailbox.mutex);

            printf("visible frames=%llu received=%llu queued=%zu "
                   "recv=%.2fms sync_wait=%.2fms render=%.2fms "
                   "flip=%.2fms total=%.2fms "
                   "av_delta=%+.2fms audio_buffer_error=%+.2fms\n",
                   (unsigned long long)metrics.frames,
                   (unsigned long long)received_frames,
                   queued_updates,
                   timing_mean(&receive_stat),
                   timing_mean(&metrics.audio_sync_wait),
                   timing_mean(&metrics.render),
                   timing_mean(&metrics.flip),
                   timing_mean(&metrics.total),
                   audio_sync_ms,
                   monitoros_audio_sink_buffer_error_ms(audio_sink));
        }
        fflush(stdout);
        frame_mailbox_release_display(&frame_mailbox, slot);
    }

cleanup:
    if (receiver_started) {
        shutdown(client_fd, SHUT_RDWR);
        if (frame_mailbox_initialized) {
            frame_mailbox_close(&frame_mailbox, false);
        }
        (void)pthread_join(receiver_thread, NULL);
        receiver_started = false;
    }

    if (renderer.flip_pending) {
        double final_flip_ms = 0.0;
        const int finish_result =
            renderer_complete_pending_flip(&renderer, false, &final_flip_ms);
        if (finish_result != 0) {
            fprintf(stderr, "failed to complete final KMS page flip\n");
            result = 1;
        }
    }

    if (drm_fd >= 0 && target.crtc_id != 0) {
        if (disable_target_crtc(drm_fd, &target) != 0) {
            fprintf(stderr, "failed to disable panel CRTC during cleanup: %s\n",
                    strerror(errno));
            result = 1;
        } else if (renderer.modeset_active) {
            puts("panel scanout disabled after source session");
        }
    }

    if (metrics.frames > 0u && frame_mailbox_initialized) {
        print_metrics(&metrics, &frame_mailbox, &renderer);
    }

    if (client_fd >= 0) {
        close(client_fd);
    }
    if (listener_fd >= 0) {
        close(listener_fd);
    }
    if (frame_mailbox_initialized) {
        frame_mailbox_destroy(&frame_mailbox);
    }
    monitoros_audio_sink_destroy(audio_sink);
    renderer_destroy(&renderer);
    if (drm_fd >= 0) {
        close(drm_fd);
    }

    return result;
}
