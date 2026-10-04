// Scala (.scl) / keyboard-mapping (.kbm) microtuning for the msfa engine.
// Independent implementation of the published Scala file formats (Dexed itself uses the tuning-library project).
#ifndef SCALA_TUNING_H
#define SCALA_TUNING_H

#include <memory>
#include <string>
#include "msfa/tuning.h"

// `scl` must be non-empty; `kbm` may be empty (standard mapping: middle C = 261.6256 Hz, linear keys).
// On failure returns nullptr and fills `error`.
std::shared_ptr<TuningState> createScalaTuning(const std::string &scl, const std::string &kbm, std::string &error);

#endif
