// Stand-in for the MTS-ESP client header; MTS-ESP is not supported in this port.
#ifndef MTS_CLIENT_STUB_H
#define MTS_CLIENT_STUB_H
struct MTSClient;
inline bool MTS_HasMaster(MTSClient *) { return false; }
inline double MTS_NoteToFrequency(MTSClient *, char, char) { return 440.0; }
inline bool MTS_ShouldFilterNote(MTSClient *, char, char) { return false; }
#endif
