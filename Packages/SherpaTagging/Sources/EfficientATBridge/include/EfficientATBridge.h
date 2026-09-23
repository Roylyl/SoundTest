#pragma once
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
// One instance owns one ONNX session, its exact Kaldi mel bank and FFT setup.
void *SoundEfficientATLoad(const char *modelPath, const char *melBankPath,
                           const char *hannPath, int threads,
                           char *error, size_t capacity);
// Input is exactly ten seconds of 32 kHz mono Float32 PCM. The verified ONNX graph
// already applies sigmoid and returns 527 per-class scores.
int SoundEfficientATRun(void *handle, const float *samples, size_t count,
                        float *scores, size_t scoresCount, char *error, size_t capacity);
// Exposed for numerical parity tests; output is row-major [128, 1000] log-Mel features.
int SoundEfficientATExtract(void *handle, const float *samples, size_t count,
                            float *features, size_t featureCount, char *error, size_t capacity);
void SoundEfficientATRelease(void *handle);
#ifdef __cplusplus
}
#endif
