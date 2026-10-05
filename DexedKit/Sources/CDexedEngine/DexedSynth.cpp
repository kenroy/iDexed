// JUCE-free voice manager for the msfa engine. Ported from Dexed's PluginProcessor.cpp
// (keydown/keyup/chooseNote/processBlock). Copyright (c) Pascal Gauthier and contributors; GPL v3.
#include "include/CDexedEngine.h"

#include <atomic>
#include <cmath>
#include <cstring>
#include <memory>

#include "msfa/synth.h"
#include "msfa/aligned_buf.h"
#include "msfa/controllers.h"
#include "msfa/dx7note.h"
#include "msfa/exp2.h"
#include "msfa/freqlut.h"
#include "msfa/lfo.h"
#include "msfa/pitchenv.h"
#include "msfa/porta.h"
#include "msfa/sin.h"
#include "msfa/env.h"
#include "msfa/tuning.h"
#include "PluginFx.h"
#include "ScalaTuning.h"
#include "EngineMkI.h"
#include "EngineOpl.h"

void dexed_trace(const char *, const char *, ...) {}

namespace {

constexpr int kMaxVoices = 16;
constexpr int kQueueSize = 1024;  // power of two
// A tap can deliver note-on and note-off before a single block is rendered; hold the release
// for ~20 ms (at 48 kHz) so every key press is audible.
constexpr int kMinNoteBlocks = 15;

enum EventType : uint8_t {
    EvNoteOn, EvNoteOff, EvPitchBend, EvCC, EvAftertouch, EvPatch, EvParam, EvPanic,
    EvMono, EvEngine, EvOpMask, EvPitchRange, EvMod, EvMasterTune, EvFilter, EvPortamento, EvNormalizeVelocity
};

struct Event {
    EventType type;
    int a = 0, b = 0, c = 0, d = 0;
    float f1 = 0, f2 = 0;
    uint8_t patch[DEXED_PATCH_SIZE];
};

struct Voice {
    int channel = 0;
    int midi_note = -1;
    int velocity = 0;
    bool keydown = false;
    bool sustained = false;
    bool live = false;
    int keydown_seq = -1;
    int age = 0;                 // blocks rendered since keydown
    bool pendingKeyup = false;   // release requested before the minimum note length elapsed
    std::unique_ptr<Dx7Note> note;
};

void makeInitVoice(uint8_t *d) {
    memset(d, 0, DEXED_PATCH_SIZE);
    for (int op = 0; op < 6; op++) {
        uint8_t *o = d + op * 21;
        o[0] = o[1] = o[2] = o[3] = 99;
        o[4] = o[5] = o[6] = 99;
        o[17] = 0; o[18] = 1; o[20] = 7;
        o[16] = op == 5 ? 99 : 0;
    }
    const uint8_t tail[19] = {99, 99, 99, 99, 50, 50, 50, 50, 0, 0, 1, 35, 0, 0, 0, 1, 0, 3, 24};
    memcpy(d + 126, tail, sizeof(tail));
    memcpy(d + 145, "INIT VOICE", 10);
}

}  // namespace

struct DexedSynth {
    // Event queue: many producers (guarded by a spin flag), one consumer (audio thread).
    Event queue[kQueueSize];
    std::atomic<uint32_t> head{0}, tail{0};
    std::atomic_flag producerLock = ATOMIC_FLAG_INIT;

    // Everything below is touched by the audio thread only.
    Voice voices[kMaxVoices];
    Controllers controllers;
    Lfo lfo;
    PluginFx fx;
    std::atomic<std::shared_ptr<TuningState> *> pendingTuning{nullptr};
    EngineMkI engineMkI;
    EngineOpl engineOpl;
    FmCore engineModern;
    std::shared_ptr<TuningState> tuning;
    uint8_t data[DEXED_PATCH_SIZE + 4];
    int currentNote = 0;
    int lastActiveVoice = 0;
    int nextKeydownSeq = 0;
    bool sustain = false;
    bool monoMode = false;
    bool refreshVoice = false;
    bool normalizeVelocity = false;

    // Published at the end of render() for the UI thread (relaxed atomics; torn reads are harmless).
    std::atomic<uint32_t> pubAmp[6]{};
    std::atomic<int> pubStage[6]{};
    std::atomic<int> pubPitchStage{-1};
    std::atomic<float> pubLevel{0};
    std::atomic<uint64_t> pubNotes[2]{};
    std::atomic<float> outputGain{1.0f};
    float vu = 0;
    double sampleRate = 48000;

    float carry[N];
    int carryPos = N;  // N == empty

    void initRateDependentTables(double sr) {
        sampleRate = sr;
        Freqlut::init(sr);
        Lfo::init(sr);
        PitchEnv::init(sr);
        Env::init_sr(sr);
        Porta::init_sr(sr);
        fx.init((int)sr);
        vu = 0;
    }

    void setSampleRate(double sr) {
        panic();
        initRateDependentTables(sr);
        for (auto &v : voices) v.note.reset(new Dx7Note(tuning, nullptr));
        lfo.reset(data + 137);
        carryPos = N;
    }

    DexedSynth(double sr) {
        Exp2::init();
        Tanh::init();
        Sin::init();
        initRateDependentTables(sr);

        tuning = createStandardTuning();
        memset(data, 0, sizeof(data));
        makeInitVoice(data);

        controllers.core = &engineMkI;
        controllers.values_[kControllerPitch] = 0x2000;
        controllers.values_[kControllerPitchRangeUp] = 3;
        controllers.values_[kControllerPitchRangeDn] = 3;
        controllers.values_[kControllerPitchStep] = 0;
        controllers.masterTune = 0;
        controllers.mpeEnabled = false;
        controllers.modwheel_cc = controllers.foot_cc = controllers.breath_cc = controllers.aftertouch_cc = 0;
        controllers.portamento_enable_cc = false;
        controllers.portamento_cc = 0;
        controllers.wheel.range = 50; controllers.wheel.pitch = true;
        controllers.foot.range = 50;  controllers.foot.amp = true;
        controllers.breath.range = 50; controllers.breath.amp = true;
        controllers.at.range = 50;    controllers.at.pitch = true;
        controllers.refresh();

        for (auto &v : voices) v.note.reset(new Dx7Note(tuning, nullptr));
        lfo.reset(data + 137);
    }

    void push(const Event &e) {
        while (producerLock.test_and_set(std::memory_order_acquire)) {}
        uint32_t h = head.load(std::memory_order_relaxed);
        if (h - tail.load(std::memory_order_acquire) < kQueueSize) {
            queue[h & (kQueueSize - 1)] = e;
            head.store(h + 1, std::memory_order_release);
        }
        producerLock.clear(std::memory_order_release);
    }

    int transpose() const {
        // With a custom tuning, whole-octave transposes shift by whole scale periods (as in Dexed).
        if (tuning->is_standard_tuning() || data[144] % 12 != 0) return data[144] - 24;
        return (data[144] - 24) / 12 * tuning->scale_length();
    }

    int chooseNote(uint8_t pitch) {
        int bestNote = currentNote, bestScore = -1, note = currentNote;
        for (int i = 0; i < kMaxVoices; i++) {
            int score = 0;
            if (!voices[note].note->isPlaying()) score += 4;
            if (!voices[note].keydown) score += 2;
            if (voices[note].midi_note == pitch) score += 1;
            if (score > bestScore ||
                (score == bestScore && voices[note].keydown_seq < voices[bestNote].keydown_seq)) {
                bestNote = note;
                bestScore = score;
            }
            note = (note + 1) % kMaxVoices;
        }
        return bestNote;
    }

    void keydown(int channel, int pitch, int velo) {
        if (velo == 0) { keyup(channel, pitch); return; }
        if (normalizeVelocity) velo = (int)((float)velo * 0.7874015f);   // 100/127, as Dexed
        pitch += transpose();
        if (pitch < 0 || pitch > 127) return;

        bool triggerLfo = true;
        for (auto &v : voices) if (v.keydown) { triggerLfo = false; break; }
        if (triggerLfo) lfo.keydown();

        int n = chooseNote((uint8_t)pitch);
        currentNote = (n + 1) % kMaxVoices;
        Voice &v = voices[n];
        v.channel = channel;
        v.midi_note = pitch;
        v.velocity = velo;
        v.sustained = sustain;
        v.keydown = true;
        v.keydown_seq = nextKeydownSeq++;
        v.age = 0;
        v.pendingKeyup = false;
        bool voiceSteal = v.note->isPlaying();
        v.note->init(data, pitch, velo, channel, &controllers);
        if (data[136] && !voiceSteal) v.note->oscSync();
        if (voices[lastActiveVoice].midi_note != -1 && controllers.portamento_enable_cc &&
            controllers.portamento_cc > 0)
            v.note->initPortamento(*voices[lastActiveVoice].note);

        if (monoMode) {
            for (int i = 0; i < kMaxVoices; i++) {
                if (voices[i].live) {
                    if (!voices[i].keydown) {
                        voices[i].live = false;
                        v.note->transferSignal(*voices[i].note);
                        break;
                    }
                    if (voices[i].midi_note < pitch) {
                        voices[i].live = false;
                        v.note->transferState(*voices[i].note);
                        break;
                    }
                    return;
                }
            }
        } else if (!data[136]) {
            for (int i = 0; i < kMaxVoices; i++) {
                if (i != n && voices[i].note->isPlaying() && voices[i].midi_note == pitch) {
                    v.note->transferPhase(*voices[i].note);
                    break;
                }
            }
        }
        v.live = true;
        lastActiveVoice = n;
    }

    void keyup(int, int pitch) {
        pitch += transpose();
        int n;
        for (n = 0; n < kMaxVoices; ++n) {
            if (voices[n].midi_note == pitch && voices[n].keydown) {
                voices[n].keydown = false;
                break;
            }
        }
        if (n >= kMaxVoices) return;

        if (monoMode) {
            int highNote = -1, target = 0;
            for (int i = 0; i < kMaxVoices; i++) {
                if (voices[i].keydown && voices[i].midi_note > highNote) {
                    target = i;
                    highNote = voices[i].midi_note;
                }
            }
            if (highNote != -1 && voices[n].live) {
                voices[n].live = false;
                voices[target].live = true;
                voices[target].note->transferState(*voices[n].note);
            }
        }
        if (voices[n].age < kMinNoteBlocks) voices[n].pendingKeyup = true;
        else releaseVoice(voices[n]);
    }

    void releaseVoice(Voice &v) {
        if (sustain) v.sustained = true;
        else v.note->keyup();
    }

    void panic() {
        for (auto &v : voices) {
            v.keydown = false;
            v.live = false;
            v.sustained = false;
            v.pendingKeyup = false;
            v.midi_note = -1;
        }
        sustain = false;
    }

    FmMod &modFor(int source) {
        switch (source) {
            case DEXED_MOD_FOOT: return controllers.foot;
            case DEXED_MOD_BREATH: return controllers.breath;
            case DEXED_MOD_AFTERTOUCH: return controllers.at;
            default: return controllers.wheel;
        }
    }

    void apply(const Event &e) {
        switch (e.type) {
            case EvNoteOn: keydown(e.a, e.b, e.c); break;
            case EvNoteOff: keyup(e.a, e.b); break;
            case EvPitchBend: controllers.values_[kControllerPitch] = e.a; break;
            case EvCC:
                switch (e.a) {
                    case 1: controllers.modwheel_cc = e.b; controllers.refresh(); break;
                    case 2: controllers.breath_cc = e.b; controllers.refresh(); break;
                    case 4: controllers.foot_cc = e.b; controllers.refresh(); break;
                    case 5: controllers.portamento_cc = e.b; break;
                    case 64:
                        sustain = e.b > 63;
                        if (!sustain) {
                            for (auto &v : voices) {
                                if (v.sustained && !v.keydown) {
                                    v.note->keyup();
                                    v.sustained = false;
                                }
                            }
                        }
                        break;
                    case 65: controllers.portamento_enable_cc = e.b >= 64; break;
                    case 120: panic(); break;
                    case 123:
                        for (auto &v : voices) if (v.keydown) keyup(v.channel, v.midi_note - transpose());
                        break;
                }
                break;
            case EvAftertouch: controllers.aftertouch_cc = e.a; controllers.refresh(); break;
            case EvPatch:
                memcpy(data, e.patch, DEXED_PATCH_SIZE);
                refreshVoice = true;
                break;
            case EvParam:
                if (e.a >= 0 && e.a < DEXED_PATCH_SIZE) { data[e.a] = (uint8_t)e.b; refreshVoice = true; }
                break;
            case EvPanic: panic(); break;
            case EvMono: panic(); monoMode = e.a != 0; break;
            case EvEngine:
                controllers.core = e.a == DEXED_ENGINE_OPL ? (FmCore *)&engineOpl
                                 : e.a == DEXED_ENGINE_MARKI ? (FmCore *)&engineMkI
                                 : &engineModern;
                break;
            case EvOpMask:
                for (int i = 0; i < 6; i++) controllers.opSwitch[i] = (e.a >> i) & 1 ? '1' : '0';
                controllers.opSwitch[6] = 0;
                break;
            case EvPitchRange:
                controllers.values_[kControllerPitchRangeUp] = e.a;
                controllers.values_[kControllerPitchRangeDn] = e.b;
                controllers.values_[kControllerPitchStep] = e.c;
                break;
            case EvMod: {
                FmMod &m = modFor(e.a);
                m.range = e.b; m.pitch = e.c & 1; m.amp = e.c & 2; m.eg = e.c & 4;
                controllers.refresh();
                break;
            }
            case EvMasterTune: {
                int32_t tune = (int32_t)(e.f1 * 0x4000) - 0x2000;
                controllers.masterTune = (int)((float)(tune * 2048) * (1.0 / 12));
                break;
            }
            case EvFilter: fx.uiCutoff = e.f1; fx.uiReso = e.f2; break;
            case EvPortamento:
                controllers.portamento_cc = e.a;
                controllers.portamento_enable_cc = e.a > 0;
                controllers.portamento_gliss_cc = e.b != 0;
                break;
            case EvNormalizeVelocity: normalizeVelocity = e.a != 0; break;
        }
    }

    void drain() {
        if (auto *pending = pendingTuning.exchange(nullptr)) {
            tuning = *pending;
            delete pending;
            for (auto &v : voices) v.note->tuning_state_ = tuning;
        }
        uint32_t t = tail.load(std::memory_order_relaxed);
        uint32_t h = head.load(std::memory_order_acquire);
        while (t != h) {
            apply(queue[t & (kQueueSize - 1)]);
            t++;
        }
        tail.store(t, std::memory_order_release);
        if (refreshVoice) {
            for (auto &v : voices)
                if (v.live) v.note->update(data, v.midi_note, v.velocity, v.channel);
            lfo.reset(data + 137);
            refreshVoice = false;
        }
    }

    void renderBlock(float *sum) {
        AlignedBuf<int32_t, N> audiobuf;
        for (int j = 0; j < N; ++j) { audiobuf.get()[j] = 0; sum[j] = 0; }
        int32_t lfovalue = lfo.getsample();
        int32_t lfodelay = lfo.getdelay();
        for (auto &v : voices) {
            if (!v.live) continue;
            v.note->compute(audiobuf.get(), lfovalue, lfodelay, &controllers);
            if (v.age < kMinNoteBlocks) v.age++;
            if (v.pendingKeyup && v.age >= kMinNoteBlocks) {
                v.pendingKeyup = false;
                if (!v.keydown) releaseVoice(v);
            }
            for (int j = 0; j < N; ++j) {
                int32_t val = audiobuf.get()[j] >> 4;
                int clip = val < -(1 << 24) ? 0x8000 : val >= (1 << 24) ? 0x7fff : val >> 9;
                float f = (float)clip / (float)0x8000;
                if (f > 1) f = 1;
                if (f < -1) f = -1;
                sum[j] += f;
                audiobuf.get()[j] = 0;
            }
        }
    }

    void render(float *out, int frames) {
        drain();
        int i = 0;
        while (i < frames) {
            if (carryPos >= N) {
                renderBlock(carry);
                carryPos = 0;
            }
            int n = N - carryPos;
            if (n > frames - i) n = frames - i;
            memcpy(out + i, carry + carryPos, n * sizeof(float));
            carryPos += n;
            i += n;
        }
        fx.process(out, frames);
        publishStatus(out, frames);
        const float gain = outputGain.load(std::memory_order_relaxed);
        if (gain != 1.0f) for (int k = 0; k < frames; k++) out[k] *= gain;
    }

    void publishStatus(const float *out, int frames) {
        float peak = 0;
        for (int i = 0; i < frames; i++) peak = std::fmax(peak, std::fabs(out[i]));
        // 40 dB of fall-off per second.
        vu = std::fmax(peak, vu * (float)std::pow(0.01, (double)frames / sampleRate));
        if (vu < 1e-4f) vu = 0;
        pubLevel.store(vu, std::memory_order_relaxed);

        uint64_t notes[2] = {0, 0};
        int best = -1;
        for (int i = 0; i < kMaxVoices; i++) {
            const Voice &v = voices[i];
            if (v.live && (v.keydown || v.sustained) && v.midi_note >= 0) {
                int shown = v.midi_note - transpose();
                if (shown >= 0 && shown < 128) notes[shown >> 6] |= 1ull << (shown & 63);
            }
            if (v.live && v.note->isPlaying() && (best < 0 || v.keydown_seq > voices[best].keydown_seq)) best = i;
        }
        pubNotes[0].store(notes[0], std::memory_order_relaxed);
        pubNotes[1].store(notes[1], std::memory_order_relaxed);

        VoiceStatus st;
        memset(&st, 0, sizeof(st));
        if (best >= 0) voices[best].note->peekVoiceStatus(st);
        for (int k = 0; k < 6; k++) {
            pubAmp[k].store(best >= 0 ? st.amp[k] : 0, std::memory_order_relaxed);
            pubStage[k].store(best >= 0 ? st.ampStep[k] : -1, std::memory_order_relaxed);
        }
        pubPitchStage.store(best >= 0 ? st.pitchStep : -1, std::memory_order_relaxed);
    }
};

extern "C" {

void dexed_set_sample_rate(DexedSynth *s, double sr) { s->setSampleRate(sr); }

DexedSynth *dexed_create(double sr) { return new DexedSynth(sr); }
void dexed_destroy(DexedSynth *s) { delete s; }

static void post(DexedSynth *s, EventType t, int a = 0, int b = 0, int c = 0) {
    Event e;
    e.type = t; e.a = a; e.b = b; e.c = c;
    s->push(e);
}

void dexed_set_patch(DexedSynth *s, const uint8_t *patch) {
    Event e;
    e.type = EvPatch;
    memcpy(e.patch, patch, DEXED_PATCH_SIZE);
    s->push(e);
}
void dexed_set_param(DexedSynth *s, int offset, int value) { post(s, EvParam, offset, value); }
void dexed_note_on(DexedSynth *s, int ch, int note, int vel) { post(s, EvNoteOn, ch, note, vel); }
void dexed_note_off(DexedSynth *s, int ch, int note) { post(s, EvNoteOff, ch, note); }
void dexed_pitch_bend(DexedSynth *s, int v) { post(s, EvPitchBend, v); }
void dexed_control_change(DexedSynth *s, int cc, int v) { post(s, EvCC, cc, v); }
void dexed_aftertouch(DexedSynth *s, int v) { post(s, EvAftertouch, v); }
void dexed_panic(DexedSynth *s) { post(s, EvPanic); }
void dexed_set_mono(DexedSynth *s, bool m) { post(s, EvMono, m); }
void dexed_set_engine(DexedSynth *s, int e) { post(s, EvEngine, e); }
void dexed_set_op_mask(DexedSynth *s, int m) { post(s, EvOpMask, m); }
void dexed_set_pitch_range(DexedSynth *s, int up, int dn, int step) { post(s, EvPitchRange, up, dn, step); }
void dexed_set_mod(DexedSynth *s, int src, int range, bool p, bool a, bool e) {
    post(s, EvMod, src, range, (p ? 1 : 0) | (a ? 2 : 0) | (e ? 4 : 0));
}
void dexed_set_master_tune(DexedSynth *s, float v) {
    Event e; e.type = EvMasterTune; e.f1 = v; s->push(e);
}
void dexed_set_portamento(DexedSynth *s, int time, bool glissando) { post(s, EvPortamento, time, glissando); }
void dexed_set_output_gain(DexedSynth *s, float gain) { s->outputGain.store(gain, std::memory_order_relaxed); }
void dexed_set_normalize_velocity(DexedSynth *s, bool on) { post(s, EvNormalizeVelocity, on); }
void dexed_set_filter(DexedSynth *s, float cutoff, float resonance) {
    Event e; e.type = EvFilter; e.f1 = cutoff; e.f2 = resonance; s->push(e);
}
bool dexed_set_tuning(DexedSynth *s, const char *scl, const char *kbm, char *error, int errorSize) {
    std::shared_ptr<TuningState> t;
    if (scl && *scl) {
        std::string err;
        t = createScalaTuning(scl, kbm ? kbm : "", err);
        if (!t) {
            if (error && errorSize > 0) { strncpy(error, err.c_str(), errorSize - 1); error[errorSize - 1] = 0; }
            return false;
        }
    } else {
        t = createStandardTuning();
    }
    delete s->pendingTuning.exchange(new std::shared_ptr<TuningState>(t));
    return true;
}
void dexed_render(DexedSynth *s, float *out, int frames) { s->render(out, frames); }

void dexed_get_status(DexedSynth *s, DexedStatus *o) {
    for (int k = 0; k < 6; k++) {
        o->opAmp[k] = s->pubAmp[k].load(std::memory_order_relaxed);
        o->opStage[k] = (int8_t)s->pubStage[k].load(std::memory_order_relaxed);
    }
    o->pitchStage = (int8_t)s->pubPitchStage.load(std::memory_order_relaxed);
    o->outputLevel = s->pubLevel.load(std::memory_order_relaxed);
    o->heldNotes[0] = s->pubNotes[0].load(std::memory_order_relaxed);
    o->heldNotes[1] = s->pubNotes[1].load(std::memory_order_relaxed);
}

}
