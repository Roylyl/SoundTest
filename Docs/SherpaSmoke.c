// Local simulator smoke test, not a device accuracy benchmark.
#include <SherpaOnnxC/sherpa-onnx/c-api/c-api.h>
#include <assert.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

static double seconds(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec + t.tv_nsec / 1e9;
}
static void run(const SherpaOnnxAudioTagging *tagger, const float *pcm,
                int count, int rate, const char *model, const char *sample) {
  const SherpaOnnxOfflineStream *stream = SherpaOnnxAudioTaggingCreateOfflineStream(tagger);
  assert(stream);
  double start = seconds();
  SherpaOnnxAcceptWaveformOffline(stream, rate, pcm, count);
  const SherpaOnnxAudioEvent *const *results = SherpaOnnxAudioTaggingCompute(tagger, stream, 527);
  double elapsed = seconds() - start;
  assert(results);
  int seen[527] = {0}; int n = 0;
  for (; results[n]; ++n) {
    assert(n < 527 && results[n]->index >= 0 && results[n]->index < 527);
    assert(isfinite(results[n]->prob) && !seen[results[n]->index]);
    seen[results[n]->index] = 1;
  }
  assert(n == 527);
  printf("%s | %s | %.3f s | %d scores | %.3f ms | top5:", model, sample,
         (double)count/rate, n, elapsed*1000);
  for (int i=0; i<5; ++i) printf(" %s=%.6f;", results[i]->name, results[i]->prob);
  puts("");
  SherpaOnnxAudioTaggingFreeResults(results);
  SherpaOnnxDestroyOfflineStream(stream);
}
int main(int argc, char **argv) {
  assert(argc == 3);
  const char *ids[] = {"zipformer", "cedTiny", "cedMini"};
  const SherpaOnnxWave *dog = SherpaOnnxReadWave(argv[2]);
  assert(dog);
  printf("sherpa %s; ONNX Runtime %s\n", SherpaOnnxGetVersionStr(), SherpaOnnxGetOnnxruntimeVersionStr());
  for (int i=0; i<3; ++i) {
    char model[4096], labels[4096];
    snprintf(model,sizeof(model),"%s/%s/model.int8.onnx",argv[1],ids[i]);
    snprintf(labels,sizeof(labels),"%s/%s/class_labels_indices.csv",argv[1],ids[i]);
    SherpaOnnxAudioTaggingConfig config = {0};
    if (i==0) config.model.zipformer.model = model; else config.model.ced = model;
    config.labels = labels; config.model.num_threads = 2; config.model.provider = "cpu";
    config.top_k = 527;
    const SherpaOnnxAudioTagging *tagger = SherpaOnnxCreateAudioTagging(&config);
    assert(tagger);
    int durations[] = {1,2,5,10,30};
    for (int j=0; j<5; ++j) {
      int count = durations[j]*16000;
      float *silence = calloc(count, sizeof(float));
      run(tagger, silence, count,16000,ids[i],"synthetic silence");
      free(silence);
    }
    run(tagger,dog->samples,dog->num_samples,dog->sample_rate,ids[i],"upstream test_wavs/12.wav");
    SherpaOnnxDestroyAudioTagging(tagger);
  }
  SherpaOnnxFreeWave(dog);
  return 0;
}
