#include "CWhisper.h"
#include "whisper/whisper.h"

#include <dlfcn.h>
#include <stdio.h>

static void *library;
static struct whisper_context_params (*p_context_default_params)(void);
static struct whisper_context *(*p_init_from_file)(const char *, struct whisper_context_params);
static struct whisper_full_params (*p_full_default_params)(enum whisper_sampling_strategy);
static int (*p_full)(struct whisper_context *, struct whisper_full_params, const float *, int);
static int (*p_full_n_segments)(struct whisper_context *);
static const char *(*p_full_get_segment_text)(struct whisper_context *, int);
static void (*p_free)(struct whisper_context *);
static void (*p_log_set)(ggml_log_callback, void *);

static void quiet(enum ggml_log_level level, const char *text, void *user_data) {
    (void)level; (void)text; (void)user_data;
}

#define LOAD(pointer, name)                                                     \
    *(void **)(&pointer) = dlsym(handle, name);                                 \
    if (!pointer) {                                                             \
        snprintf(error, error_length, "the framework has no %s", name);         \
        dlclose(handle);                                                        \
        return -2;                                                              \
    }

int slate_whisper_load(const char *path, char *error, size_t error_length) {
    if (library) return 0;
    void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
    if (!handle) {
        const char *reason = dlerror();
        snprintf(error, error_length, "%s", reason ? reason : "dlopen failed");
        return -1;
    }
    LOAD(p_context_default_params, "whisper_context_default_params")
    LOAD(p_init_from_file, "whisper_init_from_file_with_params")
    LOAD(p_full_default_params, "whisper_full_default_params")
    LOAD(p_full, "whisper_full")
    LOAD(p_full_n_segments, "whisper_full_n_segments")
    LOAD(p_full_get_segment_text, "whisper_full_get_segment_text")
    LOAD(p_free, "whisper_free")
    LOAD(p_log_set, "whisper_log_set")
    p_log_set(quiet, NULL);
    // Never closed: ggml keeps global state for the life of the process.
    library = handle;
    return 0;
}

bool slate_whisper_is_loaded(void) { return library != NULL; }

void *slate_whisper_init(const char *model_path, bool use_gpu) {
    if (!library) return NULL;
    struct whisper_context_params params = p_context_default_params();
    params.use_gpu = use_gpu;
    params.flash_attn = use_gpu;
    return p_init_from_file(model_path, params);
}

int slate_whisper_run(void *context, const float *samples, int count, const char *language, int threads) {
    if (!library || !context) return -100;
    struct whisper_full_params params = p_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.print_progress = false;
    params.print_realtime = false;
    params.print_timestamps = false;
    params.print_special = false;
    params.translate = false;
    params.no_timestamps = true;
    params.suppress_blank = true;
    params.n_threads = threads;
    params.language = language;
    return p_full((struct whisper_context *)context, params, samples, count);
}

int slate_whisper_segment_count(void *context) {
    return library && context ? p_full_n_segments((struct whisper_context *)context) : 0;
}

const char *slate_whisper_segment_text(void *context, int index) {
    return library && context ? p_full_get_segment_text((struct whisper_context *)context, index) : NULL;
}

void slate_whisper_free(void *context) {
    if (library && context) p_free((struct whisper_context *)context);
}
