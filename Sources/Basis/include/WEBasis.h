// The engine's door into Binomial's Basis Universal transcoder: plain C, so Swift can call it without C++
// interop. Decodes a KTX2 file holding Basis Universal data (ETC1S or UASTC, Zstandard or not) to 8-bit
// RGBA — the same pixels a PNG decodes to, so the rest of the engine treats both alike.
#ifndef WEBASIS_H
#define WEBASIS_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/// Whether the bytes are a KTX2 file.
int we_basis_is_ktx2(const void *_Nonnull data, size_t length);

/// Decodes the first image's largest level to RGBA8, top row first, into a buffer the caller frees
/// with `we_basis_free`. NULL when the file is not KTX2 with Basis Universal data, or is damaged.
uint8_t *_Nullable we_basis_decode(const void *_Nonnull data, size_t length, uint32_t *_Nonnull width,
                                   uint32_t *_Nonnull height);
void we_basis_free(uint8_t *_Nullable pixels);

#ifdef __cplusplus
}
#endif

#endif
