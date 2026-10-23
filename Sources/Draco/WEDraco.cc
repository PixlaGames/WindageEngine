// See include/WEDraco.h. The only code here that is the engine's own; everything under src/ is Google's Draco
// 1.5.7, unmodified, under the Apache License 2.0 in LICENSE.
#include "WEDraco.h"

#include <memory>

#include "draco/compression/decode.h"
#include "draco/core/decoder_buffer.h"
#include "draco/mesh/mesh.h"

struct WEDracoMesh {
  std::unique_ptr<draco::Mesh> mesh;
};

WEDracoMesh *we_draco_decode(const void *data, size_t length) {
  draco::DecoderBuffer buffer;
  buffer.Init(static_cast<const char *>(data), length);
  draco::Decoder decoder;
  auto result = decoder.DecodeMeshFromBuffer(&buffer);
  if (!result.ok() || !result.value()) return nullptr;
  auto *out = new WEDracoMesh();
  out->mesh = std::move(result).value();
  return out;
}

void we_draco_free(WEDracoMesh *mesh) { delete mesh; }

uint32_t we_draco_point_count(const WEDracoMesh *mesh) { return mesh->mesh->num_points(); }

uint32_t we_draco_face_count(const WEDracoMesh *mesh) { return mesh->mesh->num_faces(); }

void we_draco_indices(const WEDracoMesh *mesh, uint32_t *out) {
  const draco::Mesh &m = *mesh->mesh;
  for (draco::FaceIndex f(0); f < m.num_faces(); ++f) {
    const auto &face = m.face(f);
    for (int c = 0; c < 3; ++c) out[f.value() * 3 + c] = face[c].value();
  }
}

int32_t we_draco_attribute_components(const WEDracoMesh *mesh, uint32_t unique_id) {
  const draco::PointAttribute *a = mesh->mesh->GetAttributeByUniqueId(unique_id);
  return a ? a->num_components() : 0;
}

int32_t we_draco_attribute_floats(const WEDracoMesh *mesh, uint32_t unique_id, float *out) {
  const draco::Mesh &m = *mesh->mesh;
  const draco::PointAttribute *a = m.GetAttributeByUniqueId(unique_id);
  if (!a) return 0;
  const int n = a->num_components();
  for (draco::PointIndex p(0); p < m.num_points(); ++p) {
    if (!a->ConvertValue<float>(a->mapped_index(p), static_cast<int8_t>(n), out + p.value() * n)) return 0;
  }
  return 1;
}
