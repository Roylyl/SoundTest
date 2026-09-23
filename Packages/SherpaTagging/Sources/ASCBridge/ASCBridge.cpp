#include "ASCBridge.h"
#include <onnxruntime/onnxruntime_cxx_api.h>
#include <algorithm>
#include <cstdio>
#include <memory>
#include <stdexcept>
struct Runtime {
    Ort::Env env{ORT_LOGGING_LEVEL_WARNING, "SoundTest.ASC"};
    Ort::SessionOptions options;
    std::unique_ptr<Ort::Session> session;
    Runtime(const char *path, int threads) {
        options.SetIntraOpNumThreads(threads);
        options.SetGraphOptimizationLevel(GraphOptimizationLevel::ORT_ENABLE_ALL);
        session = std::make_unique<Ort::Session>(env,path,options);
    }
};
extern "C" void *SoundASCLoad(const char *path,int threads,char *error,size_t capacity) {
    try { return new Runtime(path,threads); }
    catch(const std::exception &e) { snprintf(error,capacity,"%s",e.what()); return nullptr; }
}
extern "C" int SoundASCRun(void *handle,const float *samples,size_t count,float *logits,char *error,size_t capacity) {
    try {
        if (!handle || count!=32000) throw std::runtime_error("CP-Mobile requires exactly 32000 mono samples");
        auto memory=Ort::MemoryInfo::CreateCpu(OrtArenaAllocator,OrtMemTypeDefault);
        int64_t shape[]={1,32000};
        auto input=Ort::Value::CreateTensor<float>(memory,const_cast<float*>(samples),count,shape,2);
        const char *inNames[]={"waveform"}; const char *outNames[]={"logits"};
        auto output=static_cast<Runtime*>(handle)->session->Run(Ort::RunOptions{nullptr},inNames,&input,1,outNames,1);
        if (output[0].GetTensorTypeAndShapeInfo().GetElementCount()!=10) throw std::runtime_error("Invalid ASC output shape");
        std::copy_n(output[0].GetTensorData<float>(),10,logits); return 1;
    } catch(const std::exception &e) { snprintf(error,capacity,"%s",e.what()); return 0; }
}
extern "C" void SoundASCRelease(void *handle) { delete static_cast<Runtime*>(handle); }
