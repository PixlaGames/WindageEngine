// See include/WEBasis.h. The only code here that is the engine's own; everything under src/ is Binomial's Basis
// Universal 2.50 transcoder and Meta's Zstandard decoder, unmodified — Apache 2.0 (LICENSE, NOTICE) and
// BSD (LICENSES/Zstandard-BSD.txt).
#include "WEBasis.h"

#include <cstdlib>
#include <cstring>
#include <mutex>

#include "transcoder/basisu_transcoder.h"

static void initialise() {
    static std::once_flag once;
    std::call_once(once, [] { basist::basisu_transcoder_init(); });
}

int we_basis_is_ktx2(const void *data, size_t length) {
    static const uint8_t magic[12] = {0xAB, 'K', 'T', 'X', ' ', '2', '0', 0xBB, '\r', '\n', 0x1A, '\n'};
    return length >= 12 && std::memcmp(data, magic, 12) == 0;
}

uint8_t *we_basis_decode(const void *data, size_t length, uint32_t *width, uint32_t *height) {
    if (!we_basis_is_ktx2(data, length) || length > UINT32_MAX) return nullptr;
    initialise();
    basist::ktx2_transcoder transcoder;
    if (!transcoder.init(data, static_cast<uint32_t>(length)) || !transcoder.start_transcoding()) return nullptr;
    const uint32_t w = transcoder.get_width(), h = transcoder.get_height();
    if (w == 0 || h == 0) return nullptr;
    auto *pixels = static_cast<uint8_t *>(std::malloc(size_t(w) * h * 4));
    if (!pixels) return nullptr;
    if (!transcoder.transcode_image_level(0, 0, 0, pixels, w * h, basist::transcoder_texture_format::cTFRGBA32)) {
        std::free(pixels);
        return nullptr;
    }
    *width = w;
    *height = h;
    return pixels;
}

void we_basis_free(uint8_t *pixels) { std::free(pixels); }
