// Xclip's bounded, raw-RGBA streaming adapter to the official libwebp animation encoder.
#include <errno.h>
#include <fcntl.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/resource.h>
#include <unistd.h>
#include "webp/encode.h"
#include "webp/mux.h"

static int number(const char *text) {
    char *end = NULL;
    long value = strtol(text, &end, 10);
    return end != text && *end == 0 && value > 0 && value <= 1800000 ? (int)value : 0;
}
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        int version = WebPGetEncoderVersion();
        printf("Xclip WebP adapter 1; libwebp %d.%d.%d\n", version >> 16, (version >> 8) & 255, version & 255);
        return 0;
    }
    if (argc != 7) { fprintf(stderr, "Usage: XclipWebP width height fps frame-count duration-ms output.webp\n"); return 2; }
    int width = number(argv[1]), height = number(argv[2]), fps = number(argv[3]);
    int count = number(argv[4]), duration = number(argv[5]), success = 0, output = -1;
    if (!width || width > 960 || !height || height > 960 || !fps || fps > 30 || !count || count > 1800 || !duration || duration <= (count - 1) * 1000 / fps) {
        fprintf(stderr, "Invalid animation dimensions or timing.\n"); return 2;
    }
    const size_t size = (size_t)width * height * 4;
    unsigned char *rgba = malloc(size);
    WebPAnimEncoderOptions options;
    WebPConfig config;
    WebPData data;
    WebPDataInit(&data);
    WebPAnimEncoder *encoder = NULL;
    if (!rgba || !WebPAnimEncoderOptionsInit(&options) || !WebPConfigInit(&config)) goto cleanup;
    options.anim_params.loop_count = 0;
    config.quality = 85; config.method = 3;
    encoder = WebPAnimEncoderNew(width, height, &options);
    if (!encoder) goto cleanup;
    for (int index = 0; index < count; ++index) {
        struct rusage usage;
        if (getrusage(RUSAGE_SELF, &usage) == 0 && usage.ru_maxrss > 512L * 1024 * 1024) {
            fprintf(stderr, "Animation exceeded its memory limit. Use a shorter clip or lower FPS.\n"); goto cleanup;
        }
        if (fread(rgba, 1, size, stdin) != size) { fprintf(stderr, "Incomplete animation frame.\n"); goto cleanup; }
        WebPPicture picture;
        if (!WebPPictureInit(&picture)) goto cleanup;
        picture.width = width; picture.height = height; picture.use_argb = 1;
        int valid = WebPPictureImportRGBA(&picture, rgba, width * 4) &&
            WebPAnimEncoderAdd(encoder, &picture, (int)llround(index * 1000.0 / fps), &config);
        WebPPictureFree(&picture);
        if (!valid) goto cleanup;
    }
    if (!WebPAnimEncoderAdd(encoder, NULL, duration, NULL) || !WebPAnimEncoderAssemble(encoder, &data)) goto cleanup;
    if (data.size > 256 * 1024 * 1024) { fprintf(stderr, "Animation file exceeded its size limit.\n"); goto cleanup; }
    output = open(argv[6], O_WRONLY | O_CREAT | O_EXCL, 0600);
    if (output < 0) { fprintf(stderr, "Cannot create output: %s\n", strerror(errno)); goto cleanup; }
    size_t offset = 0;
    while (offset < data.size) {
        ssize_t written = write(output, data.bytes + offset, data.size - offset);
        if (written < 0 && errno == EINTR) continue;
        if (written <= 0) goto cleanup;
        offset += (size_t)written;
    }
    success = 1;
cleanup:
    if (!success && encoder) fprintf(stderr, "WebP export failed: %s\n", WebPAnimEncoderGetError(encoder));
    if (output >= 0) { close(output); if (!success) unlink(argv[6]); }
    WebPDataClear(&data); WebPAnimEncoderDelete(encoder); free(rgba);
    return success ? 0 : 1;
}
