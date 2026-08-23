#include "include/ring_buffer.h"

#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>

struct arb_ring {
    float *data;
    size_t frame_capacity;  // power of two
    size_t mask;
    uint32_t channels;
    _Atomic size_t write_pos;   // producer writes, consumer reads
    _Atomic size_t read_pos;    // consumer writes, producer reads
    _Atomic uint64_t overruns;
};

static size_t round_up_pow2(size_t v) {
    size_t p = 1;
    while (p < v) {
        p <<= 1;
    }
    return p;
}

arb_ring *arb_create(size_t min_frames, uint32_t channels) {
    if (min_frames == 0 || channels == 0) {
        return NULL;
    }
    arb_ring *r = calloc(1, sizeof(arb_ring));
    if (!r) {
        return NULL;
    }
    r->frame_capacity = round_up_pow2(min_frames);
    r->mask = r->frame_capacity - 1;
    r->channels = channels;
    r->data = calloc(r->frame_capacity * channels, sizeof(float));
    if (!r->data) {
        free(r);
        return NULL;
    }
    atomic_store_explicit(&r->write_pos, 0, memory_order_relaxed);
    atomic_store_explicit(&r->read_pos, 0, memory_order_relaxed);
    atomic_store_explicit(&r->overruns, 0, memory_order_relaxed);
    return r;
}

void arb_destroy(arb_ring *r) {
    if (!r) {
        return;
    }
    free(r->data);
    free(r);
}

size_t arb_write(arb_ring *r, const float *src, size_t frames) {
    // acquire on read_pos pairs with the consumer's release store, so we
    // observe space it has freed.
    const size_t w = atomic_load_explicit(&r->write_pos, memory_order_relaxed);
    const size_t rd = atomic_load_explicit(&r->read_pos, memory_order_acquire);
    const size_t used = w - rd;
    const size_t free_frames = r->frame_capacity - used;

    size_t n = frames < free_frames ? frames : free_frames;
    if (n < frames) {
        atomic_fetch_add_explicit(&r->overruns, (uint64_t)(frames - n),
                                  memory_order_relaxed);
    }
    if (n == 0) {
        return 0;
    }

    const size_t idx = w & r->mask;
    const size_t first = (idx + n <= r->frame_capacity) ? n : (r->frame_capacity - idx);
    memcpy(r->data + idx * r->channels, src, first * r->channels * sizeof(float));
    if (first < n) {
        memcpy(r->data, src + first * r->channels,
               (n - first) * r->channels * sizeof(float));
    }

    // release so the consumer sees the samples before the index move.
    atomic_store_explicit(&r->write_pos, w + n, memory_order_release);
    return n;
}

size_t arb_read(arb_ring *r, float *dst, size_t frames) {
    const size_t rd = atomic_load_explicit(&r->read_pos, memory_order_relaxed);
    const size_t w = atomic_load_explicit(&r->write_pos, memory_order_acquire);
    const size_t used = w - rd;

    size_t n = frames < used ? frames : used;
    if (n == 0) {
        return 0;
    }

    const size_t idx = rd & r->mask;
    const size_t first = (idx + n <= r->frame_capacity) ? n : (r->frame_capacity - idx);
    memcpy(dst, r->data + idx * r->channels, first * r->channels * sizeof(float));
    if (first < n) {
        memcpy(dst + first * r->channels, r->data,
               (n - first) * r->channels * sizeof(float));
    }

    atomic_store_explicit(&r->read_pos, rd + n, memory_order_release);
    return n;
}

size_t arb_available(const arb_ring *r) {
    const size_t w = atomic_load_explicit(&r->write_pos, memory_order_acquire);
    const size_t rd = atomic_load_explicit(&r->read_pos, memory_order_relaxed);
    return w - rd;
}

uint64_t arb_overruns(const arb_ring *r) {
    return atomic_load_explicit(&r->overruns, memory_order_relaxed);
}

uint32_t arb_channels(const arb_ring *r) { return r->channels; }
