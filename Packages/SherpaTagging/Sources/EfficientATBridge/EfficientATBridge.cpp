#include "EfficientATBridge.h"
#include <Accelerate/Accelerate.h>
#include <onnxruntime/onnxruntime_cxx_api.h>
#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <fstream>
#include <memory>
#include <stdexcept>
#include <string>
#include <vector>

namespace {
constexpr size_t kSamples = 320000;
constexpr size_t kPreemphasized = kSamples - 1;
constexpr size_t kFFT = 1024;
constexpr size_t kBins = kFFT / 2 + 1;
constexpr size_t kWindow = 800;
constexpr size_t kFrames = 1000;
constexpr size_t kMels = 128;
constexpr size_t kClasses = 527;
constexpr size_t kFeatures = kMels * kFrames;

size_t reflected(long index) {
    if (index < 0) return static_cast<size_t>(-index);
    if (index >= static_cast<long>(kPreemphasized))
        return static_cast<size_t>(2 * static_cast<long>(kPreemphasized) - index - 2);
    return static_cast<size_t>(index);
}

struct Runtime {
    Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "SoundTest.EfficientAT"};
    Ort::SessionOptions options;
    std::unique_ptr<Ort::Session> session;
    std::string inputName;
    std::string outputName;
    std::array<float, kBins * kMels> melBank{};
    std::array<float, kWindow> window{};
    std::array<size_t, kMels> firstBin{}, lastBin{};
    vDSP_DFT_Setup fft = nullptr;

    Runtime(const char *modelPath, const char *melBankPath, const char *hannPath, int threads) {
        if (!modelPath || !melBankPath || !hannPath || threads < 1 || threads > 8)
            throw std::runtime_error("Invalid EfficientAT model arguments");
        std::ifstream file(melBankPath, std::ios::binary | std::ios::ate);
        if (!file || file.tellg() != static_cast<std::streamoff>(sizeof(melBank)))
            throw std::runtime_error("EfficientAT Kaldi mel bank has invalid size");
        file.seekg(0);
        file.read(reinterpret_cast<char *>(melBank.data()), sizeof(melBank));
        if (!file) throw std::runtime_error("Cannot read EfficientAT Kaldi mel bank");
        for (size_t m = 0; m < kMels; ++m) {
            size_t first = kBins, last = 0;
            for (size_t bin = 0; bin < kBins; ++bin) {
                const float weight = melBank[m * kBins + bin];
                if (!std::isfinite(weight) || weight < 0)
                    throw std::runtime_error("Invalid EfficientAT mel weight");
                if (weight != 0) { first = std::min(first, bin); last = bin + 1; }
            }
            if (first == kBins) throw std::runtime_error("Empty EfficientAT mel filter");
            firstBin[m] = first; lastBin[m] = last;
        }
        std::ifstream windowFile(hannPath, std::ios::binary | std::ios::ate);
        if (!windowFile || windowFile.tellg() != static_cast<std::streamoff>(sizeof(window)))
            throw std::runtime_error("EfficientAT Hann window has invalid size");
        windowFile.seekg(0);
        windowFile.read(reinterpret_cast<char *>(window.data()), sizeof(window));
        if (!windowFile || !std::all_of(window.begin(), window.end(), [](float v) { return std::isfinite(v) && v >= 0 && v <= 1; }))
            throw std::runtime_error("Invalid EfficientAT Hann window");
        options.SetIntraOpNumThreads(threads);
        options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        session = std::make_unique<Ort::Session>(env, modelPath, options);
        if (session->GetInputCount() != 1 || session->GetOutputCount() != 1)
            throw std::runtime_error("Unexpected EfficientAT ONNX input/output count");
        Ort::AllocatorWithDefaultOptions allocator;
        inputName = session->GetInputNameAllocated(0, allocator).get();
        outputName = session->GetOutputNameAllocated(0, allocator).get();
        // Create this last: constructor failure before this point must not leak
        // an FFT setup (Runtime's destructor is not run for a failed constructor).
        fft = vDSP_DFT_zrop_CreateSetup(nullptr, kFFT, vDSP_DFT_FORWARD);
        if (!fft) throw std::runtime_error("Cannot initialize EfficientAT FFT");
    }
    ~Runtime() { if (fft) vDSP_DFT_DestroySetup(fft); }

    void extract(const float *samples, size_t count, float *features) const {
        if (!samples || !features || count != kSamples)
            throw std::runtime_error("EfficientAT requires exactly 320000 mono 32 kHz samples");
        std::vector<float> emphasized(kPreemphasized);
        for (size_t i = 0; i < kPreemphasized; ++i) {
            if (!std::isfinite(samples[i])) throw std::runtime_error("Non-finite audio sample");
            emphasized[i] = samples[i + 1] - 0.97f * samples[i];
        }
        if (!std::isfinite(samples[kSamples - 1])) throw std::runtime_error("Non-finite audio sample");
        std::array<float, kFFT / 2> even{}, odd{}, real{}, imag{};
        std::array<float, kBins> power{};
        for (size_t frame = 0; frame < kFrames; ++frame) {
            for (size_t k = 0; k < kFFT; ++k) {
                const long source = static_cast<long>(frame * 320 + k) - 512;
                const size_t n = reflected(source);
                const float value = (k >= 112 && k < 912) ? emphasized[n] * window[k - 112] : 0;
                if ((k & 1) == 0) even[k / 2] = value; else odd[k / 2] = value;
            }
            vDSP_DFT_Execute(fft, even.data(), odd.data(), real.data(), imag.data());
            power[0] = 0.25f * real[0] * real[0];
            for (size_t bin = 1; bin < kBins - 1; ++bin)
                power[bin] = 0.25f * (real[bin] * real[bin] + imag[bin] * imag[bin]);
            power[kBins - 1] = 0.25f * imag[0] * imag[0];
            for (size_t m = 0; m < kMels; ++m) {
                float value = 0;
                const float *weights = melBank.data() + m * kBins;
                for (size_t bin = firstBin[m]; bin < lastBin[m]; ++bin)
                    value += weights[bin] * power[bin];
                features[m * kFrames + frame] = (std::log(value + 1e-5f) + 4.5f) / 5.0f;
            }
        }
    }

    void run(const float *samples, size_t count, float *scores, size_t scoresCount) const {
        if (!scores || scoresCount != kClasses) throw std::runtime_error("Invalid EfficientAT scores buffer");
        std::vector<float> features(kFeatures);
        extract(samples, count, features.data());
        auto memory = Ort::MemoryInfo::CreateCpu(OrtArenaAllocator, OrtMemTypeDefault);
        const std::array<int64_t, 4> shape{1, 1, static_cast<int64_t>(kMels), static_cast<int64_t>(kFrames)};
        auto input = Ort::Value::CreateTensor<float>(memory, features.data(), features.size(), shape.data(), shape.size());
        const char *inputs[]{inputName.c_str()}, *outputs[]{outputName.c_str()};
        auto result = session->Run(Ort::RunOptions{nullptr}, inputs, &input, 1, outputs, 1);
        if (result.size() != 1 || result[0].GetTensorTypeAndShapeInfo().GetElementCount() != kClasses)
            throw std::runtime_error("Unexpected EfficientAT output shape");
        const float *probabilities = result[0].GetTensorData<float>();
        for (size_t i = 0; i < kClasses; ++i) {
            const float value = probabilities[i];
            if (!std::isfinite(value) || value < 0 || value > 1)
                throw std::runtime_error("Invalid EfficientAT probability");
            scores[i] = value;
        }
    }
};
}

extern "C" void *SoundEfficientATLoad(const char *modelPath, const char *melBankPath,
                                        const char *hannPath, int threads,
                                        char *error, size_t capacity) {
    try { return new Runtime(modelPath, melBankPath, hannPath, threads); }
    catch (const std::exception &e) { if (error && capacity) std::snprintf(error, capacity, "%s", e.what()); return nullptr; }
}
extern "C" int SoundEfficientATRun(void *handle, const float *samples, size_t count,
                                    float *scores, size_t scoresCount, char *error, size_t capacity) {
    try {
        if (!handle) throw std::runtime_error("EfficientAT is not loaded");
        static_cast<Runtime *>(handle)->run(samples, count, scores, scoresCount); return 1;
    } catch (const std::exception &e) { if (error && capacity) std::snprintf(error, capacity, "%s", e.what()); return 0; }
}
extern "C" int SoundEfficientATExtract(void *handle, const float *samples, size_t count,
                                        float *features, size_t featureCount, char *error, size_t capacity) {
    try {
        if (!handle || featureCount != kFeatures) throw std::runtime_error("Invalid EfficientAT feature buffer");
        static_cast<Runtime *>(handle)->extract(samples, count, features); return 1;
    } catch (const std::exception &e) { if (error && capacity) std::snprintf(error, capacity, "%s", e.what()); return 0; }
}
extern "C" void SoundEfficientATRelease(void *handle) { delete static_cast<Runtime *>(handle); }
