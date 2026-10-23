// Written for this package in place of the file Draco's CMake build generates, with the same features CMake
// enables by default for a native build: mesh and point-cloud decoding, both Edgebreaker variants,
// normal encoding, backwards compatibility and deduplication. The transcoder (glTF/scene tooling) is off.
#ifndef DRACO_FEATURES_H_
#define DRACO_FEATURES_H_

#define DRACO_POINT_CLOUD_COMPRESSION_SUPPORTED
#define DRACO_MESH_COMPRESSION_SUPPORTED
#define DRACO_NORMAL_ENCODING_SUPPORTED
#define DRACO_STANDARD_EDGEBREAKER_SUPPORTED
#define DRACO_PREDICTIVE_EDGEBREAKER_SUPPORTED
#define DRACO_BACKWARDS_COMPATIBILITY_SUPPORTED
#define DRACO_ATTRIBUTE_INDICES_DEDUPLICATION_SUPPORTED
#define DRACO_ATTRIBUTE_VALUES_DEDUPLICATION_SUPPORTED

#endif  // DRACO_FEATURES_H_
