#ifndef DECKLINK_SHIM_H
#define DECKLINK_SHIM_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
    char name[256];
    int64_t persistentID;
    bool supportsPlayback;
    bool supportsInternalKeying;
    bool supportsExternalKeying;
} DLKDeviceInfo;

bool dlk_runtime_available(void);

int64_t dlk_api_version(void);

int32_t dlk_copy_devices(DLKDeviceInfo *out, int32_t capacity);

typedef struct {

    char name[64];

    uint32_t modeID;
    int32_t width;
    int32_t height;

    int64_t frameDuration;
    int64_t timeScale;
    bool progressive;

    bool supportsKeying;
} DLKDisplayModeInfo;

int32_t dlk_copy_display_modes(
    int64_t persistentID, DLKDisplayModeInfo *out, int32_t capacity);

uint32_t dlk_configured_output_mode(int64_t persistentID);

bool dlk_reference_locked(int64_t persistentID);

uint32_t dlk_output_link_configuration(int64_t persistentID);

typedef struct DLKOutput DLKOutput;

typedef enum {
    DLKKeyingOff = 0,
    DLKKeyingInternal = 1,
    DLKKeyingExternal = 2,
} DLKKeying;

DLKOutput *dlk_output_open(
    int64_t persistentID, uint32_t modeID,
    DLKKeying keying, char *error, size_t errorLength);

bool dlk_output_display(
    DLKOutput *output, const uint8_t *bgra, size_t bytesPerRow);

void dlk_output_close(DLKOutput *output);

// MARK: Capture

typedef struct {
    char name[256];
    int64_t persistentID;
    // The hardware can capture (BMDDeckLinkVideoIOSupport has bmdDeviceSupportsCapture).
    bool supportsCapture;
    bool supportsFormatDetection;
    // Sub-device switched off by the card's profile (BMDDeckLinkDuplex is inactive).
    bool inactive;
    // Capture modes the input offers right now; 0 when the connector is mapped as an
    // output in Desktop Video Setup.
    int32_t inputModeCount;
    bool captureBusy;
    bool playbackBusy;
} DLKInputDeviceInfo;

int32_t dlk_copy_input_devices(DLKInputDeviceInfo *out, int32_t capacity);

typedef struct DLKInput DLKInput;

typedef struct {
    // Valid only for the duration of the callback.
    const uint8_t *bytes;
    size_t rowBytes;
    int32_t width;
    int32_t height;
    // BMDPixelFormat fourcc: '2vuy' (bmdFormat8BitYUV) or 'BGRA' (bmdFormat8BitBGRA).
    uint32_t pixelFormat;
    // BMDColorspace fourcc: 'r601', 'r709' or '2020'.
    uint32_t colorspace;
    int64_t streamTime;
    int64_t frameDuration;
    int64_t timeScale;
} DLKInputFrame;

// Called on a DeckLink driver thread for every frame that carries a picture.
typedef void (*DLKInputFrameCallback)(void *context, const DLKInputFrame *frame);

typedef enum {
    DLKInputSignalNone = 0,
    DLKInputSignalLocked = 1,
    DLKInputSignalFailed = 2,
} DLKInputSignal;

typedef struct {
    DLKInputSignal signal;
    uint32_t modeID;
    int32_t width;
    int32_t height;
    int64_t frameDuration;
    int64_t timeScale;
    // BMDFieldDominance fourcc ('prog', 'psf ', 'lowr', 'uppr').
    uint32_t fieldDominance;
    uint32_t pixelFormat;
    uint32_t colorspace;
    uint64_t framesReceived;
    char error[160];
} DLKInputStatus;

DLKInput *dlk_input_open(
    int64_t persistentID, DLKInputFrameCallback callback, void *context,
    char *error, size_t errorLength);

void dlk_input_copy_status(DLKInput *input, DLKInputStatus *out);

// Stops capture; no callback runs after this returns.
void dlk_input_close(DLKInput *input);

#ifdef __cplusplus
}
#endif

#endif
