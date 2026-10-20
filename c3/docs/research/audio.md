> **CORRECTION (lead, from implementation):** the PulseAudio command numbers quoted in this note are line numbers of native-common.h, not command values (AUTH is 8, GET_SERVER_INFO 20, SUBSCRIBE_EVENT 66 ...). Use the verified table in `audio_impl.md` section 1 instead.

# Audio service research spike

Scope: the `audio` service as a shell mixer needs it: output and input devices
with stable ids, names, form factor and ports; default device get/set; volume
per channel (linear, dB, normalised, over-amplification above 100 %); mute;
balance; per-application streams (playback and record) with app identity,
volume, mute and move; card profiles; device add/remove/change events; a
microphone-in-use indicator; software versus hardware volume. Peak meter is
optional. Spike date 2026-10-20. Read-only: nothing was built or run, and no
sound server, audio device or Windows/macOS host was touched.

Method. Every source was fetched or read on the date above. Raw GitHub URLs
were fetched from `master` and are **not pinned** (the sibling notes do the
same). Local clones were read where present, with their commit given. Source
keys (`[PA-PN]`, `[MS-IAEV]` ...) are defined with URLs in section 3.1. Claim
IDs (`[A7]`) in section 2 are verified in section 4. Tags: `(single-source)` and
`(UNVERIFIED)` as the template requires. Line numbers are the ones read on the
date above; `RS1` is the crate `pulseaudio` 0.1.0 and `RS3` is 0.3.2, and each
line reference says which.

## 1. What a shell needs

Priority order (P0 = the mixer is useless without it).

* P0 Output device list: stable id, description, form factor (speakers,
  headphones, HDMI, bluetooth), default output get and set, hot-plug events.
* P0 Master volume on the default output: per-channel level, dB readout,
  mute, and a boost range above 100 % where the platform allows it.
* P0 Input device list, default input, input volume and mute.
* P0 Per-application playback streams: name, icon, binary, pid, volume, mute,
  move to another output device.
* P0 Microphone-in-use indicator (privacy dot), derived from recording streams.
* P1 Ports ("Speakers" / "Headphones", availability) and card profiles
  (A2DP / HSP / off) on Linux.
* P1 Balance, derived from the channel volumes. No platform checked stores it.
* P1 Per-application recording streams (apps that use the microphone).
* P1 Software versus hardware volume flag, so the UI can explain why a slider
  is inert or capped.
* P2 Peak meter (per device and per stream).

Units the shell must show: the slider percent and dB. Over-amplification
(above 100 %) is shown only where the backend allows it.

## 2. Per-platform native route (Linux / macOS / Windows)

Routes are ranked per feature, first choice first. Each platform ends with its
cut line.

### 2.1 Linux

Recommendation: implement the PulseAudio native protocol as a pure C3 client
over the unix socket. PulseAudio and `pipewire-pulse` both serve it, so one
client covers both servers `[A1]`. Do not build a PipeWire-native client in v1.

#### 2.1.1 Routes per feature

| Feature | Route (ranked) | Interface (exact) | Notes |
| --- | --- | --- | --- |
| Connect and authenticate | 1. Pulse native socket `$XDG_RUNTIME_DIR/pulse/native`; `AUTH` (45), then `SET_CLIENT_NAME` (46) `[PA-NC]:45-46` `[A2]` `[A5]` | | Socket and cookie rules in 2.1.2. |
| Server info, default names | 1. `GET_SERVER_INFO` (58) `[PA-NC]:58`; reply carries `default_sink_name`, `default_source_name` `[PA-PN]:3712-3713` | | Use these as the default ids. |
| Output devices (sinks) | 1. `GET_SINK_INFO_LIST` (60), then `SUBSCRIBE` events `[PA-NC]:60,73` | record layout 2.1.4 `[PA-PN]:3164-3238` | `name` is the stable id; `index` is per server session. |
| Input devices (sources) | 1. `GET_SOURCE_INFO_LIST` (62) `[PA-NC]:62` | `[PA-PN]:3239` (same shape as sinks) | Monitor sources have `monitor_of` set; hide them from the input list. |
| Form factor | 1. proplist `device.form_factor` on the device `[PA-PROP]:212` | string value | Strings are set by the module that owns the device. Value list `(UNVERIFIED)`. |
| Ports and availability | 1. port list in the device record (protocol >= 16, `[PA-PN]:3203-3222`); availability (>= 24, `:3213`); group and type (>= 34, `:3215`) | `PA_PORT_AVAILABLE_UNKNOWN/NO/YES` = 0/1/2 `[PA-DEF]:1060-1062` | Set with `SET_SINK_PORT` (171) / `SET_SOURCE_PORT` (172) `[PA-NC]:171-172`. |
| Card profiles | 1. `GET_CARD_INFO_LIST` (159), `SET_CARD_PROFILE` (160) `[PA-NC]:159-160` | card record `[PA-PN]:3327` | Profile names (e.g. `a2dp-sink`, `headset-head-unit`) come from the module `(UNVERIFIED)`. |
| Default get | 1. `GET_SERVER_INFO` `[PA-PN]:3712-3713` | | |
| Default set | 1. `SET_DEFAULT_SINK` (86) / `SET_DEFAULT_SOURCE` (87) with a name string `[PA-NC]:86-87` `[PA-PN]:4368` | | pipewire-pulse maps this to the `default` metadata (see A24) `[PW-PS]:4843`. |
| Volume get | 1. cvolume in the device record (`u8` channels, `u32` each) `[PA-TS]:299-307` | `pa_volume_t` `[PA-VOL]:117` | Per channel; conversions in 2.1.5. |
| Volume set (device) | 1. `SET_SINK_VOLUME` (75) / `SET_SOURCE_VOLUME` (77), index or name, plus cvolume `[PA-NC]:75,77` `[PA-PN]:3786-3797` | server checks `pa_cvolume_valid` | Accepts up to `PA_VOLUME_MAX`, not only NORM `[PA-PN]:3797` `[PA-VOL]:139`. |
| Mute (device) | 1. `SET_SINK_MUTE` (79) / `SET_SOURCE_MUTE` (80), boolean `[PA-NC]:79-80` `[PA-PN]:3882-3886` | separate boolean | Do not model mute as volume zero. |
| Balance | 1. `pa_cvolume_get_balance` (client helper, `[PA-VOL]:345`), set with `pa_cvolume_set_balance` `[PA-VOL]:347` (body not read) | float -1.0 .. +1.0 `[PA-VOL]:340-344` | Client-side only; the server stores per-channel values. |
| Playback streams (app) | 1. `GET_SINK_INPUT_INFO_LIST` (68) `[PA-NC]:68` | record `[PA-PN]:3402-3443` | Carries proplist, mute (v11), corked (v19), volume-writable (v20). |
| Record streams (app) | 1. `GET_SOURCE_OUTPUT_INFO_LIST` (70) `[PA-NC]:70` | record `[PA-PN]:3445` | Basis of the mic-in-use indicator (2.1.7). |
| App name, icon, binary, pid | 1. proplist on the stream, set by the client: `application.name` [PA-PROP]:144, `application.id` :147, `application.icon_name` :158, `application.process.id` :164, `application.process.binary` :167 | | Client-set, so not security data. `application.id` is the desktop-file id `(single-source: PQT)` `[PQT]:716-722`. |
| Set stream volume | 1. `SET_SINK_INPUT_VOLUME` (76), `SET_SOURCE_OUTPUT_VOLUME` (175, v22) `[PA-NC]:76,175` | index plus cvolume | Stream volume is software, on top of the device volume. |
| Set stream mute | 1. `SET_SINK_INPUT_MUTE` (125, v11) `[PA-NC]:125`; `SET_SOURCE_OUTPUT_MUTE` (176, v22) `[PA-NC]:176` | | |
| Move stream | 1. `MOVE_SINK_INPUT` (121, v10): `u32` stream index, `u32` device index, string device name `[PA-NC]:121` `[PA-PN]:4554-4575` | | Index `-1` with a name moves by name `(UNVERIFIED)`. |
| Events | 1. `SUBSCRIBE` (73) with a mask; server pushes `SUBSCRIBE_EVENT` (116): `u32` event, `u32` index `[PA-PN]:3723-3734` `[A8]` | masks `[PA-DEF]:533-565`; event types `[PA-DEF]:574-618` | No payload. Re-read the changed object after each event. |
| Peak meter | 1. record stream on the sink monitor (design `(UNVERIFIED for the PA flag)`); the same design in Quickshell `[QS-PEAK]:98-128` | | Quickshell uses `PW_KEY_STREAM_MONITOR` and `PW_KEY_STREAM_CAPTURE_SINK`. |
| Hardware or software volume | 1. sink flags: `HW_VOLUME_CTRL` 0x1, `HW_MUTE_CTRL` 0x10, `DECIBEL_VOLUME` 0x20, `FLAT_VOLUME` 0x40 `[PA-DEF]:801-824` | flags field of the device record `[PA-PN]:3186` | `FLAT_VOLUME`: device volume follows the loudest stream `(single-source: RS1 sink_info.rs doc)`. |

**Permissions:** none beyond the cookie. The socket belongs to the user session
and the server checks the peer uid on the unix socket (`pa_pdispatch_creds`,
`[PA-PN]:2613-2615`, when credentials are available). No polkit action is
needed `(UNVERIFIED for pipewire-pulse builds)`. Cookie file mode not read `(UNVERIFIED)`.

**Pitfalls:** `ARCHITECTURE.md` threading rules apply: the socket reader is the
service worker; events come on that socket.

**Cut line (Linux):** ALSA mixer fallback (2.1.8), only when no sound server
answers. It is volume and mute only.

#### 2.1.2 Connection, socket, cookie

Socket discovery `[A2]` `[A3]`:

1. `PULSE_SERVER` environment variable (`ENV_DEFAULT_SERVER`) `[PA-CC]:51`.
2. Per-user runtime socket: `pa_runtime_path("native")` `[PA-CX]:678`, which is
   `$XDG_RUNTIME_DIR/pulse/native` `[PA-CU]:1786-1798`. Without `XDG_RUNTIME_DIR`
   PulseAudio uses another directory `(not read)`.
3. TCP port 4713 is the default `[PA-NC]:200`. Not needed for a local client.

Cookie `[A4]`:

* Environment `PULSE_COOKIE` (`ENV_COOKIE_FILE`) `[PA-CC]:53,177-183`.
* Then the X11 root property (not relevant on Wayland), the application cookie
  file, `client.conf` `cookie-file`, then the default file `cookie`
  `[PA-CC]:169-213`.
* Relative names resolve under the config home: `$XDG_CONFIG_HOME/pulse/` or
  `~/.config/pulse/` `[PA-AK]:134-143` `[PA-CU]:1573,1581`.
* The file is 256 bytes (`PA_NATIVE_COOKIE_LENGTH`) `[PA-NC]:196`. An older
  fallback name `.pulse-cookie` in the home directory `[PA-NC]:198`.
* The server compares the 256 bytes sent with its own cookie `[PA-PN]:2640-2646`.

Happy path `[A5]`:

1. `connect()` to the unix socket (`SOCK_STREAM`).
2. Send `AUTH`: descriptor, then tagstruct `U32 45, U32 tag, U32 version|flags,
   ARBITRARY cookie(256)`. Version 35 with no flags is valid `[PA-CX]:636-660`
   `[PW-DEFS]:27`.
3. Read `REPLY` (2) with the same tag. Payload: `U32 version|flags`
   `[PA-PN]:2709`.
4. Send `SET_CLIENT_NAME` (46): a proplist with `application.name`,
   `application.id`, `application.icon_name` (version >= 13) `[PA-CX]:578-586`.
   Reply: `U32 client index` `[PA-PN]:2785`.
5. Issue `GET_SERVER_INFO`, then the list commands. A list reply is a sequence of
   records with **no count prefix**; read until the tagstruct is at EOF
   `[PA-PN]:3654-3656` `[A31]`.
6. `SUBSCRIBE` with the wanted mask. Keep reading packets: events have tag
   `0xFFFFFFFF`.
7. Stop: `SUBSCRIBE` with mask 0, then close the socket.

Version handling `[A6]`:

* The client sends PA_PROTOCOL_VERSION 35 `[PA-MES]:26` `[PA-CX]:647`.
* The server refuses versions below 8 `[PA-PN]:2582-2585`.
* The server gates replies on the **client's** version `[PA-PN]:2590-2600`. The
  C client gates parsing on the **server's** reply (`context.c:507`, then
  `:522-532`) `[PA-CX]:507,522-532`. The Rust crate `pulseaudio` 0.3.2 takes
  `min(MAX_VERSION, reply)` `[RS3]:lib.rs:127`. Advertise only the version the
  client implements, and decode with `min(advertised, reply)`. The mismatch is
  an inference, not tested `(UNVERIFIED)`.

#### 2.1.3 Packet framing and tagstruct

Frame `[A7]` (integers big-endian):

```
offset 0  u32  length       payload bytes after this 20-byte header
offset 4  u32  channel      0xFFFFFFFF for control (command) packets
offset 8  u32  offset_hi    0 for control packets
offset 12 u32  offset_lo    0 for control packets
offset 16 u32  flags        0 for control packets
```

`[PA-PS]`: descriptor index enum `:55-63`; flag values `:47-53` (`SHMDATA`
0x80000000, `SHMDATA_MEMFD_BLOCK` 0x20000000, `SHMRELEASE` 0x40000000,
`SHMREVOKE` 0xC0000000); control channel `-1` at `:619`; max frame 16 MiB at
`:83`. The Rust crate reads the same five words `[RS1]:protocol.rs:56-70`.

Tagstruct: every value starts with a one-byte type tag `[PA-TH]:36-75`:

| Tag | Byte | Payload | Source |
| --- | --- | --- | --- |
| `PA_TAG_U32` | `L` | `u32` BE | `[PA-TS]:215-218` |
| `PA_TAG_U8` | `B` | `u8` | `[PA-TS]:222` |
| `PA_TAG_U64` | `R` | `u64` BE | `[PA-TS]:269` |
| `PA_TAG_S64` | `r` | `s64` BE | `[PA-TS]:276` |
| `PA_TAG_USEC` | `U` | `u64` BE (microseconds) | `[PA-TS]:262` |
| `PA_TAG_STRING` | `t` | UTF-8, NUL-terminated | `[PA-TS]:205` |
| `PA_TAG_STRING_NULL` | `N` | nothing (NULL string) | `[PA-TS]:209` |
| `PA_TAG_BOOLEAN_TRUE` / `FALSE` | `1` / `0` | nothing | `[PA-TS]:248` |
| `PA_TAG_ARBITRARY` | `x` | `u32` length, bytes | `[PA-TS]:240-244` |
| `PA_TAG_SAMPLE_SPEC` | `a` | `u8` format, `u8` channels, `u32` rate | `[PA-TS]:230-233` |
| `PA_TAG_CHANNEL_MAP` | `m` | `u8` count, then `u8` per channel | `[PA-TS]:286-296` |
| `PA_TAG_CVOLUME` | `v` | `u8` count, then `u32` per channel | `[PA-TS]:299-307` |
| `PA_TAG_VOLUME` | `V` | `u32` | `[PA-TS]:309-313` |
| `PA_TAG_PROPLIST` | `P` | repeated (key as `t`, `u32` length, bytes), ends with `N` | `[PA-TS]:318-335` |

Command header: `U32 command`, `U32 tag` (client counter, incremented per
command) `[PA-CX]:1373-1383`. Reply `REPLY` = 2, error `ERROR` = 0 with a `U32`
error code `[PA-NC]:35-37`.

Pitfall: a proplist may only be at the end of a packet, or not before a
STRING `[PA-TH]:36-38`.

Subscription event packet `[A8]` (server to client, tag `-1`): `U32
SUBSCRIBE_EVENT (116)`, `U32 0xFFFFFFFF`, `U32 event`, `U32 index`
`[PA-PN]:3729-3734`.

#### 2.1.4 Device and stream records

Device record, `sink_fill_tagstruct` `[PA-PN]:3164-3238`, in wire order (the
version gate and the line where it starts):

1. All versions: `U32 index`, `STRING name`, `STRING description`,
   `SAMPLE_SPEC`, `CHANNEL_MAP`, `U32 module`, `CVOLUME volume`, `BOOL muted`,
   `U32 monitor index`, `STRING monitor name`, `USEC latency`, `STRING driver`,
   `U32 flags` `[PA-PN]:3176-3187`.
2. v13 (`:3189`): `PROPLIST`, `USEC requested latency`.
3. v15 (`:3194`): `VOLUME base_volume`, `U32 state` (0 running, 1 idle,
   2 suspended `[PA-DEF]:875-881`), `U32 volume steps`, `U32 card index`.
4. v16 (`:3203`): `U32 port count`, per port `STRING name, STRING description,
   U32 priority`, then v24 (`:3213`) `U32 available` (0 unknown, 1 no, 2 yes),
   v34 (`:3215`) `STRING availability group, U32 type`; then `STRING active port`.
5. v21 (`:3225`): `U8 format count`, then `FORMAT_INFO` per format.

Source record: same shape, `[PA-PN]:3239`. Card record: `[PA-PN]:3327`.

Stream record, `sink_input_fill_tagstruct` `[PA-PN]:3402-3443`: `U32 index,
STRING media.name, U32 module, U32 client, U32 sink index, SAMPLE_SPEC,
CHANNEL_MAP, CVOLUME, USEC latency, USEC sink latency, STRING resample method,
STRING driver`, then v11 `BOOL muted`, v13 `PROPLIST`, v19 `BOOL corked`, v20
`BOOL has_volume, BOOL volume_writable`, v21 `FORMAT_INFO`. Source-output record:
`[PA-PN]:3445`.

Feature gates, from the version comments in `native-common.h` and checked
against the gates above: MOVE_SINK_INPUT v10 `[PA-NC]:120-121`, sink-input mute
v11 `:124-125`, proplists v13 `:143`, card info and profile v15 `:157-160`,
ports v16 `:170-172`, source-output volume and mute v22 `:174-176`, port latency
offset v27 `:178-179`, memfd v31 `:186-188`, port group and type v34 `:190`.

#### 2.1.5 Volume encoding (`pa_volume_t`, `pa_cvolume`)

* `pa_volume_t` is `uint32_t` `[PA-VOL]:117`.
* `PA_VOLUME_NORM` = 0x10000 = 65536 (100 %) `[PA-VOL]:120`.
* `PA_VOLUME_MUTED` = 0 `[PA-VOL]:123`. This is a volume of zero, not the mute flag.
* `PA_VOLUME_MAX` = `UINT32_MAX/2` = 0x7FFFFFFF `[PA-VOL]:126`.
* `PA_VOLUME_IS_VALID(v)` is `v <= PA_VOLUME_MAX` `[PA-VOL]:139`.
* `PA_VOLUME_UI_MAX` = `pa_sw_volume_from_dB(+11.0)` = 99957 (152.5 %)
  `[PA-VOL]:133` (value computed here, same formula).
* Mapping is cubic, not logarithmic `[PA-VOL]:260-291`:
  * `linear = (v / NORM)^3` `[PA-VOL]:290` (`f*f*f`).
  * `v = clamp(lround(cbrt(linear) * NORM), 0, MAX)` `[PA-VOL]:275`.
  * `dB = 20 * log10(linear)` `[PA-VOL]:236`; inverse `linear = 10^(dB/20)` `[PA-VOL]:240`.
  * Combined (derived): `dB = 60 * log10(v / NORM)`.
* Examples (computed here with these formulas):

| Shell percent | `pa_volume_t` | linear | dB |
| --- | --- | --- | --- |
| 0 % | 0 | 0 | -inf (`PA_DECIBEL_MININFTY`) |
| 50 % | 32768 | 0.125 | -18.06 |
| 79.4 % | 52057 | 0.5012 | -6.00 |
| 100 % | 65536 | 1.0 | 0.00 |
| 152.5 % | 99957 | 3.548 | +11.00 (UI max) |

* `PA_VOLUME_MAX` is 3 276 800 % (`2^31-1` over NORM), about +271 dB. Only the UI
  clamps it to +11 dB.
* Shell convention for `Volume` (section 5): `Volume = v / NORM`. Then
  `amplitude = Volume^3` and `dB = 60 * log10(Volume)`.
* Rounding pitfall: the Rust crate truncates (`as u32`) where the C code uses
  `lround`. For linear 0.5 the crate gives 52015 and C gives 52016
  `[RS3]:serde/volume.rs:63-69` `[PA-VOL]:275`.
* Over-amplification: the server accepts values up to `PA_VOLUME_MAX`
  `[PA-PN]:3797`. pamixer clamps to NORM unless `allow-boost` is given
  `[PAMIX]:175-176`. Dank Material Shell clamps to a user setting
  `sinkMaxVolume` `[DMS-AUD]:1624-1634`.

#### 2.1.6 Sink-level facts used by the model

* Mute is independent of volume (`SET_SINK_MUTE` payload is a boolean)
  `[PA-PN]:3882-3886`.
* Flags are in the device record at `[PA-PN]:3186`; the names are in
  `[PA-DEF]:801-832`.
* `DYNAMIC_LATENCY` = 0x0080 `[PA-DEF]:828` (same value in `RS1` `SinkFlags`).

#### 2.1.7 PipeWire native route (note, not recommended for v1)

* pipewire-pulse implements the same wire protocol and advertises
  `PROTOCOL_VERSION` 35 `[PW-DEFS]:25-27` `[PW-PS]:136-146`.
* Default output and input come from the `default` metadata object, keys
  `default.audio.sink` and `default.audio.source`, value a JSON object with
  `name` `[PW-PS]:956-971`. Quickshell reads the same keys and also
  `default.configured.audio.sink` `[QS-DEF]:76-87`.
* Quickshell separates `defaultAudioSink` (in use) from `preferredDefaultAudioSink`
  (the hint that is set) `[QS-QML]:88-113`.
* Recommendation: use the Pulse protocol. A native PipeWire client needs SPA
  pods, node and param enumeration, and metadata. It adds nothing the Pulse
  protocol lacks for this feature list.
* Quickshell maps PipeWire linear channel volumes to the slider with
  `visual = cbrt(linear)` `[QS-NODE]:584-585`, the same cubic convention.

#### 2.1.8 Mic-in-use indicator (Linux)

Design `(UNVERIFIED against a live server)`: the indicator is true when a
**record stream** (source output) from an application exists and is not muted.
Dank Material Shell does this for PipeWire nodes with
`media.class == Stream/Input/Audio`, skips names matching `cava|monitor|system`,
and treats a muted stream as inactive `[DMS-PRIV]:23-45,116-136`. Screen-cast
tools are a separate class there `[DMS-PRIV]:138-166` `(single-source)`. Monitor
captures of a sink are not microphones and must be excluded.

#### 2.1.9 ALSA mixer fallback (cut line)

Route: open `/dev/snd/controlC<n>` and use the control interface, or call
`amixer`. Control names follow the kernel naming rules: `Master`, `Headphone`,
`Speaker`, `Mic`, `Headset Mic`, `Capture` `[KCN]:65-123`. Scope: hardware
volume and mute of one card. Not in scope: per-application streams, default
device semantics, ports as PulseAudio exposes them, or events beyond control
changes.

### 2.2 macOS

Recommendation: CoreAudio HAL through `AudioObjectGetPropertyData` and
`AudioObjectAddPropertyListener`. Check each selector with
`AudioObjectHasProperty` before use `(UNVERIFIED: this call name was not read in
the sources)`.

Important: the Apple documentation pages are JavaScript shells. The JSON behind
them gives **declarations only** for the selectors used here (no discussion text),
so semantics come from implementation code. Numeric four-character values were
not available from any reachable source `(UNVERIFIED)`.

| Feature | Route (ranked) | Selector / call | Evidence |
| --- | --- | --- | --- |
| Enumerate devices | 1. `kAudioHardwarePropertyDevices` on `kAudioObjectSystemObject`, scope global, element main | `[AP-DEV]` decl; used in `[CPAL]:enumerate.rs:21-23`, `[CAR]:macos_helpers.rs:23` | agreed |
| Default output / input | 1. `kAudioHardwarePropertyDefaultOutputDevice`, `kAudioHardwarePropertyDefaultInputDevice`; get with `AudioObjectGetPropertyData`, set with the same selector | decls `[AP-DOUT]`, `[AP-DIN]`; used in `[CPAL]:enumerate.rs:85-87,115-117`, `mod.rs:275-277` | agreed (get). Set path not read `(UNVERIFIED)`. |
| Stable id | 1. `kAudioDevicePropertyDeviceUID` (string) | decl `[AP-UID]`; used in `[CPAL]:device.rs:433-435` | agreed. `AudioDeviceID` not stable across boots `(UNVERIFIED: design assumption)`. |
| Name / description | 1. `kAudioObjectPropertyName` `(UNVERIFIED: not read)` | | |
| Form factor / transport | 1. `kAudioDevicePropertyTransportType` `[AP-TT]`; names `kAudioDeviceTransportTypeBuiltIn`, `...USB` `[CAR]:macos_helpers.rs:678`. Bluetooth and HDMI names `(UNVERIFIED)` | | Map to the form factor in the backend. |
| Scope | 1. `kAudioObjectPropertyScopeInput` / `...Output` / `...Global` `[AP-SCI]` `[CPAL]:device.rs:566,593-597` | | Input and output are scopes of one device. |
| Element | 1. `kAudioObjectPropertyElementMain` (current name) `[CPAL]:device.rs:479`; `kAudioObjectPropertyElementMaster` in `[CAR]:macos_helpers.rs:52` | element 0 is the device `(single-source)` | Both names exist in the crates; Main is the current one. |
| Volume, scalar | 1. `kAudioDevicePropertyVolumeScalar` `[AP-VS]`, per channel; element 0 = main `(UNVERIFIED semantics and range)` | | |
| Volume, dB | 1. `kAudioDevicePropertyVolumeDecibels` `[AP-VDB]`; range `kAudioDevicePropertyVolumeRangeDecibels` `[AP-VRDB]` | | dB and any over-100 % range `(UNVERIFIED whether the range exceeds 0 dB)`. |
| Mute | 1. `kAudioDevicePropertyMute` `[AP-MUTE]` | | |
| Virtual main volume (private route) | | `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` `(UNVERIFIED: no source read)` | 2.2.1 |
| Hardware vs software | 1. property present or not (`AudioObjectHasProperty`) `(UNVERIFIED)`; devices without a volume control (typically HDMI) must report "no property" `(UNVERIFIED)` | | Show as `UNSUPPORTED` in the Cap model. |
| Device events | 1. `AudioObjectAddPropertyListener` on the system object (devices, defaults) and per device (volume, mute, data source) `[CPAL]:property_listener.rs:34` `[CAR]:macos_helpers.rs:779,896` | block variant not verified (`AudioObjectAddPropertyListenerBlock`, page 404) | Remove with `AudioObjectRemovePropertyListener` `[CPAL]:property_listener.rs:6`. |
| Mic in use | 1. `kAudioDevicePropertyDeviceIsRunningSomewhere` on the input device `[AP-RUN]` | | Approximation: other apps, loopback drivers and system sounds also start the device `(UNVERIFIED)`. Background Music's virtual input counts as a microphone `[BGM]:152-161`. |
| Data source (ports-like) | 1. `kAudioDevicePropertyDataSource` / `kAudioDevicePropertyDataSources` `[AP-DS]` | | Internal speakers vs headphones on a built-in device `(UNVERIFIED)`. |
| Per-process audio (capture only) | 1. `AudioHardwareCreateProcessTap` with a `CATapDescription`; empty process list means all processes, exclusive, unmuted `[CPAL]:loopback.rs:92-115` | `kAudioHardwarePropertyProcessObjectList` `[AP-PROC]` `(UNVERIFIED that it enumerates audio-active processes)` | A capture path; cpal uses it for system loopback. No volume control on a tap. |
| Per-application volume | None in the OS `(single-source: the BGM README is the only evidence)` `[BGM]:50-52` | | Third parties install a virtual driver. |

Call sequence (happy path, device volume):

1. `AudioObjectGetPropertyData(kAudioObjectSystemObject, DefaultOutputDevice)` → `AudioDeviceID`.
2. `AudioObjectGetPropertyData(dev, DeviceUID)` → stable id string.
3. `AudioObjectHasProperty(dev, VolumeScalar, scope output, element main)`:
   no → `UNSUPPORTED_NO_HW_VOLUME`; yes → read.
4. `AudioObjectGetPropertyData(dev, VolumeDecibels, ...)` for dB. Fallback:
   compute from the scalar `(UNVERIFIED mapping)`.
5. Listeners: `AudioObjectAddPropertyListener` for `DefaultOutputDevice`,
   `Devices`, and per device `VolumeScalar`, `Mute`, `IsRunningSomewhere`. Keep
   the listener object and remove it on close `[CPAL]:property_listener.rs:14-34`.
6. Stop: remove all listeners; release the tap and aggregate device if used.

Permissions and entitlements:

* Device volume, mute and default selection: no TCC prompt `(UNVERIFIED for the HAL calls)`.
* Process tap and system loopback: an audio-capture permission `(UNVERIFIED: the TCC class)`.
* Background Music asks for microphone access because its virtual input counts
  as a microphone `[BGM]:152-161`. That is the cost of any driver approach.

Pitfalls:

* Callbacks run on a CoreAudio thread. They only enqueue to the mailbox
  `ARCHITECTURE.md` "Threads".
* Element 0 is the device; channel elements are 1, 2, ... `(UNVERIFIED; single-source)`.
* Boost above unity through a driver clips: Background Music warns above 50 %
  `[BGM]:166`.

#### 2.2.1 Private route (marked, not recommended for v1)

`kAudioHardwareServiceDeviceProperty_VirtualMainVolume` through the
AudioHardwareService API, resolved at run time with `bleu::dl`
`(UNVERIFIED: no source read; no OS version observed)`.

Cut line (macOS): no per-application volume in v1; no process tap in v1; no
private route in v1.

### 2.3 Windows

Recommendation: Core Audio (MMDevice, EndpointVolume, SessionManager2) on one
MTA worker thread. Everything here is documented except default-device
selection, which needs the undocumented `IPolicyConfig` (2.3.2).

| Feature | Route (ranked) | Interface (exact) | Notes |
| --- | --- | --- | --- |
| Enumerate endpoints | 1. `IMMDeviceEnumerator::EnumAudioEndpoints(dataFlow, dwStateMask)` `[MS-EAE]`, mask `DEVICE_STATE_ACTIVE` (or `DEVICE_STATEMASK_ALL`) | `EDataFlow`: `eRender` 0, `eCapture` 1, `eAll` 2 `[MS-EDF]` | Enumerator CLSID `{BCDE0395-E52F-467C-8E3D-C4579291692E}` `(single-source: ET-ENUM)`. |
| Stable id | 1. `IMMDevice::GetId` (opaque, persistent) `[MS-GETID]` | endpoint ID string | Treat as opaque; reopen with `IMMDeviceEnumerator::GetDevice`. |
| Name | 1. `PKEY_Device_FriendlyName`, `PKEY_DeviceInterface_FriendlyName`, `PKEY_Device_DeviceDesc` via `IPropertyStore` `[MS-DEVPROP]` `[WASAPI]:api.rs:36` | | |
| Form factor | 1. `PKEY_AudioEndpoint_FormFactor` `[MS-PKEY-FF]` | enum names in order: RemoteNetworkDevice, Speakers, LineLevel, Headphones, Microphone, Headset, Handset, UnknownDigitalPassthrough, SPDIF, HDMI, UnknownFormFactor `[MS-PKEY-FF]` | Numeric values `(UNVERIFIED: devicetopology.h not fetched)`. |
| Default get | 1. `IMMDeviceEnumerator::GetDefaultAudioEndpoint(dataFlow, role)` `[MS-GDAE]` | `ERole`: eConsole 0, eMultimedia 1, eCommunications 2 `[MS-ROLE]` | |
| Default set | 1. private `IPolicyConfig` (2.3.2) | | Single-source `[ET-IPC]:23`. |
| Master volume | 1. `IAudioEndpointVolume` from `IMMDevice::Activate(IID_IAudioEndpointVolume)` `[MS-ACT]`; `GetMasterVolumeLevelScalar`, `SetMasterVolumeLevelScalar`, `GetMute`, `SetMute` `[MS-IAEV]` | scalar 0.0..1.0, audio-tapered `[MS-IAEV]` | Out of range → `E_INVALIDARG` `[MS-SMV]`. No boost above 100 % through the scalar. |
| Master volume in dB | 1. `GetVolumeRange`, `GetMasterVolumeLevel`, `GetChannelVolumeLevel` (dB) `[MS-IAEV]` | range is driver-dependent `[MS-IAEV]` | Boost only if the driver's dB range goes above 0 dB `(UNVERIFIED)`. |
| Channel volume | 1. `GetChannelCount`, `GetChannelVolumeLevelScalar`, `SetChannelVolumeLevelScalar` `[MS-IAEV]` | | Balance derived from these. |
| Hardware support | 1. `IAudioEndpointVolume::QueryHardwareSupport` `[MS-IAEV]` | bit meaning not read `(UNVERIFIED)` | Source of the HW-volume flag. |
| Per-application sessions | 1. `IAudioSessionManager2` (`Activate(IID_IAudioSessionManager2)`) → `GetSessionEnumerator` → `IAudioSessionControl2` `[MS-SM2]` `[MS-SC2]` `[WVC]:lib.rs:106-107,121` | | Documented. |
| App pid | 1. `IAudioSessionControl2::GetProcessId` `[MS-SC2]` `[WVC]:lib.rs:130` | | `IsSystemSoundsSession` `[MS-SC2]`. |
| App volume and mute | 1. `ISimpleAudioVolume`, cast from the session control `[WVC]:lib.rs:161` | session master volume = highest channel `[MS-IAEV]` (quoted text of `ISimpleAudioVolume::GetMasterVolume`) | Page `ISimpleAudioVolume` returned 404 `(not read)`. |
| App name, icon | 1. `IAudioSessionControl::GetDisplayName`, `GetIconPath` (inherited) `(UNVERIFIED: page not fetched)` | | |
| Session move to another output | 1. private `IAudioPolicyConfigFactory` persisted default (2.3.2) `(single-source)` `[ET-FAC]:5-9` | | Private. |
| Peak meter | 1. `IAudioMeterInformation` on the endpoint: `GetPeakValue`, `GetChannelsPeakValues`, `QueryHardwareSupport` `[MS-IAMI]` | normalised 0.0..1.0 `[MS-IAMI]` | Software meter reports 0 in exclusive mode `[MS-IAMI]`. |
| Device events | 1. `IMMNotificationClient` (5 callbacks) registered on the enumerator `[MS-IMMN]` `[MS-REGC]` | `OnDeviceAdded`, `OnDeviceRemoved`, `OnDeviceStateChanged`, `OnPropertyValueChanged`, `OnDefaultDeviceChanged` `[MS-IMMN]` | Must not block; must not call Register/Unregister inside a callback `[MS-IMMN]`. |
| Volume change events | 1. `IAudioEndpointVolume::RegisterControlChangeNotify` `[MS-IAEV]` | | |
| New session events | 1. `IAudioSessionNotification::OnSessionCreated` via `RegisterSessionNotification` `[MS-SNOT]` `[MS-SM2]` | | Needs MTA; without it the app gets no notifications `[MS-SNOT]`. |
| Mic in use | 1. capture sessions from `IAudioSessionManager2` on the capture endpoint `(UNVERIFIED: session-state getter not read)` | | Endpoint peak > 0 as a heuristic `(design)`. |

Call sequence (happy path and stop):

1. `CoInitializeEx(NULL, COINIT_MULTITHREADED)` on the worker thread `[MS-SNOT]`.
2. Create `IMMDeviceEnumerator` (CLSID above) `[MS-IMDE]`.
3. `RegisterEndpointNotificationCallback(client)` `[MS-REGC]`.
4. `EnumAudioEndpoints(eAll, DEVICE_STATEMASK_ALL)` `[MS-EAE]`. For each device:
   `GetId` `[MS-GETID]`; `OpenPropertyStore` and read the PKEYs `[MS-DEVPROP]`;
   `Activate(IID_IAudioEndpointVolume)` `[MS-ACT]`; read mute and volume;
   `RegisterControlChangeNotify` `[MS-IAEV]`.
5. `GetDefaultAudioEndpoint(flow, role)` for each flow and role `[MS-GDAE]` `[MS-ROLE]`.
6. `Activate(IID_IAudioSessionManager2)` on the render endpoint; `RegisterSessionNotification` `[MS-SM2]`; `GetSessionEnumerator`; per session `QueryInterface` to `IAudioSessionControl2`, `GetProcessId` `[MS-SC2]`, cast to `ISimpleAudioVolume` `[WVC]:lib.rs:161`.
7. Stop: `UnregisterSessionNotification`, `UnregisterControlChangeNotify`, then `UnregisterEndpointNotificationCallback` from the worker thread, never from a callback `[MS-IMMN]`; `Release` all interfaces.

Permissions: none beyond COM initialisation `(UNVERIFIED: no admin right or UAC prompt checked)`.

#### 2.3.2 Undocumented default-device route (private, marked)

`IPolicyConfig` / `IPolicyConfigVista` is not documented by Microsoft. Source for
the interface shape: EarTrumpet `[ET-IPC]`, `[ET-PCC]`, `[ET-FAC]`. The brief
names the CLSID `{294935CE-F637-4E7C-A41B-AB255460B862}`. EarTrumpet's
`PolicyConfigClient` uses CLSID `{870AF99C-171D-4F9E-AF0D-E63DF40C2BC9}`
`[ET-PCC]:7`. **This is a discrepancy.** The `294935CE` value is `(UNVERIFIED)`.

Interface IIDs written in EarTrumpet's comments `[ET-IPC]:6-9`:

| Build (per EarTrumpet comment) | IID |
| --- | --- |
| W10_TH1 | `{CA286FC3-91FD-42C3-8E9B-CAAFA66242E3}` |
| W10_TH2 | `{6BE54BE8-A068-4875-A49D-0C2966473B11}` |
| Win7-Win8, W10_RS1 to present | `{F8679F50-850A-41CF-9C72-430F290290C8}` (`IPolicyConfigWin7`) |

Method table of `IPolicyConfigWin7` `[ET-IPC]:11-24`. Vtable slots are 0-based
with `IUnknown` at 0-2; slot numbers computed here:

| Slot | Method | Use |
| --- | --- | --- |
| 3-10 | `Unused1` .. `Unused8` | do not call |
| 11 | `GetPropertyValue(wszDeviceId, &key, &pv)` | not needed |
| 12 | `SetPropertyValue(wszDeviceId, &key, &pv)` | not needed |
| 13 | `SetDefaultEndpoint(wszDeviceId, ERole)` | default selection |
| 14 | `SetEndpointVisibility(wszDeviceId, short)` | not needed |

Pitfalls: the slot numbers come from one source `(single-source)`. The brief says
they differ by Windows version; EarTrumpet gives one table for one IID family,
so version differences are `(UNVERIFIED)`. The per-app persisted default uses
`IAudioPolicyConfigFactory`: `SetPersistedDefaultAudioEndpoint(pid, flow, role,
deviceId)`, `GetPersistedDefaultAudioEndpoint`, `ClearAllPersistedApplicationDefaultEndpoints`
`[ET-FAC]:5-9`. EarTrumpet's copy of that interface has **no GUID attribute**
in the file, so the IIDs `{2a59116d-...}` and `{ab3d4648-...}` named in the
brief are `(UNVERIFIED)`.

Recommendation: keep this in a separate `*_private.c3` file, resolved with
`bleu::dl`, behind `Cap.DEFAULT_SET`, with the source cited at the top
(`ARCHITECTURE.md`, "Hidden and undocumented OS APIs").

Cut line (Windows): default-device set and per-app persisted routing are private;
leave them out of v1 unless approved. Everything else is documented.

## 3. Reference implementations (prove it works)

Read status: "code" means the file was opened and the cited lines were read.
"README" means only the README was read. "not read" means not used.

| Key | Project | Lang | Location | Read? | Copy the idea of |
| --- | --- | --- | --- | --- | --- |
| PA-* | PulseAudio | C | section 3.1 | code (all cited) | wire protocol, server behaviour |
| RS3 | `pulseaudio` 0.3.2 (newest pure-Rust native protocol) | Rust | `static.crates.io/crates/pulseaudio/pulseaudio-0.3.2.crate` | code: `src/protocol.rs:20,26`, `src/lib.rs:127`, `src/protocol/command/auth.rs:7-9`, `src/protocol/serde/volume.rs:63-69` | version constants, negotiation, volume rounding |
| RS1 | `pulseaudio` 0.1.0 (base of the previous attempt's fork) | Rust | `static.crates.io/crates/pulseaudio/pulseaudio-0.1.0.crate` | code: `src/protocol.rs:56-70,81-88,194-201`, `src/protocol/command/sink_info.rs:224-300`, `src/protocol/serde.rs:30-46`, `src/protocol/serde/volume.rs:13-15,45-56,92-101` | framing, sink decode order, tag bytes (0.1.0 line numbers) |
| PW-* | PipeWire pipewire-pulse | C | section 3.1 | code (cited lines) | the second server; `default` metadata; version mask |
| QS-* | Quickshell PipeWire service | C++ | local clone `/home/user/quickshell-mirror/quickshell` at `2b4501a282689792b62e94f3fb30d8f512324fe6`, `src/services/pipewire/{defaults.cpp, node.cpp, peak.cpp, qml.hpp}` | code (cited ranges) | default vs preferred; cbrt mapping; peak monitor stream |
| DMS-* | DankMaterialShell (Quickshell QML) | QML | local clone `/home/user/avengemedia/dankmaterialshell` at `8be08999caf74878179434a980420a9ed5008b03`, `quickshell/Services/{PrivacyService.qml, AudioService.qml, PipewireAudioBackend.qml}` | code (cited ranges; AudioService partly) | mic-active heuristic, volume clamp, default device |
| PAMIX | pamixer | C++ | section 3.1 | code (partial) | boost clamp unless allowed |
| PQT | pulseaudio-qt (KDE) | C++ | section 3.1 | code (partial) | subscribe mask; client proplist |
| CPAL | cpal 0.18.2 (CoreAudio host) | Rust | `static.crates.io/crates/cpal/cpal-0.18.2.crate`, `src/host/coreaudio/macos/{enumerate.rs, device.rs, mod.rs, loopback.rs, property_listener.rs}` | code (partial) | HAL selectors, scopes, listeners, process tap |
| CAR | coreaudio-rs 0.14.2 | Rust | `static.crates.io/crates/coreaudio-rs/coreaudio-rs-0.14.2.crate`, `src/audio_unit/macos_helpers.rs` | code (partial) | element Master; transport names |
| CSYS | coreaudio-sys 0.2.18 | Rust | `static.crates.io/crates/coreaudio-sys/coreaudio-sys-0.2.18.crate`, `build.rs` | code (`build.rs` only; bindings are generated at build time, so no constants) | which SDK headers the names come from |
| BGM | Background Music (macOS) | README | section 3.1 | README | per-app volume via a virtual driver; mic-permission side effect; clipping |
| SWA | SwitchAudioSource (switchaudio-osx) | README | section 3.1 | README | CLI semantics for the output and input types and mute |
| WVC | windows-volume-control 0.1.1 | Rust | `static.crates.io/crates/windows-volume-control/windows-volume-control-0.1.1.crate`, `src/lib.rs` | code (partial). `session.rs` names the endpoint interface where the session one is meant | session enumeration and pid |
| WASAPI | wasapi 0.26.0 | Rust | `static.crates.io/crates/wasapi/wasapi-0.26.0.crate`, `src/events.rs:404-417`, `src/api.rs:36` | code (partial) | notification client; PKEY names |
| ET-* | EarTrumpet | C# | section 3.1 | code (4 files) | default-device route, IIDs, enumerator CLSID |
| SoundSwitch | SoundSwitch | C# | README via section 3.1; source paths guessed, 404 | README | (source not reached) |
| AudioDeviceCmdlets | cdhunt/AudioDeviceCmdlets | C# | paths guessed, 404 | not read | (not reached) |
| cubeb | mozilla/cubeb | C++ | `src/cubeb_coreaudio.cpp` 404 on `master` | not read | (not reached) |
| wayle | wayle, previous attempt's fork | Rust | `scratchpad/rust_prev/desktop-systems/forks/wayle-services` | not read for audio | (not read) |
| plasma-pa, libpulse-binding, cpvc, volumecontrol | | | not attempted | not read | (not read) |

Previous attempt. `scratchpad/rust_prev/desktop-systems/forks/pulseaudio` was
listed, not read. `research/pulseaudio.json` is crates.io search metadata
(download counts, no code), so it was not used as evidence. The version
conclusion (0.3.2 is the newest crate) comes from the crate index.

### 3.1 Source keys (URLs)

PulseAudio, `https://raw.githubusercontent.com/pulseaudio/pulseaudio/master/`:
`PA-NC` = `src/pulsecore/native-common.h`; `PA-PN` = `src/pulsecore/protocol-native.c`;
`PA-CX` = `src/pulse/context.c`; `PA-TS` = `src/pulsecore/tagstruct.c`;
`PA-TH` = `src/pulsecore/tagstruct.h`; `PA-PS` = `src/pulsecore/pstream.c`;
`PA-VOL` = `src/pulse/volume.h` (lines 117, 120, 123, 126, 133, 139, 340-347) and `src/pulse/volume.c` (lines 236, 240, 243-248, 260-291), told apart by these line sets;
`PA-DEF` = `src/pulse/def.h`; `PA-PROP` = `src/pulse/proplist.h`;
`PA-CC` = `src/pulse/client-conf.c`; `PA-AK` = `src/pulsecore/authkey.c`;
`PA-CU` = `src/pulsecore/core-util.c`; `PA-MES` = `meson.build`.

PipeWire: `PW-DEFS` = `https://gitlab.freedesktop.org/pipewire/pipewire/-/raw/master/src/modules/module-protocol-pulse/defs.h`;
`PW-PS` = the same directory, `pulse-server.c` (and `pulse-server.h:16-18` for the socket name).

Rust crates: `RS1` = `pulseaudio-0.1.0.crate`, `RS3` = `pulseaudio-0.3.2.crate`
(both from `static.crates.io/crates/pulseaudio/`). `CPAL`, `CAR`, `CSYS`, `WVC`,
`WASAPI` are in section 3.

Other code: `PAMIX` = `https://raw.githubusercontent.com/cdemoulins/pamixer/master/src/pamixer.cc`;
`PQT` = `https://raw.githubusercontent.com/KDE/pulseaudio-qt/master/src/context.cpp`;
`ET-IPC` / `ET-PCC` / `ET-FAC` / `ET-ENUM` = `https://raw.githubusercontent.com/File-New-Project/EarTrumpet/master/EarTrumpet/Interop/MMDeviceAPI/{IPolicyConfig.cs, PolicyConfigClient.cs, IAudioPolicyConfigFactory.cs, MMDeviceEnumerator.cs}`;
`BGM` = `https://raw.githubusercontent.com/kyleneideck/BackgroundMusic/master/README.md`;
`SWA` = `https://raw.githubusercontent.com/deweller/switchaudio-osx/master/README.md`;
`KCN` = `https://docs.kernel.org/sound/designs/control-names.html`;
`ARCH` = `/home/user/BleuKit/c3/docs/ARCHITECTURE.md`.

Microsoft Learn (all `https://learn.microsoft.com/en-us/windows/win32/`):

| Key | Page |
| --- | --- |
| MS-IMMN | `api/mmdeviceapi/nn-mmdeviceapi-immnotificationclient` |
| MS-IMDE | `api/mmdeviceapi/nn-mmdeviceapi-immdeviceenumerator` |
| MS-EAE | `api/mmdeviceapi/nf-mmdeviceapi-immdeviceenumerator-enumaudioendpoints` |
| MS-GDAE | `api/mmdeviceapi/nf-mmdeviceapi-immdeviceenumerator-getdefaultaudioendpoint` |
| MS-REGC | `api/mmdeviceapi/nf-mmdeviceapi-immdeviceenumerator-registerendpointnotificationcallback` |
| MS-EDF | `api/mmdeviceapi/ne-mmdeviceapi-edataflow` |
| MS-ROLE | `api/mmdeviceapi/ne-mmdeviceapi-erole` |
| MS-ACT | `api/mmdeviceapi/nf-mmdeviceapi-immdevice-activate` |
| MS-GETID | `api/mmdeviceapi/nf-mmdeviceapi-immdevice-getid` |
| MS-IAEV | `api/endpointvolume/nn-endpointvolume-iaudioendpointvolume` |
| MS-SMV | `api/endpointvolume/nf-endpointvolume-iaudioendpointvolume-setmasterVolumelevelscalar` |
| MS-IAMI | `api/endpointvolume/nn-endpointvolume-iaudiometerinformation` |
| MS-SM2 | `api/audiopolicy/nn-audiopolicy-iaudiosessionmanager2` |
| MS-SC2 | `api/audiopolicy/nn-audiopolicy-iaudiosessioncontrol2` |
| MS-SNOT | `api/audiopolicy/nn-audiopolicy-iaudiosessionnotification` |
| MS-PKEY-FF | `coreaudio/pkey-audioendpoint-formfactor` |
| MS-DEVPROP | `coreaudio/device-properties` |

Apple (declarations): `https://developer.apple.com/tutorials/data/documentation/coreaudio/<name>.json`,
where `<name>` is the lower-case selector: `AP-DEV` = `kaudiohardwarepropertydevices`;
`AP-DOUT` = `kaudiohardwarepropertydefaultoutputdevice`; `AP-DIN` =
`kaudiohardwarepropertydefaultinputdevice`; `AP-UID` = `kaudiodevicepropertydeviceuid`;
`AP-TT` = `kaudiodevicepropertytransporttype`; `AP-SCI` = `kaudioobjectpropertyscopeinput`;
`AP-VS` = `kaudiodevicepropertyvolumescalar`; `AP-VDB` = `kaudiodevicepropertyvolumedecibels`;
`AP-VRDB` = `kaudiodevicepropertyvolumerangedecibels`; `AP-MUTE` =
`kaudiodevicepropertymute`; `AP-DS` = `kaudiodevicepropertydatasource`; `AP-RUN` =
`kaudiodevicepropertydeviceisrunningsomewhere`; `AP-PROC` =
`kaudiohardwarepropertyprocessobjectlist`. Human page: `https://developer.apple.com/documentation/coreaudio/<name>`.

## 4. Double validation

Each row is a claim with its two sources. `(single-source)` and `(UNVERIFIED)`
are as the template requires.

| ID | Claim | Source A | Source B | Status |
| --- | --- | --- | --- | --- |
| A1 | PulseAudio and pipewire-pulse share protocol version 35 | PA-MES:26 | PW-DEFS:27 | agreed |
| A2 | Socket is `$XDG_RUNTIME_DIR/pulse/native` | PA-CU:1786-1798, PA-CX:678 | PW-PS (name `native`, pulse-server.h:16) | agreed on the name; directory from PA-CU only |
| A3 | Socket discovery order: `PULSE_SERVER`, then runtime socket | PA-CC:51, PA-CX:678 | (order not read in a second source) | (single-source) on order |
| A4 | Cookie: `PULSE_COOKIE`, then `cookie` under config home, 256 bytes | PA-CC:53,169-213; PA-AK:134-143; PA-CU:1573,1581; PA-NC:196 | RS1 `auth.rs:23` comment (`~/.pulse-cookie`) | agreed on the file; fallback name differs |
| A5 | AUTH is `U32 45, U32 tag, U32 version|flags, ARBITRARY cookie`; reply `U32 version|flags`; then SET_CLIENT_NAME with proplist, reply `U32 client index` | PA-CX:578-586, 636-660; PA-PN:2709, 2785 | RS1 `auth.rs:28-35,41-47`; RS1 `set_client_name.rs:16,27` | agreed |
| A6 | Version gating: server by client's version, C client by server's reply, crate by min | PA-PN:2590-2600; PA-CX:507,522-532 | RS3 `lib.rs:127` (min) | **conflict in approach**; interop risk `(UNVERIFIED)` |
| A7 | Frame header: 5 big-endian u32 words; channel -1 for control | PA-PS:55-63, 619 | RS1 `protocol.rs:56-70, 81-88` | agreed |
| A8 | Subscribe event packet: `U32 116, U32 -1, U32 event, U32 index` | PA-PN:3729-3734 | RS1 `protocol.rs:194-201` (`read_subscription_event`) | agreed on shape |
| A9 | Tag bytes (`L`, `t`, `N`, `v`, `P`, `x`, ...) | PA-TH:36-75 | RS1 `serde.rs:30-46` (same bytes) | agreed |
| A10 | cvolume is `u8` count + `u32` each; volume is `V` + `u32` | PA-TS:299-313 | RS1 `serde/volume.rs:92-101` (Volume read/write) | agreed on Volume; cvolume layout not read in RS1 `(single-source)` |
| A11 | `PA_VOLUME_NORM` = 0x10000; `PA_VOLUME_MAX` = `UINT32_MAX/2`; `MUTED` = 0 | PA-VOL:117-126 | RS3 `serde/volume.rs` (`VOLUME_NORM`, `VOLUME_MAX`); RS1 `serde/volume.rs:13-15` | agreed |
| A12 | Linear = cube of the volume; dB = 20 log10 | PA-VOL:236, 278-291 | QS-NODE:584-585 (`cbrt`); RS1 `serde/volume.rs:53-56` (to_linear), `:45-50` (to_db) | agreed |
| A13 | `from_linear` rounds with `lround` | PA-VOL:275 | RS1 and RS3 `as u32` (truncation) | **conflict** (1-unit difference: 0.5 gives 52015 vs 52016); C followed |
| A14 | `PA_VOLUME_UI_MAX` = +11 dB | PA-VOL:133 | (none read) | (single-source) |
| A15 | Server accepts volumes above NORM (up to MAX) | PA-PN:3797 (`pa_cvolume_valid`), PA-VOL:139 | PAMIX:175-176 (a client choice), DMS-AUD:1624-1634 (a client setting) | agreed |
| A16 | Mute is separate from volume | PA-PN:3882-3886 (boolean payload) | RS1 `sink_info.rs` (`muted: bool` beside `cvolume`) | agreed |
| A17 | Sink flags: HW_VOLUME_CTRL 0x1, HW_MUTE 0x10, DECIBEL 0x20, FLAT 0x40, DYNAMIC_LATENCY 0x80 | PA-DEF:801-828 | RS1 `sink_info.rs` `SinkFlags` (same values) | agreed |
| A18 | `FLAT_VOLUME`: device follows the loudest stream | RS1 `sink_info.rs` doc comment | PA-DEF:824 (flag only; meaning not read) | (single-source) |
| A19 | Sink state RUNNING 0, IDLE 1, SUSPENDED 2 | PA-DEF:875-881 | RS1 `sink_info.rs` `SinkState` | agreed |
| A20 | Port availability 0/1/2 (unknown/no/yes), from v24 | PA-DEF:1060-1062; PA-PN:3213 (gate) | RS1 `sink_info.rs` `PortAvailable` (same values) | agreed |
| A21 | Ports from v16; `SET_SINK_PORT` is command 171 | PA-PN:3203-3222; PA-NC:170-172 | RS1 `sink_info.rs` (`>= 16`) | agreed |
| A22 | Card info and profile commands from v15 (159/160) | PA-NC:159-160; PA-PN:3327 | PW-PS:4409,4614,5507 (cards, profile) | agreed |
| A23 | `default.audio.sink` metadata value is JSON with `name` | PW-PS:956-968 | QS-DEF:76-87 (same keys) | agreed |
| A24 | pipewire-pulse maps SET_DEFAULT_SINK to the metadata | PW-PS:4843 (handler); PW-PS:4994 comment says the metadata is updated after SET_DEFAULT | QS-DEF reads the same metadata | agreed on the read path; the write path is from the comment, handler body not read `(single-source)` |
| A25 | Default PipeWire sink is `defaultAudioSink`; preferred is a hint | QS-QML:88-113 | (none read) | (single-source) |
| A26 | Peak meter as a monitor capture stream | QS-PEAK:98-128 | (no PA equivalent read) | (single-source) |
| A27 | PA record-stream peak detection flag | (not read) | (not read) | (UNVERIFIED) |
| A28 | Mic-in-use heuristic on `Stream/Input/Audio` with a name filter | DMS-PRIV:23-45, 116-136 | (design) | (single-source) |
| A29 | Proplist keys (`application.name` ...) | PA-PROP:144-223 | PQT:716-722 (client sets the same keys) | agreed |
| A30 | Subscription masks and event types | PA-DEF:533-618 | PQT:496-498 (mask uses SINK, SOURCE, CARD, SERVER, INPUT, OUTPUT) | agreed |
| A31 | List reply has no count; read until EOF | PA-PN:3654-3656 | (RS3 not read for lists) | (single-source) |
| A32 | Server compares the 256-byte cookie | PA-PN:2640-2646 | (not read) | (single-source) |
| A33 | Auth on the unix socket by peer uid (creds build) | PA-PN:2607-2615 | (not read) | (single-source) |
| W1 | Endpoint notification client is non-blocking and must not Register/Unregister inside callbacks | MS-IMMN page text | WASAPI `events.rs:404-417` (implementation of the interface) | agreed |
| W2 | Endpoint scalar range 0..1; `E_INVALIDARG` outside | MS-SMV page text | MS-IAEV page text (0..1 range) | agreed |
| W3 | Session master volume is the highest channel | MS-IAEV page text (quoted `ISimpleAudioVolume::GetMasterVolume`) | WVC `lib.rs:161` (uses `ISimpleAudioVolume`) | agreed |
| W4 | Session enumeration then `IAudioSessionControl2::GetProcessId` | MS-SC2 page text | WVC `lib.rs:106-107,121,130` | agreed |
| W5 | MTA needed for session notifications | MS-SNOT page text | (not read) | (single-source) |
| W6 | `EDataFlow` values `eRender` 0, `eCapture` 1, `eAll` 2 | MS-EDF page text | (not read) | (single-source) |
| W7 | `ERole` values 0, 1, 2 | MS-ROLE page text | (not read) | (single-source) |
| W8 | Form factor enum names (11 values, in order) | MS-PKEY-FF page text | (not read) | (single-source); numeric values UNVERIFIED |
| W9 | `IPolicyConfigWin7` IID `{F8679F50-...}`; `SetDefaultEndpoint` at slot 13 | ET-IPC:9,11-24 (slot computed) | (no second source) | (single-source) |
| W10 | CLSID of PolicyConfigClient `{870AF99C-...}` | ET-PCC:7 | brief names `{294935CE-...}` | **conflict** with the brief; `294935CE` UNVERIFIED |
| W11 | `IAudioPolicyConfigFactory` IIDs `{2a59116d-...}` / `{ab3d4648-...}` | ET-FAC has no GUID attribute | (not read) | (UNVERIFIED) |
| W12 | `IMMDevice::GetId` is opaque and persistent | MS-GETID page text | WASAPI `api.rs` (opens devices by ID) `(not separately read)` | agreed |
| W13 | Enumerator CLSID `{BCDE0395-...}` | ET-ENUM:6-7 | (not read) | (single-source) |
| M1 | Devices, default in/out, DeviceUID, TransportType names exist | AP-DEV, AP-DOUT, AP-DIN, AP-UID, AP-TT (declarations) | CPAL `enumerate.rs`, `device.rs:433-435`; CAR `macos_helpers.rs:678` (names used) | agreed |
| M2 | VolumeScalar, VolumeDecibels, Mute, DataSource, IsRunningSomewhere, ProcessObjectList names exist | AP-VS, AP-VDB, AP-MUTE, AP-DS, AP-RUN, AP-PROC (declarations) | (not used in the code read) | (single-source) |
| M3 | Element names `Main` and `Master` | CPAL `device.rs:479` (Main) | CAR `macos_helpers.rs:52` (Master) | agreed (both names exist; Main is current) |
| M4 | Process tap with an empty process list covers all processes | CPAL `loopback.rs:92-98` | (no second source) | (single-source) |
| M5 | Listeners via `AudioObjectAddPropertyListener` | CPAL `property_listener.rs:34` | CAR `macos_helpers.rs:779,896` | agreed |
| M6 | No per-application volume in the OS; a driver is needed | BGM README:50-52 | (no Apple source) | (single-source) |
| M7 | Driver virtual input counts as a microphone (TCC) | BGM README:152-161 | (no Apple source) | (single-source) |
| M8 | Driver boost above 50 % clips | BGM README:166 | (none) | (single-source) |
| M9 | `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` | (page 404) | (no crate) | (UNVERIFIED) |
| M10 | Numeric four-character selector values | (not reachable) | (not reachable) | (UNVERIFIED) |
| K1 | ALSA control names `Master`, `Headphone`, `Mic`, `Capture` | KCN:65-123 | (not read) | (single-source) |

## 5. Proposed Bleu model

A draft in the style of `ARCHITECTURE.md`. Not compiled. Check with
`tools/check.sh` before use. One decision is open (the quantity type).

**Quantity type.** `bleu_core` `Level` is clamped to 0.0 ..= 1.0
(`libs/bleu_core.c3l/src/unit.c3:16-27`). The brief asks for volume above
100 %, so `Level` cannot carry it. Options: (a) a new `typedef Volume = float;`
in `bleu::audio` with range 0.0 .. 1.5 (the UI maximum of +11 dB is 1.525),
with `Level` as the 0..1 view; (b) add a `Gain` quantity to `bleu_core`.
**Lead decision needed.** Implementers must not change `bleu_core` (brief).

Semantics per backend. This is the honest part:

| Backend | `Volume` value | amplitude | dB source | Above 1.0 possible? |
| --- | --- | --- | --- | --- |
| PulseAudio native | `pa_volume_t / 65536` (cube-root slider) | `Volume^3` | derived `60*log10(Volume)` | yes, up to 32768 (server) |
| CoreAudio | `VolumeScalar` (0..1 `(UNVERIFIED)`) | unknown | `VolumeDecibels` when present | no, unless the dB range says so `(UNVERIFIED)` |
| WASAPI endpoint | scalar 0..1, audio-tapered `[MS-IAEV]` | unknown | `GetVolumeRange`, `GetChannelVolumeLevel` | no for the scalar; dB range is driver-dependent |

Because the three slider scales differ, `Volume` means "slider position on the
backend's own scale", and `dB` is the portable number to show. The public
`<* *>` comments must say so.

```c3
module bleu::audio;
import bleu::unit, bleu::availability, bleu::observe, bleu::stream, bleu::operation;

typedef Volume = float;              // slider position; 1.0 = nominal 100 %; backend scale (see docs)
typedef Decibel = float;             // dB; silence is DECIBEL_MIN (the real floor is PA_DECIBEL_MININFTY)
const Decibel DECIBEL_MIN = (Decibel)-150.0f;

enum Flow : char { OUTPUT, INPUT }
enum FormFactor : char
{
    UNKNOWN, SPEAKERS, HEADPHONES, HEADSET, HANDSET, MICROPHONE,
    HDMI, DISPLAYPORT, BLUETOOTH, LINE_LEVEL, DIGITAL_PASSTHROUGH, SPDIF, REMOTE_NETWORK,
}
enum PortAvail : char { UNKNOWN, NO, YES }

struct Port { String name; String description; PortAvail available; bool available_known; }
struct Device
{
    String id;                       // stable: PA sink name | WASAPI endpoint ID | CoreAudio UID
    String name;
    String description;
    Flow flow;
    FormFactor form_factor;
    Volume[] channel_volume;         // one per channel, slider scale
    Decibel[] channel_db;            // empty if no dB route
    bool has_volume;
    bool volume_is_hardware;         // false = software (PA stream, or PA sink without HW_VOLUME_CTRL)
    bool has_mute;
    bool muted;
    bool has_balance;                // derived, see below
    float balance;                   // -1.0 .. +1.0, valid when has_balance
    Port[] ports;
    String active_port;              // empty = none
    bool is_default;
}
struct Stream                        // playback (Flow.OUTPUT) or record (Flow.INPUT)
{
    String id;                       // PA sink-input index as text; WASAPI session instance id
    Flow flow;
    String app_name;
    String app_id;                   // desktop id (PA application.id; Windows session id)
    String app_icon;                 // freedesktop icon name or path
    String binary;
    uint pid;                        // 0 = unknown
    String device_id;
    Volume[] channel_volume;
    bool has_volume;
    bool has_mute;
    bool muted;
}
struct State                         // plain data only: no optionals, no pointers (ARCHITECTURE 1)
{
    Device[] outputs;
    Device[] inputs;
    String default_output_id;        // empty = none
    String default_input_id;
    Stream[] streams;
    bool mic_in_use;                 // heuristics per platform (2.1.8, 2.2, 2.3)
    String backend_name;
}
enum Cap : char
{
    LIST_DEVICES, DEVICE_VOLUME, DEVICE_DB, DEVICE_BOOST, DEVICE_MUTE, DEVICE_BALANCE,
    DEFAULT_GET, DEFAULT_SET, PORTS, PORT_SET, CARD_PROFILES, CARD_PROFILE_SET,
    STREAMS_PLAYBACK, STREAMS_RECORD, STREAM_VOLUME, STREAM_MUTE, STREAM_MOVE,
    PEAK_METER, MIC_IN_USE, EVENTS, HW_VOLUME_FLAG,
}
enum EventKind : char
{
    DEVICE_ADDED, DEVICE_REMOVED, DEVICE_CHANGED, DEFAULT_CHANGED,
    STREAM_ADDED, STREAM_REMOVED, STREAM_CHANGED, MIC_IN_USE_CHANGED, OVERFLOW,
}
struct Event { EventKind kind; Flow flow; String id; }
enum BackendChoice : char { AUTO, PULSE, ALSA, COREAUDIO, WASAPI }
struct Options { BackendChoice backend; Allocator allocator; }
```

Commands (each returns an `Operation{Value}` where it can fail late):

* `set_device_volume(id, Flow, Volume[]) -> Operation`
* `set_device_mute(id, Flow, bool) -> Operation`
* `set_default(id, Flow)` (needs `Cap.DEFAULT_SET`)
* `set_stream_volume(stream_id, Volume[])`, `set_stream_mute(stream_id, bool)`
* `move_stream(stream_id, device_id)` (needs `Cap.STREAM_MOVE`)
* `set_port(device_id, port_name)`, `set_card_profile(card_id, profile_name)`

Balance is derived: `balance = (R - L) / (R + L)` from the two channel volumes.
`pa_cvolume_get_balance` `[PA-VOL]:345` is the PulseAudio form. It is not stored
state.

Backends by OS, with priority:

* `LINUX`: `pulse_native` (priority 100; PulseAudio and pipewire-pulse);
  `alsa_mixer` (priority 10; volume and mute only; cut line).
* `MACOS`: `coreaudio_hal` (priority 100; devices, default, volume, mute,
  events, mic-in-use approximation). Per-app and process tap: not in v1.
* `WINDOWS`: `wasapi_mmdevice` (priority 100; endpoints, volume, mute, events,
  sessions, peak). Private default selection in `wasapi_policy_private.c3`, not
  in v1 unless approved.

Fields unavailable per platform: ports and card profiles (no Windows or macOS
route checked); per-app streams on macOS (process tap is capture only);
`PEAK_METER` on macOS (not read); `DEFAULT_SET` on Windows without the private
route; `DEVICE_DB` where the driver reports no range.

## 6. Risks and cut lines

What is hard:

* **Linux, wire layer.** Tagstruct, framing and auth are small but exact. The
  version-gating mismatch (A6) is where the reference implementations disagree.
  Test against a real server before relying on it. No server was run here.
* **Linux, PipeWire.** Not a risk for the Pulse route. It is a risk for any future
  native PipeWire backend (SPA pods, metadata objects).
* **macOS, per-app volume.** Not available through the OS. A driver (Background
  Music) is the only documented way, and it counts as a microphone for TCC
  `[BGM]:152-161`. Out of scope for v1.
* **macOS, selector semantics.** Element 0 and channel semantics, the scalar
  range, and the meaning of `IsRunningSomewhere` are not verified (M2, M10).
* **Windows, default device.** `IPolicyConfig` is undocumented. The CLSID in the
  brief disagrees with EarTrumpet (W10). The slot table is single-source (W9).
  It needs a private backend and run-time resolution.
* **Windows, endpoint volume above 100 %.** The scalar is clamped to 0..1
  `[MS-SMV]`. The dB range is driver-dependent. Above 100 % is not offered.
* **Hardware or software volume.** Reported per backend: Linux sink flags, Windows
  `QueryHardwareSupport` semantics `(UNVERIFIED)`, CoreAudio property presence
  `(UNVERIFIED)`. Model it as a Cap, not as a bare bool.

Cut lines, recommended for v1:

1. Linux: Pulse protocol with ports, cards, streams, events, volume and mute.
   Drop the peak meter (optional) and per-stream dB.
2. Linux: ALSA fallback as volume and mute only, or defer it.
3. macOS: devices, default, volume (scalar or dB), mute, device events, the
   mic-in-use approximation. Drop per-app, process tap, peak meter and all
   private routes.
4. Windows: endpoints, default get, volume, mute, events, per-app sessions
   (volume, mute, pid, name), peak. Drop default set and per-app move (both private).
5. Balance: derive only; do not store.
6. Above 100 %: Linux only in v1 (the PulseAudio server accepts it); other
   platforms report their native range and no boost.

Doubts for the lead:

* The `Level` clamp (`unit.c3:16-27`) conflicts with the above-100 % requirement.
  Decide before State is written.
* The brief's Windows CLSID and factory IIDs could not be confirmed (W10, W11).
  Treat them as unverified until a second source is read.
* No test was run against PulseAudio, pipewire-pulse, CoreAudio or WASAPI. This
  spike is design evidence only.
* The previous Rust attempt's `pulseaudio` fork was not read. The upstream crate
  (0.3.2) was used instead, which is the newer code.
