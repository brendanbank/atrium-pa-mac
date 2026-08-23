// Single-producer / single-consumer lock-free ring buffer for float PCM.
//
// Why C and not Swift: the producer runs on a CoreAudio render thread.
// That thread must never allocate, take a lock, or make a call that can
// trigger ARC traffic — doing so causes glitches at best and a priority
// inversion at worst. Swift gives no way to *prove* a region is free of
// those; C11 atomics do.
//
// Capacity is rounded up to a power of two so the modulo is a mask.

#ifndef ATRIUM_RING_BUFFER_H
#define ATRIUM_RING_BUFFER_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct arb_ring arb_ring;

/// Allocate a ring holding at least `min_frames` interleaved frames of
/// `channels` floats. Returns NULL on allocation failure.
arb_ring *arb_create(size_t min_frames, uint32_t channels);

/// Free a ring. Must not be called while the render thread is running.
void arb_destroy(arb_ring *r);

/// Producer side — call ONLY from the render thread.
/// Writes `frames` interleaved frames. Returns the number actually
/// written; a short write means the consumer is not draining fast enough.
/// Never blocks, never allocates.
size_t arb_write(arb_ring *r, const float *src, size_t frames);

/// Consumer side — call from any single non-realtime thread.
/// Returns the number of frames read into `dst`.
size_t arb_read(arb_ring *r, float *dst, size_t frames);

/// Frames currently available to the consumer.
size_t arb_available(const arb_ring *r);

/// Total frames the producer had to drop because the buffer was full.
/// Non-zero means the consumer is too slow — surface it, don't ignore it.
uint64_t arb_overruns(const arb_ring *r);

uint32_t arb_channels(const arb_ring *r);

#endif /* ATRIUM_RING_BUFFER_H */
