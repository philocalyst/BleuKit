# audio: implementation notes

Companion to `docs/research/audio.md` (the spec) and `libs/bleu_audio.c3l/README.md`
(what runs and what does not). This file lists what was verified, what changed
from the research, and the open doubts.

## 1. Corrections to the research (verified)

The research's command numbers came from `grep -n` line numbers of the enum
in `native-common.h`, not from the enum values. Every number in section 2.1 that
names a command is wrong; the table used by `pulse_wire.c3` is the enum's values:

| Command | Research said | Value (verified) |
| --- | --- | --- |
| AUTH | 45 | **8** (pactl capture; crate `command.rs` `Auth = 8`) |
| SET_CLIENT_NAME | 46 | **9** |
| GET_SERVER_INFO | 58 | **20** |
| GET_SINK_INFO / GET_SOURCE_INFO | (not listed) | **21 / 23** |
| GET_SINK_INFO_LIST / GET_SOURCE_INFO_LIST | 60 / 62 | **22 / 24** |
| GET_SINK_INPUT_INFO_LIST / GET_SOURCE_OUTPUT_INFO_LIST | 68 / 70 | **30 / 32** |
| SUBSCRIBE | 73 | **35** |
| SUBSCRIBE_EVENT | 116 | **66** |
| SET_SINK_VOLUME / SET_SINK_INPUT_VOLUME / SET_SOURCE_VOLUME | 75 / 76 / 77 | **36 / 37 / 38** |
| SET_SINK_MUTE / SET_SOURCE_MUTE / SET_SINK_INPUT_MUTE | 79 / 80 / 125 | **39 / 40 / 69** |
| SET_DEFAULT_SINK / SET_DEFAULT_SOURCE | 86 / 87 | **44 / 45** |
| MOVE_SINK_INPUT / MOVE_SOURCE_OUTPUT | 121 / (missing) | **67 / 68** |
| GET_CARD_INFO_LIST / SET_CARD_PROFILE | 159 / 160 | **89 / 90** |
| SET_SINK_PORT / SET_SOURCE_PORT | 171 / 172 | **96 / 97** |
| SET_SOURCE_OUTPUT_VOLUME / MUTE | 175 / 176 | **98 / 99** |

Two sources for the values: the enum's position in `native-common.h` (computed
by script) and the crate `pulseaudio-0.3.2` `src/protocol/command.rs`, which
gives Auth 8, SetClientName 9, GetServerInfo 20, GetSinkInfoList 22,
Subscribe 35, SetSinkVolume 36, SubscribeEvent 66, MoveSinkInput 67,
SetSinkPort 96, SetSourceOutputVolume 98. The AUTH value was also seen on the
wire in a `pactl info` capture against PulseAudio 16.1.

Other corrections:

* Source output: its volume, mute and has-volume flags come at protocol 22, not
  11 (`source_output_fill_tagstruct`, protocol-native.c:3445-3485). The sink
  input's mute is at 11.
* Source record format list is gated at 22; the sink record's at 21.
* The proplist entry carries the length twice: key string, `L` u32 length, then
  `x` arbitrary blob with its own length (tagstruct.c:313-336; crate
  `props.rs` `read`). Values also carry their terminating NUL inside the blob.
* Card records: profile availability at 29; ports at 26 with latency offset
  (`s64`) at 27 and group and type at 34 (protocol-native.c:3327-3385).
* Device flags: `HW_VOLUME_CTRL` 0x1 and `HW_MUTE_CTRL` 0x10 (def.h:801,815).
* Form factor strings (`device.form_factor`) are listed in proplist.h:212:
  internal, speaker, handset, tv, webcam, microphone, headset, headphone,
  hands-free, car, hifi, computer, portable. The research said UNVERIFIED.
* `device.bus` values (proplist.h:215): isa, pci, usb, firewire, bluetooth.
* `PA_PORT_AVAILABLE_*` 0/1/2 (`def.h`), and the error codes (`def.h:471-498`,
  PA_OK 0, ACCESS 1 ... NOTSUPPORTED 19).
* Balance: the algorithm of `pa_cvolume_get_balance` (volume.c:691-713) is
  implemented. The `on_left` / `on_right` predicates are in volume.c:555-561,
  and they test `PA_CHANNEL_POSITION_MASK_LEFT/RIGHT`, whose definition was not
  found (UNVERIFIED). The implementation uses FRONT_LEFT, FRONT_LEFT_OF_CENTER,
  REAR_LEFT, SIDE_LEFT (and the right-hand equivalents), from the position enum
  order in `channelmap.h`.
* Windows form factor numeric values (research W8, UNVERIFIED): RemoteNetworkDevice
  0 ... DigitalAudioDisplayDevice 9, UnknownFormFactor 10. Verified from the
  windows crate 0.58.0 bindings.
* Windows vtable slots: research W9 (single source) is now confirmed by the
  generated bindings for IMMDeviceEnumerator, IMMDevice, IMMDeviceCollection,
  IMMNotificationClient, IAudioEndpointVolume, IAudioSessionManager2 (with its
  base), IAudioSessionEnumerator, IAudioSessionControl(2), ISimpleAudioVolume,
  IPropertyStore. The IPolicyConfig slots (W9, W10) were not implemented and are
  still unverified.
* Windows IIDs and property keys (research W11-W13 partly): the endpoint and
  session IIDs, the enumerator CLSID and IID, PKEY_Device_FriendlyName (pid 14),
  PKEY_Device_DeviceDesc (pid 2) and PKEY_AudioEndpoint_FormFactor are confirmed
  by the crate.
* macOS selectors (research M10, "not reachable"): the four-character values
  come from the objc2-core-audio 0.3.2 generated bindings
  (`src/generated/AudioHardware.rs`), e.g. kAudioHardwarePropertyDevices
  0x64657623. The values spell the names, which is the only check available.

## 2. Protocol behaviour observed (not in the research)

* PipeWire's pulse server (1.0.5) reports the default sink and source in
  GET_SERVER_INFO as the alias `@DEFAULT_SINK@` / `@DEFAULT_SOURCE@`, and answers
  GET_SINK_INFO with that alias with NOENTITY (error 5). The implementation
  reports no default device in that case (`resolve_default`).
* PulseAudio 16.1 accepts an AUTH with a zero cookie when the module is loaded
  with `auth-anonymous=1`; without it, the cookie file must match.
* A malformed packet makes the server log "protocol error, kicking client" and
  close the connection; the error from the client's side is "peer closed the
  connection" (DISCONNECTED).

## 3. Deviations from the research's model

* `Gain` is used for volume (as the brief asked), but on the **slider scale** of
  each backend (PulseAudio: value / 65536), not as `bleu_core`'s documented
  amplitude ratio (`unit.c3`: "a linear amplification ratio"). The amplitude is
  `gain^3` for PulseAudio (`audio::volume::amplitude`). **Doubt for the lead:**
  either `bleu_core`'s comment for `Gain` should say "slider scale" or a separate
  quantity is needed. No change was made to `bleu_core`.
* No `Volume` typedef (research section 5 option a): `Gain` covers the 0..1.5
  range the research cared about.
* `Device.level` is a `Level` (clamped to nominal). The research's "Level-normalised
  view" is that field.
* `Device.bus` and `FormFactor` are separate: Bluetooth is a bus.
* Streams and devices are re-read in full on every change (one snapshot per
  change), with `publish_snapshot` emitting the diff as events. The research did
  not specify how events are derived; the diff is pure and tested (`changes.c3`).
* PulseAudio events trigger a full refresh (coalesced); the research suggested
  per-object re-reads. Full refresh was chosen for correctness and simplicity;
  the cost is one round of about six queries per change.

## 4. Bug found by the live tests, and its fix

An event that arrives while a refresh is waiting for its reply is consumed by
that wait and only sets `events_seen`. The loop checked the flag after a poll,
which had nothing new to wake on, so the refresh was deferred until the next
command. Fixed with `refresh_until_quiet` (`linux_pulse.c3`). Found because the
mock integration test failed about 80 % of the time; it then passed 12 of 12.

## 5. What was verified how

| Item | How |
| --- | --- |
| Pure codec (framing, tagstruct, requests, records) | 80 `@test` functions (`c3c compile-test`), incl. hand-derived golden bytes (`pulse_test.c3`) and decoders on real replies (`pulse_records_test.c3`, fixtures in `tests/fixtures/`) |
| Real replies | `tests/capture_fixtures.py` sends the handshake and list queries to a live server and saves the replies (PulseAudio 16.1; the card record is synthetic from the mock encoder) |
| Linux backend end-to-end, mock | `tests/run.sh mock`: 48 checks against `tests/pulse_mock.py` (handshake, lists, all setters, events, outage) |
| Linux backend end-to-end, PulseAudio 16.1 | `tests/run.sh real` against a daemon started as user `bleutest` (`--load=module-null-sink`, `auth-anonymous=1`): 11 checks |
| Linux backend end-to-end, PipeWire 1.0.5 | `tests/run.sh real` against pipewire-pulse on PipeWire started as `bleutest` (no sound card): 11 checks |
| Type checking, six targets | `tools/check.sh` (or the equivalent private libdir run); clean on all six |
| macOS, Windows backends | type-checked only (see README) |

Commands run for the Linux checks (abridged): `c3c ... compile-test` for the
unit tests; `libs/bleu_audio.c3l/tests/run.sh mock`; `PULSE_SERVER=unix:<socket>
libs/bleu_audio.c3l/tests/run.sh real`.

## 6. Open doubts

* The macOS and Windows backends have never run. Their correctness rests on the
  generated bindings and on the code's reading of them. Expect first-run bugs.
* `DEVICE_VOLUME` on macOS for a device without a volume control: its volume list
  is empty and a set fails with INVALID_ARGUMENT. Documented, not hidden.
* The research's section 2.3.2 CLSID for IPolicyConfig (`294935CE-...`) disagrees
  with EarTrumpet's (`870AF99C-...`). Not implemented, so not resolved.
* Linux version negotiation: records are decoded with min(35, the server's
  version). The research marked the server-versus-client gating as an inference
  (A6). PulseAudio 16.1 and PipeWire 1.0.5 both report 35, so the case where it
  matters was not exercised.
