#ifndef SLATE_CWHISPER_H
#define SLATE_CWHISPER_H

#include <stdbool.h>
#include <stddef.h>

// whisper.cpp, loaded at run time from a framework the user chose to
// download. Nothing here links whisper; until slate_whisper_load succeeds,
// every other call is unavailable.

/// Opens the framework binary at `path`. 0 on success (or if already
/// loaded); otherwise writes why into `error`.
int slate_whisper_load(const char *path, char *error, size_t error_length);
bool slate_whisper_is_loaded(void);

/// A model context, or NULL if the model file couldn't be loaded.
void *slate_whisper_init(const char *model_path, bool use_gpu);
/// Transcribes 16 kHz mono samples; 0 on success.
int slate_whisper_run(void *context, const float *samples, int count, const char *language, int threads);
int slate_whisper_segment_count(void *context);
const char *slate_whisper_segment_text(void *context, int index);
void slate_whisper_free(void *context);

#endif
