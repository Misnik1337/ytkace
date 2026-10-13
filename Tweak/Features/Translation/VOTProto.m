// Plain C (no Objective-C) so the codec builds and tests with a host compiler.
#include "VOTProto.h"

#include <stdlib.h>
#include <string.h>

enum {
    VOTWireVarint = 0,
    VOTWireFixed64 = 1,
    VOTWireBytes = 2,
    VOTWireFixed32 = 5,
};

void VOTBufferFree(VOTBuffer *buffer) {
    if (buffer == NULL) return;
    free(buffer->data);
    buffer->data = NULL;
    buffer->length = 0;
    buffer->capacity = 0;
}

static void VOTReserve(VOTBuffer *buffer, size_t extra) {
    if (buffer->failed) return;
    if (buffer->length + extra <= buffer->capacity) return;
    size_t capacity = buffer->capacity == 0 ? 64 : buffer->capacity;
    while (capacity < buffer->length + extra) capacity *= 2;
    uint8_t *data = realloc(buffer->data, capacity);
    if (data == NULL) {
        buffer->failed = 1;
        return;
    }
    buffer->data = data;
    buffer->capacity = capacity;
}

static void VOTAppend(VOTBuffer *buffer, const void *bytes, size_t length) {
    if (length == 0) return;
    VOTReserve(buffer, length);
    if (buffer->failed) return;
    memcpy(buffer->data + buffer->length, bytes, length);
    buffer->length += length;
}

static void VOTWriteVarint(VOTBuffer *buffer, uint64_t value) {
    uint8_t bytes[10];
    size_t count = 0;
    do {
        uint8_t byte = value & 0x7F;
        value >>= 7;
        if (value != 0) byte |= 0x80;
        bytes[count++] = byte;
    } while (value != 0);
    VOTAppend(buffer, bytes, count);
}

static void VOTWriteTag(VOTBuffer *buffer, uint32_t field, uint32_t wire) {
    VOTWriteVarint(buffer, ((uint64_t)field << 3) | wire);
}

static void VOTWriteBytes(VOTBuffer *buffer, uint32_t field,
                          const void *bytes, size_t length) {
    VOTWriteTag(buffer, field, VOTWireBytes);
    VOTWriteVarint(buffer, length);
    VOTAppend(buffer, bytes, length);
}

// proto3 semantics: empty strings, false and zero are not written.
static void VOTWriteString(VOTBuffer *buffer, uint32_t field, const char *value) {
    if (value == NULL || value[0] == '\0') return;
    VOTWriteBytes(buffer, field, value, strlen(value));
}

static void VOTWriteBool(VOTBuffer *buffer, uint32_t field, int value) {
    if (!value) return;
    VOTWriteTag(buffer, field, VOTWireVarint);
    VOTWriteVarint(buffer, 1);
}

static void VOTWriteInt32(VOTBuffer *buffer, uint32_t field, int32_t value) {
    if (value == 0) return;
    VOTWriteTag(buffer, field, VOTWireVarint);
    // Negative int32 values are sign-extended to 64 bits on the wire.
    VOTWriteVarint(buffer, (uint64_t)(int64_t)value);
}

static void VOTWriteDouble(VOTBuffer *buffer, uint32_t field, double value) {
    if (value == 0.0) return;
    uint64_t bits;
    memcpy(&bits, &value, sizeof bits);
    uint8_t bytes[8];
    for (int index = 0; index < 8; index++) {
        bytes[index] = (uint8_t)(bits >> (8 * index));
    }
    VOTWriteTag(buffer, field, VOTWireFixed64);
    VOTAppend(buffer, bytes, sizeof bytes);
}

static void VOTWriteMessage(VOTBuffer *buffer, uint32_t field, const VOTBuffer *message) {
    if (message->failed) {
        buffer->failed = 1;
        return;
    }
    VOTWriteBytes(buffer, field, message->data, message->length);
}

static int VOTFinish(VOTBuffer *out) {
    if (out->failed) {
        VOTBufferFree(out);
        return 0;
    }
    return 1;
}

int VOTEncodeSessionRequest(VOTBuffer *out, const char *uuid, const char *module) {
    VOTWriteString(out, 1, uuid);
    VOTWriteString(out, 2, module);
    return VOTFinish(out);
}

int VOTEncodeTranslationRequest(VOTBuffer *out,
                                const char *url,
                                double duration,
                                const char *requestLanguage,
                                const char *responseLanguage,
                                int useLivelyVoice,
                                const char *videoTitle) {
    VOTWriteString(out, 3, url);
    VOTWriteBool(out, 5, 1);            // firstRequest
    VOTWriteDouble(out, 6, duration);
    VOTWriteBool(out, 7, 1);            // unknown0
    VOTWriteString(out, 8, requestLanguage);
    VOTWriteString(out, 14, responseLanguage);
    VOTWriteBool(out, 15, 1);           // unknown2
    VOTWriteInt32(out, 16, 2);          // configVersion
    VOTWriteBool(out, 18, useLivelyVoice);
    VOTWriteString(out, 19, videoTitle);
    return VOTFinish(out);
}

int VOTEncodeAudioChunkRequest(VOTBuffer *out,
                               const char *url,
                               const char *translationID,
                               const uint8_t *audio,
                               size_t audioLength,
                               int32_t chunkID,
                               int32_t partsLength,
                               const char *fileID,
                               int32_t version) {
    VOTBuffer audioBuffer = {0};
    if (audioLength != 0) VOTWriteBytes(&audioBuffer, 2, audio, audioLength);
    VOTWriteInt32(&audioBuffer, 1, chunkID);

    VOTBuffer chunk = {0};
    VOTWriteMessage(&chunk, 1, &audioBuffer);
    VOTWriteInt32(&chunk, 2, partsLength);
    VOTWriteString(&chunk, 3, fileID);
    VOTWriteInt32(&chunk, 4, version);

    VOTWriteString(out, 1, translationID);
    VOTWriteString(out, 2, url);
    VOTWriteMessage(out, 4, &chunk);
    VOTBufferFree(&audioBuffer);
    VOTBufferFree(&chunk);
    return VOTFinish(out);
}

int VOTEncodeAudioFileRequest(VOTBuffer *out,
                              const char *url,
                              const char *translationID,
                              const uint8_t *audio,
                              size_t audioLength,
                              const char *fileID) {
    VOTBuffer file = {0};
    if (audioLength != 0) VOTWriteBytes(&file, 2, audio, audioLength);
    VOTWriteString(&file, 1, fileID);

    VOTWriteString(out, 1, translationID);
    VOTWriteString(out, 2, url);
    VOTWriteMessage(out, 6, &file);
    VOTBufferFree(&file);
    return VOTFinish(out);
}

typedef struct {
    const uint8_t *cursor;
    const uint8_t *end;
} VOTReader;

static int VOTReadVarint(VOTReader *reader, uint64_t *value) {
    uint64_t result = 0;
    for (int shift = 0; shift < 64; shift += 7) {
        if (reader->cursor >= reader->end) return 0;
        uint8_t byte = *reader->cursor++;
        result |= (uint64_t)(byte & 0x7F) << shift;
        if ((byte & 0x80) == 0) {
            *value = result;
            return 1;
        }
    }
    return 0;
}

typedef struct {
    uint32_t field;
    uint32_t wire;
    uint64_t varint;
    const uint8_t *bytes;
    size_t length;
} VOTField;

static int VOTReadField(VOTReader *reader, VOTField *field) {
    uint64_t key;
    if (!VOTReadVarint(reader, &key)) return 0;
    field->field = (uint32_t)(key >> 3);
    field->wire = (uint32_t)(key & 7);
    field->bytes = NULL;
    field->length = 0;
    field->varint = 0;
    switch (field->wire) {
        case VOTWireVarint:
            return VOTReadVarint(reader, &field->varint);
        case VOTWireFixed64:
        case VOTWireFixed32: {
            size_t size = field->wire == VOTWireFixed64 ? 8 : 4;
            if ((size_t)(reader->end - reader->cursor) < size) return 0;
            field->bytes = reader->cursor;
            field->length = size;
            reader->cursor += size;
            return 1;
        }
        case VOTWireBytes: {
            uint64_t length;
            if (!VOTReadVarint(reader, &length)) return 0;
            if (length > (uint64_t)(reader->end - reader->cursor)) return 0;
            field->bytes = reader->cursor;
            field->length = (size_t)length;
            reader->cursor += length;
            return 1;
        }
        default:
            return 0;
    }
}

static char *VOTCopyString(const VOTField *field) {
    if (field->wire != VOTWireBytes) return NULL;
    char *copy = malloc(field->length + 1);
    if (copy == NULL) return NULL;
    if (field->length != 0) memcpy(copy, field->bytes, field->length);
    copy[field->length] = '\0';
    return copy;
}

static void VOTReplaceString(char **slot, const VOTField *field) {
    free(*slot);
    *slot = VOTCopyString(field);
}

static double VOTFieldDouble(const VOTField *field) {
    if (field->wire != VOTWireFixed64) return 0.0;
    uint64_t bits = 0;
    for (int index = 0; index < 8; index++) {
        bits |= (uint64_t)field->bytes[index] << (8 * index);
    }
    double value;
    memcpy(&value, &bits, sizeof value);
    return value;
}

void VOTTranslationResponseFree(VOTTranslationResponse *response) {
    if (response == NULL) return;
    free(response->url);
    free(response->translationID);
    free(response->language);
    free(response->message);
    memset(response, 0, sizeof *response);
}

int VOTDecodeTranslationResponse(const uint8_t *data, size_t length,
                                 VOTTranslationResponse *out) {
    memset(out, 0, sizeof *out);
    VOTReader reader = {data, data + length};
    VOTField field;
    while (reader.cursor < reader.end) {
        if (!VOTReadField(&reader, &field)) {
            VOTTranslationResponseFree(out);
            return 0;
        }
        switch (field.field) {
            case 1: VOTReplaceString(&out->url, &field); break;
            case 2: out->duration = VOTFieldDouble(&field); break;
            case 4: out->status = (int32_t)field.varint; break;
            case 5:
                out->remainingTime = (int32_t)field.varint;
                out->hasRemainingTime = 1;
                break;
            case 7: VOTReplaceString(&out->translationID, &field); break;
            case 8: VOTReplaceString(&out->language, &field); break;
            case 9: VOTReplaceString(&out->message, &field); break;
            case 10: out->isLivelyVoice = field.varint != 0; break;
            case 12: out->shouldRetry = (int32_t)field.varint; break;
            default: break;
        }
    }
    return 1;
}

void VOTSessionResponseFree(VOTSessionResponse *response) {
    if (response == NULL) return;
    free(response->secretKey);
    memset(response, 0, sizeof *response);
}

int VOTDecodeSessionResponse(const uint8_t *data, size_t length,
                             VOTSessionResponse *out) {
    memset(out, 0, sizeof *out);
    VOTReader reader = {data, data + length};
    VOTField field;
    while (reader.cursor < reader.end) {
        if (!VOTReadField(&reader, &field)) {
            VOTSessionResponseFree(out);
            return 0;
        }
        if (field.field == 1) VOTReplaceString(&out->secretKey, &field);
        if (field.field == 2) out->expires = (int32_t)field.varint;
    }
    return out->secretKey != NULL;
}

int VOTDecodeAudioResponse(const uint8_t *data, size_t length, int32_t *status) {
    *status = 0;
    VOTReader reader = {data, data + length};
    VOTField field;
    while (reader.cursor < reader.end) {
        if (!VOTReadField(&reader, &field)) return 0;
        if (field.field == 1) *status = (int32_t)field.varint;
    }
    return 1;
}
