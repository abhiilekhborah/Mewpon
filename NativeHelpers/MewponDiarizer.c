// Fixed offline C API adapter. No shell, network, microphone or arbitrary code.
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
#include <sys/stat.h>
#include "sherpa-onnx/c-api/c-api.h"

int main(int argc, char **argv) {
    if (argc != 6) return 2;
    char *end = NULL;
    long known = strtol(argv[5], &end, 10);
    if (!end || *end || known < 0 || known > 12) return 2;
    struct stat info;
    if (stat(argv[1], &info) || info.st_size > 230500000) return 3;
    const SherpaOnnxWave *wave = SherpaOnnxReadWave(argv[1]);
    if (!wave || wave->sample_rate != 16000 || wave->num_samples <= 0 || wave->num_samples > 115200000) {
        if (wave) SherpaOnnxFreeWave(wave);
        return 3;
    }
    SherpaOnnxOfflineSpeakerDiarizationConfig config;
    memset(&config, 0, sizeof(config));
    config.segmentation.pyannote.model = argv[2];
    config.segmentation.num_threads = 2;
    config.segmentation.provider = "cpu";
    config.embedding.model = argv[3];
    config.embedding.num_threads = 2;
    config.embedding.provider = "cpu";
    config.clustering.num_clusters = known > 0 ? (int)known : -1;
    config.clustering.threshold = 0.9f;
    config.clustering.compute_confidence = 1;
    config.min_duration_on = 0.3f;
    config.min_duration_off = 0.5f;
    const SherpaOnnxOfflineSpeakerDiarization *engine = SherpaOnnxCreateOfflineSpeakerDiarization(&config);
    if (!engine) { SherpaOnnxFreeWave(wave); return 4; }
    const SherpaOnnxOfflineSpeakerDiarizationResult *result = SherpaOnnxOfflineSpeakerDiarizationProcess(engine, wave->samples, wave->num_samples);
    if (!result) { SherpaOnnxDestroyOfflineSpeakerDiarization(engine); SherpaOnnxFreeWave(wave); return 5; }
    int count = SherpaOnnxOfflineSpeakerDiarizationResultGetNumSegments(result);
    const SherpaOnnxOfflineSpeakerDiarizationSegment *segments = SherpaOnnxOfflineSpeakerDiarizationResultSortByStartTime(result);
    int status = 0;
    FILE *output = NULL;
    if (count < 0 || count > 50000 || (count && !segments) || !(output = fopen(argv[4], "wx"))) status = 6;
    if (output) {
        chmod(argv[4], 0600);
        fputs("{\"turns\":[", output);
        for (int i=0; i<count; ++i) {
            const SherpaOnnxOfflineSpeakerDiarizationSegment s=segments[i];
            float confidence = isfinite(s.confidence) && s.confidence>=-1 && s.confidence<=1 ? s.confidence:-2;
            if (!isfinite(s.start) || !isfinite(s.end) || s.start<0 || s.end<s.start || s.speaker<0 || s.speaker>1000) {status=7;break;}
            fprintf(output,"%s{\"start\":%.6f,\"end\":%.6f,\"speaker\":%d,\"confidence\":%.6f}",i ? ",":"",s.start,s.end,s.speaker,confidence);
        }
        fputs("]}",output);
        if (fclose(output)) status=8;
    }
    if (segments) SherpaOnnxOfflineSpeakerDiarizationDestroySegment(segments);
    SherpaOnnxOfflineSpeakerDiarizationDestroyResult(result);
    SherpaOnnxDestroyOfflineSpeakerDiarization(engine);
    SherpaOnnxFreeWave(wave);
    if (status && output) remove(argv[4]);
    return status;
}
