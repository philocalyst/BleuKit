# bleu_audio

The audio service: output and input devices with volume, mute and balance;
application playback and recording streams; card profiles and ports; the
microphone-in-use indicator; and device, stream and default changes as events.
Module root `bleu::audio`. Spec: `docs/research/audio.md` (v1 cut). What was
verified and where the implementation departs from the research:
`docs/research/audio_impl.md`.

Backends: `pulse` (Linux, PulseAudio native protocol, also PipeWire's pulse
server), `coreaudio` (macOS, HAL property API), `wasapi` (Windows, MMDevice,
EndpointVolume, audio sessions). Each backend runs on the service's worker
thread, as ARCHITECTURE.md requires.

## Public API

* `audio::open(allocator, Options{backend, server, cookie_file})` → `Audio*`;
  `close()`, `backend_name()`, `capability(Cap)`.
* State: `latest()` (a retained `Snapshot{State}`), `wait_after(seen, timeout)`,
  `watch(listener, ctx)` / `unwatch`. `State.degraded` is "" when every list was
  read; otherwise it names a list that stopped at a record the decoder does not
  understand (the other lists are still published).
* Events: `subscribe()` → `Reader{Event}` (`DEVICE_ADDED`, `DEVICE_CHANGED`,
  `DEFAULT_CHANGED`, `STREAM_ADDED/CHANGED/REMOVED`, `CARD_CHANGED`,
  `MIC_IN_USE_CHANGED`, ...). Events name the object; re-read the state.
* Commands, each returning `Pending*?` (an `Operation{bool}`, complete when the
  server answered; the change itself arrives in the state):
  `set_device_volume(flow, id, Gain[])`, `set_device_mute`, `set_default`,
  `set_stream_volume(id, flow, Gain[])`, `set_stream_mute`,
  `move_stream(id, flow, device)`, `set_port(flow, device, port)`,
  `set_card_profile(card, profile)`, `refresh()` (re-reads the whole server and
  publishes it, even when no event announced a change).
* Volume is `bleu::unit::Gain` on the backend's own slider scale (1.0 = nominal
  100 %). `audio::volume` converts: `decibels`, `from_decibels`, `amplitude`,
  `from_amplitude`; PulseAudio's cubic mapping is documented there (50 % = 32768
  = -18.06 dB). Balance is derived (`Device.balance`), not stored.

## Coverage

Status words: **Run** = executed here; **Compiled** = type-checked for the
target only (`tools/check.sh`), never executed; **Not done** = not implemented.

Linux, `pulse` backend. "Run (mock)" = the Python mock server
(`tests/pulse_mock.py`); "Run (PA 16.1)" = a real PulseAudio 16.1 daemon (null
sink, auto-authenticated); "Run (PW 1.0.5)" = pipewire-pulse 1.0.5 on PipeWire.

| Capability | Linux pulse | macOS coreaudio | Windows wasapi |
| --- | --- | --- | --- |
| DEVICE_VOLUME | Run (mock; PA 16.1 round trip) | Compiled | Compiled |
| DEVICE_BOOST (above 100 %) | Run (mock: 120 % set and read back) | Not done: no boost in the HAL | Not done: endpoint is 0..1 |
| DEVICE_MUTE | Run (mock; PA 16.1 round trip) | Compiled | Compiled |
| INPUT_DEVICES | Run (mock: microphone listed, monitor hidden) | Compiled | Compiled |
| DEFAULT_SET | Run (mock) | Compiled | Not done: undocumented IPolicyConfig |
| PORTS / PORT_SET | Run (mock: listed, set accepted; active port checked) | Not done | Not done |
| CARD_PROFILES / CARD_PROFILE_SET | Run (mock; card decoder on synthetic record) | Not done: Linux only | Not done: Linux only |
| STREAMS_PLAYBACK | Run (mock; PA 16.1 record decoded from a real stream) | Not done: no per-app route | Compiled |
| STREAMS_RECORD | Run (mock; PA 16.1 record decoded from a real stream) | Not done | Compiled |
| STREAM_VOLUME / STREAM_MUTE | Run (mock) | Not done | Compiled |
| STREAM_MOVE | Run (mock) | Not done | Not done: undocumented IPolicyConfig |
| MIC_IN_USE | Run (mock: true; monitor excluded in PA 16.1 fixture) | Compiled (approximation) | Compiled (capture session active) |
| EVENTS | Run (mock: add, remove, change, default; PA 16.1 volume round trip) | Compiled | Compiled (notifications; volume read once a second) |
| HW_VOLUME_FLAG | Run (mock: sink flag decoded) | Compiled (property presence, unverified) | Compiled, always "software" (not read) |
| PEAK_METER | Not done | Not done | Not done |
| Default device get | Run (PA 16.1; mock) and "none" under PW 1.0.5 | Compiled | Compiled |

Run totals (this change): 36 `@test` functions of the library pass
(`c3c compile-test --test-filter bleu::audio`; 30 existed before, 6 were added
for the review's findings); mock integration 60 of 60 checks (48 before), and the
same 60 with no cookie file (`run.sh nocookie`); PA 16.1 integration 11 of 11; PW
1.0.5 integration 11 of 11 (the server reports no default; the target is the
first output). Nothing was run on macOS or Windows.

## Not done

* macOS and Windows backends are compiled only: nothing about them ran. The
  HAL selector values are from the objc2-core-audio generated bindings, not
  from a Mac. The COM slots are from the windows crate 0.58.0 bindings, not
  from a Windows machine.
* Windows volume changes are read once a second (no `IAudioEndpointVolumeCallback`).
* Windows `volume_is_hardware` is always false; `QueryHardwareSupport` is not read.
* Linux: no peak meter; no ALSA fallback (research cut line 2.1.9); no TCP
  servers (only unix sockets); cookie from the X11 root property is not read.
* Linux: a server that names no default (pipewire-pulse 1.0.5 answers the
  `@DEFAULT_SINK@` alias with NOENTITY) reports no default device.
* Linux: `device.form_factor` of an HDMI sink is inferred from its name ("hdmi");
  Bluetooth headsets are BLUETOOTH on the bus with the form factor the server reports.
* Balance uses the left and right channel sets of `pa_cvolume_get_balance`; the
  mask definition in PulseAudio was not located (UNVERIFIED in `pulse_volume.c3`).
* Stream records on Linux are re-read on every event (no incremental update).
* Linux: a list reply has no record lengths, so when one record does not decode,
  the records after it in that list are lost (the ones before it are kept, and
  `State.degraded` says so). A server ERROR reply to a list query still ends the
  refresh and the connection is re-made.
* Windows and macOS: when the change listeners cannot be registered, the worker
  keeps polling (once a second) and reports no error. `capability` still says the
  events are available, because `Hub.start` has no start-up error to report and
  `open` returns before the worker registers anything. Compiled only.
* macOS: listeners are re-registered only when the set of device IDs changes. A
  device that keeps its ID but gains or loses a stream direction is seen when the
  set next changes. Compiled only.
