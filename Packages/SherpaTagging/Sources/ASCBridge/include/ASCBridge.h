#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
void *SoundASCLoad(const char *path, int threads, char *error, size_t capacity);
int SoundASCRun(void *handle, const float *samples, size_t count, float *logits, char *error, size_t capacity);
void SoundASCRelease(void *handle);
#ifdef __cplusplus
}
#endif
