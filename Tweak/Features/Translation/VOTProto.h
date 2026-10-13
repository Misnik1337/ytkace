// Minimal protobuf codec for the Yandex video translation (VOT) API.
// Plain C so it can be unit-tested off-device against FOSWLY/vot.js output.
// Field numbers mirror vot.js packages/shared/src/protos/yandex.proto.
#ifndef YTKACE_VOT_PROTO_H
#define YTKACE_VOT_PROTO_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    uint8_t *data;
    size_t length;
    size_t capacity;
    int failed;
} VOTBuffer;

void VOTBufferFree(VOTBuffer *buffer);

// YandexSessionRequest { uuid = 1; module = 2; }
int VOTEncodeSessionRequest(VOTBuffer *out, const char *uuid, const char *module);

// VideoTranslationRequest with the constants vot.js sends for a first request.
// useLivelyVoice asks for Yandex "live voices"; videoTitle may be NULL.
int VOTEncodeTranslationRequest(VOTBuffer *out,
                                const char *url,
                                double duration,
                                const char *requestLanguage,
                                const char *responseLanguage,
                                int useLivelyVoice,
                                const char *videoTitle);

// VideoTranslationAudioRequest carrying one ChunkAudioObject.
// partsLength is 0 for every chunk except the last, which carries the total.
int VOTEncodeAudioChunkRequest(VOTBuffer *out,
                               const char *url,
                               const char *translationID,
                               const uint8_t *audio,
                               size_t audioLength,
                               int32_t chunkID,
                               int32_t partsLength,
                               const char *fileID,
                               int32_t version);

// VideoTranslationAudioRequest carrying a whole AudioBufferObject
// (used with an empty buffer for the fail-audio fallback).
int VOTEncodeAudioFileRequest(VOTBuffer *out,
                              const char *url,
                              const char *translationID,
                              const uint8_t *audio,
                              size_t audioLength,
                              const char *fileID);

typedef struct {
    char *url;
    double duration;
    int32_t status;
    int32_t remainingTime;
    int hasRemainingTime;
    char *translationID;
    char *language;
    char *message;
    int32_t shouldRetry;
    int isLivelyVoice;
} VOTTranslationResponse;

int VOTDecodeTranslationResponse(const uint8_t *data, size_t length,
                                 VOTTranslationResponse *out);
void VOTTranslationResponseFree(VOTTranslationResponse *response);

typedef struct {
    char *secretKey;
    int32_t expires;
} VOTSessionResponse;

int VOTDecodeSessionResponse(const uint8_t *data, size_t length,
                             VOTSessionResponse *out);
void VOTSessionResponseFree(VOTSessionResponse *response);

// VideoTranslationAudioResponse { status = 1; repeated remainingChunks = 2; }
int VOTDecodeAudioResponse(const uint8_t *data, size_t length, int32_t *status);

#ifdef __cplusplus
}
#endif

#endif
