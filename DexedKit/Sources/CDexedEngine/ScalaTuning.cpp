#include "ScalaTuning.h"

#include <cmath>
#include <cstdlib>
#include <sstream>
#include <vector>

namespace {

std::vector<std::string> contentLines(const std::string &text) {
    std::vector<std::string> out;
    std::istringstream in(text);
    std::string line;
    while (std::getline(in, line)) {
        if (!line.empty() && line.back() == '\r') line.pop_back();
        size_t first = line.find_first_not_of(" \t");
        if (first == std::string::npos) { out.push_back(""); continue; }   // blank lines can be meaningful (description)
        if (line[first] == '!') continue;                                  // comment
        out.push_back(line.substr(first));
    }
    return out;
}

std::string firstToken(const std::string &line) {
    std::istringstream in(line);
    std::string t;
    in >> t;
    return t;
}

bool parseDegree(const std::string &line, double &cents) {
    std::string t = firstToken(line);
    if (t.empty()) return false;
    if (t.find('.') != std::string::npos) {
        char *end = nullptr;
        cents = std::strtod(t.c_str(), &end);
        return end != t.c_str();
    }
    size_t slash = t.find('/');
    double num, den = 1;
    char *end = nullptr;
    num = std::strtod(t.c_str(), &end);
    if (end == t.c_str()) return false;
    if (slash != std::string::npos) den = std::strtod(t.c_str() + slash + 1, nullptr);
    if (num <= 0 || den <= 0) return false;
    cents = 1200.0 * std::log2(num / den);
    return true;
}

int floorDiv(int a, int b) {
    int q = a / b;
    if ((a % b != 0) && ((a < 0) != (b < 0))) q--;
    return q;
}

struct ScalaTuningState : public TuningState {
    int32_t table[128];
    int length = 12;
    std::string description = "Scala tuning";

    int32_t midinote_to_logfreq(int midinote) override {
        if (midinote < 0) midinote = 0;
        if (midinote > 127) midinote = 127;
        return table[midinote];
    }
    bool is_standard_tuning() override { return false; }
    int scale_length() override { return length; }
    std::string display_tuning_str() override { return description; }
};

}  // namespace

std::shared_ptr<TuningState> createScalaTuning(const std::string &scl, const std::string &kbm, std::string &error) {
    // ---- scale ----
    auto lines = contentLines(scl);
    if (lines.size() < 2) { error = "The Scala file is empty or incomplete."; return nullptr; }
    std::string description = lines[0];
    int count = std::atoi(firstToken(lines[1]).c_str());
    if (count <= 0 || (int)lines.size() < 2 + count) { error = "The Scala file has an invalid note count."; return nullptr; }
    std::vector<double> cents;
    for (int i = 0; i < count; i++) {
        double c;
        if (!parseDegree(lines[2 + i], c)) { error = "Couldn't read note " + std::to_string(i + 1) + " of the Scala file."; return nullptr; }
        cents.push_back(c);
    }
    double period = cents.back();
    if (period <= 0) { error = "The scale's period (last note) must be above zero."; return nullptr; }

    auto degreeCents = [&](int d) {
        int oct = floorDiv(d, count);
        int idx = d - oct * count;
        return oct * period + (idx == 0 ? 0.0 : cents[idx - 1]);
    };

    // ---- keyboard mapping ----
    int mapSize = 0, firstNote = 0, lastNote = 127, middle = 60, refNote = 60, octaveDegree = count;
    double refFreq = 440.0 * std::pow(2.0, -9.0 / 12.0);   // middle C
    std::vector<int> mapping;
    if (!kbm.empty()) {
        auto k = contentLines(kbm);
        // Mapping rows may legitimately be blank-trimmed; drop empty strings.
        std::vector<std::string> v;
        for (auto &l : k) if (!l.empty()) v.push_back(l);
        if (v.size() < 7) { error = "The keyboard-mapping file is incomplete."; return nullptr; }
        mapSize = std::atoi(firstToken(v[0]).c_str());
        firstNote = std::atoi(firstToken(v[1]).c_str());
        lastNote = std::atoi(firstToken(v[2]).c_str());
        middle = std::atoi(firstToken(v[3]).c_str());
        refNote = std::atoi(firstToken(v[4]).c_str());
        refFreq = std::atof(firstToken(v[5]).c_str());
        octaveDegree = std::atoi(firstToken(v[6]).c_str());
        if (refFreq <= 0 || mapSize < 0 || (int)v.size() < 7 + mapSize) {
            error = "The keyboard-mapping file has invalid values."; return nullptr;
        }
        for (int i = 0; i < mapSize; i++) {
            std::string t = firstToken(v[7 + i]);
            mapping.push_back((t == "x" || t == "X") ? -1000000 : std::atoi(t.c_str()));
        }
    }

    // Absolute degree (in scale steps, may exceed one period) of a MIDI note; false when unmapped.
    auto degreeOf = [&](int note, int &degree) {
        if (note < firstNote || note > lastNote) return false;
        int dist = note - middle;
        if (mapSize == 0) { degree = dist; return true; }
        int cycle = floorDiv(dist, mapSize);
        int idx = dist - cycle * mapSize;
        if (mapping[idx] == -1000000) return false;
        degree = cycle * octaveDegree + mapping[idx];
        return true;
    };

    int refDegree = 0;
    if (!degreeOf(refNote, refDegree)) refDegree = refNote - middle;
    double refCents = degreeCents(refDegree);

    auto state = std::make_shared<ScalaTuningState>();
    state->length = count;
    state->description = description.empty() ? "Scala tuning" : description;
    const double step = (double)(1 << 24);
    for (int n = 0; n < 128; n++) {
        int d;
        double freq;
        if (degreeOf(n, d)) freq = refFreq * std::pow(2.0, (degreeCents(d) - refCents) / 1200.0);
        else freq = 440.0 * std::pow(2.0, (n - 69) / 12.0);   // unmapped keys fall back to 12-TET
        state->table[n] = (int32_t)std::llround(std::log2(freq) * step);
    }
    return state;
}
