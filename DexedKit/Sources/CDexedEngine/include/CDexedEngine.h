// C interface to the Dexed (msfa) FM synth engine.
// All mutating calls are thread-safe and are applied on the audio thread at the start of
// the next dexed_render() call. dexed_render() itself must only be called from one thread.
#ifndef CDEXEDENGINE_H
#define CDEXEDENGINE_H

#include <stdint.h>
#include <stdbool.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct DexedSynth DexedSynth;

enum {
    DEXED_PATCH_SIZE = 156,   // unpacked single-voice size (155 bytes + op-switch slot unused)
    DEXED_ENGINE_MODERN = 0,
    DEXED_ENGINE_MARKI = 1,
    DEXED_ENGINE_OPL = 2,
    DEXED_MOD_WHEEL = 0,
    DEXED_MOD_FOOT = 1,
    DEXED_MOD_BREATH = 2,
    DEXED_MOD_AFTERTOUCH = 3,
};

DexedSynth *dexed_create(double sampleRate);
void dexed_destroy(DexedSynth *s);

void dexed_set_patch(DexedSynth *s, const uint8_t patch[DEXED_PATCH_SIZE]);
void dexed_set_param(DexedSynth *s, int offset, int value);

void dexed_note_on(DexedSynth *s, int channel, int note, int velocity);
void dexed_note_off(DexedSynth *s, int channel, int note);
void dexed_pitch_bend(DexedSynth *s, int value14bit);
void dexed_control_change(DexedSynth *s, int cc, int value);
void dexed_aftertouch(DexedSynth *s, int value);
void dexed_panic(DexedSynth *s);

void dexed_set_mono(DexedSynth *s, bool mono);
void dexed_set_engine(DexedSynth *s, int engine);
void dexed_set_op_mask(DexedSynth *s, int mask6bit);
void dexed_set_pitch_range(DexedSynth *s, int up, int down, int step);
void dexed_set_mod(DexedSynth *s, int source, int range, bool pitch, bool amp, bool eg);
// Master tune and output filter. `value` / `cutoff` / `resonance` are normalised 0…1 (tune 0.5 = in tune, cutoff 1 = open).
void dexed_set_master_tune(DexedSynth *s, float value);
void dexed_set_filter(DexedSynth *s, float cutoff, float resonance);
// Microtuning from Scala file contents. scl = NULL/empty restores standard 12-TET. kbm may be NULL.
// Returns false and fills `error` if a file can't be parsed.
bool dexed_set_tuning(DexedSynth *s, const char *scl, const char *kbm, char *error, int errorSize);

// Live metering, refreshed at the end of every dexed_render(). Operator arrays use the
// engine's storage order (index 0 = OP6 … index 5 = OP1).
typedef struct {
    uint32_t opAmp[6];      // raw engine amplitude of the most recent voice; 0 when silent
    int8_t opStage[6];      // envelope stage 0…3 (3 = release); -1 when silent
    int8_t pitchStage;
    float outputLevel;      // peak with slow decay, 0…1
    uint64_t heldNotes[2];  // bitmask of MIDI notes held down (bit n of word n/64)
} DexedStatus;

void dexed_get_status(DexedSynth *s, DexedStatus *out);

// Changes the sample rate. Only call while no dexed_render() is running (e.g. from AU allocateRenderResources);
// all voices are silenced.
void dexed_set_sample_rate(DexedSynth *s, double sampleRate);

// Renders mono float samples in [-1, 1].
void dexed_render(DexedSynth *s, float *out, int frames);

#ifdef __cplusplus
}
#endif
#endif
