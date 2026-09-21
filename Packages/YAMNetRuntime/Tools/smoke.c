/* Local simulator smoke probe for the bundled official YAMNet model.
 * This synthetic silence check validates linkage and model execution, not accuracy.
 */
#include <TensorFlowLiteC/TensorFlowLiteC.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    TfLiteModel *model = TfLiteModelCreateFromFile(argv[1]);
    if (!model) return 3;
    TfLiteInterpreterOptions *options = TfLiteInterpreterOptionsCreate();
    TfLiteInterpreterOptionsSetNumThreads(options, 2);
    TfLiteInterpreter *interpreter = TfLiteInterpreterCreate(model, options);
    TfLiteInterpreterOptionsDelete(options);
    if (!interpreter || TfLiteInterpreterAllocateTensors(interpreter) != kTfLiteOk) return 4;
    float samples[15600] = {0};
    if (argc > 2) {
        FILE *audio = fopen(argv[2], "rb");
        if (!audio || fread(samples, sizeof(float), 15600, audio) != 15600) return 9;
        fclose(audio);
    }
    float scores[521];
    TfLiteTensor *input = TfLiteInterpreterGetInputTensor(interpreter, 0);
    if (!input || TfLiteTensorCopyFromBuffer(input, samples, sizeof(samples)) != kTfLiteOk) return 5;
    if (TfLiteInterpreterInvoke(interpreter) != kTfLiteOk) return 6;
    const TfLiteTensor *output = TfLiteInterpreterGetOutputTensor(interpreter, 0);
    if (!output || TfLiteTensorByteSize(output) != sizeof(scores) ||
        TfLiteTensorCopyToBuffer(output, scores, sizeof(scores)) != kTfLiteOk) return 7;
    int top = 0;
    for (int i = 0; i < 521; ++i) {
        if (!isfinite(scores[i]) || scores[i] < 0 || scores[i] > 1) return 8;
        if (scores[i] > scores[top]) top = i;
    }
    printf("TFLite=%s input=15600 output=521 top_index=%d top_score=%.8f\n", TfLiteVersion(), top, scores[top]);
    TfLiteInterpreterDelete(interpreter);
    TfLiteModelDelete(model);
    return 0;
}
