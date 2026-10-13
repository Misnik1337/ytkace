// Compares the native VOT protobuf codec with vectors produced by FOSWLY/vot.js
// (Tests/data/vot_vectors.txt). Built and run by test_vot_proto.py.
#define _POSIX_C_SOURCE 200809L
#include "../Tweak/Features/Translation/VOTProto.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static char *vectors[16][2];
static int vectorCount;
static int failures;

static void loadVectors(const char *path) {
    FILE *file = fopen(path, "r");
    if (file == NULL) {
        fprintf(stderr, "cannot open %s\n", path);
        exit(2);
    }
    char name[64];
    static char value[4096];
    while (vectorCount < 16 && fscanf(file, "%63s %4095s", name, value) == 2) {
        vectors[vectorCount][0] = strdup(name);
        vectors[vectorCount][1] = strdup(value);
        vectorCount++;
    }
    fclose(file);
}

static const char *vector(const char *name) {
    for (int index = 0; index < vectorCount; index++) {
        if (strcmp(vectors[index][0], name) == 0) return vectors[index][1];
    }
    fprintf(stderr, "missing vector %s\n", name);
    exit(2);
}

static size_t decodeHex(const char *hex, uint8_t *out) {
    size_t length = strlen(hex) / 2;
    for (size_t index = 0; index < length; index++) {
        unsigned int byte;
        sscanf(hex + index * 2, "%2x", &byte);
        out[index] = (uint8_t)byte;
    }
    return length;
}

static void expectBytes(const char *name, VOTBuffer *buffer) {
    static uint8_t expected[2048];
    size_t length = decodeHex(vector(name), expected);
    if (buffer->length != length || memcmp(buffer->data, expected, length) != 0) {
        fprintf(stderr, "FAIL %s: encoded %zu bytes, expected %zu\n",
                name, buffer->length, length);
        failures++;
    }
    VOTBufferFree(buffer);
}

static void expect(int condition, const char *message) {
    if (!condition) {
        fprintf(stderr, "FAIL %s\n", message);
        failures++;
    }
}

int main(int argc, char **argv) {
    if (argc < 2) return 2;
    loadVectors(argv[1]);
    const char *url = "https://youtu.be/aircAruvnKk";
    const uint8_t audio[] = {0, 1, 2, 250, 255, 7, 0};

    VOTBuffer buffer = {0};
    VOTEncodeSessionRequest(&buffer, "0123456789ABCDEF0123456789ABCDEF", "video-translation");
    expectBytes("session", &buffer);

    VOTEncodeTranslationRequest(&buffer, url, 1153.25, "auto", "ru", 0, NULL);
    expectBytes("translate", &buffer);

    // Non-ASCII title and message check UTF-8 strings pass through unchanged.
    VOTEncodeTranslationRequest(&buffer, url, 1153.25, "en", "ru", 1,
                                "But what is a neural network? | Глава 1");
    expectBytes("translateLively", &buffer);

    VOTEncodeAudioChunkRequest(&buffer, url, "476682088", audio, sizeof audio,
                               0, 0, "random-web_mse_proxy-x", 1);
    expectBytes("chunk0", &buffer);

    VOTEncodeAudioChunkRequest(&buffer, url, "476682088", audio, sizeof audio,
                               3, 4, "random-web_mse_proxy-x", 1);
    expectBytes("chunkLast", &buffer);

    VOTEncodeAudioFileRequest(&buffer, url, "476682088", NULL, 0,
                              "fallback-empty-audio:video-translation:aircAruvnKk");
    expectBytes("failAudio", &buffer);

    static uint8_t bytes[2048];
    size_t length = decodeHex(vector("translateResponse"), bytes);
    VOTTranslationResponse response;
    expect(VOTDecodeTranslationResponse(bytes, length, &response), "decode translation");
    expect(response.status == 1, "translation status");
    expect(response.hasRemainingTime && response.remainingTime == 42, "remaining time");
    expect(response.duration == 1153.5, "duration");
    expect(response.shouldRetry == 1, "shouldRetry");
    expect(response.url && strcmp(response.url, "https://vtrans.s3.example/x.mp3") == 0, "url");
    expect(response.translationID && strcmp(response.translationID, "476682088") == 0, "id");
    expect(response.message && strcmp(response.message, "Перевод готов") == 0, "message");
    expect(response.language && strcmp(response.language, "en") == 0, "language");
    expect(!response.isLivelyVoice, "standard voice flag");
    VOTTranslationResponseFree(&response);

    size_t livelyLength = decodeHex(vector("translateResponseLively"), bytes);
    expect(VOTDecodeTranslationResponse(bytes, livelyLength, &response), "decode lively");
    expect(response.isLivelyVoice, "live voice flag");
    VOTTranslationResponseFree(&response);
    length = decodeHex(vector("translateResponse"), bytes);

    expect(!VOTDecodeTranslationResponse(bytes, length - 3, &response), "truncated response rejected");

    length = decodeHex(vector("sessionResponse"), bytes);
    VOTSessionResponse session;
    expect(VOTDecodeSessionResponse(bytes, length, &session), "decode session");
    expect(session.expires == 36000, "session expires");
    expect(session.secretKey && strcmp(session.secretKey, "secret-key-value") == 0, "secret");
    VOTSessionResponseFree(&session);

    length = decodeHex(vector("audioResponse"), bytes);
    int32_t status = 0;
    expect(VOTDecodeAudioResponse(bytes, length, &status) && status == 2, "audio status");

    if (failures == 0) printf("ok\n");
    return failures == 0 ? 0 : 1;
}
