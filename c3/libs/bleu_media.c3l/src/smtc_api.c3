<*
 The Windows Runtime interfaces the SMTC backend calls, as vtables.

 Every slot number is the position of the method in the interface's vtable,
 which is the order of its declaration in the metadata. The IInspectable base
 is slots 0 to 5 (`bleu::win::winrt`). Verified against the bindings in
 windows-rs 0.62.2 (`src/Windows/Media/Control/mod.rs`, `src/Windows/Foundation/mod.rs`),
 windows-future 0.3.2 (`IAsyncOperation_Vtbl`: SetCompleted 6, Completed 7,
 GetResults 8) and windows-collections 0.3.2 (`IVectorView_Vtbl`: GetAt 6,
 Size 7). Unused slots are declared as `void*` so that the used ones line up.

 Methods that return an object return it as an owned `void*`, released with
 `release_object`. Methods that return a value use an out parameter, as the ABI
 requires. Not compiled or run here: type-checked for the Windows targets only.
*>
module bleu::media::smtc_api @feat(WIN32);
import bleu::win::hresult, bleu::win::winrt, bleu::win::guid;

<* Any method returning an object, a string (HSTRING) or an async operation: `void**` out. *>
alias GetObjectFn = fn hresult::Hresult(void* self, void** out);
<* A method returning a `bool` through an out pointer. *>
alias GetBoolFn = fn hresult::Hresult(void* self, bool* out);
<* A method returning a 64-bit value (TimeSpan or DateTime, one `long` of ticks). *>
alias GetTicksFn = fn hresult::Hresult(void* self, long* out);
<* A method returning an `int` enumeration (`GlobalSystemMediaTransportControlsSessionPlaybackStatus`). *>
alias GetIntFn = fn hresult::Hresult(void* self, int* out);
<* A method returning a `double` through an out pointer (`IReference<double>.Value`). *>
alias GetDoubleFn = fn hresult::Hresult(void* self, double* out);
<* A method taking an `int` and returning an async operation. *>
alias SetIntAsyncFn = fn hresult::Hresult(void* self, int value, void** out);
<* A method taking a `double` and returning an async operation. *>
alias SetDoubleAsyncFn = fn hresult::Hresult(void* self, double value, void** out);
<* A method taking a `bool` and returning an async operation. *>
alias SetBoolAsyncFn = fn hresult::Hresult(void* self, bool value, void** out);
<* A method taking a 64-bit tick count and returning an async operation. *>
alias SetTicksAsyncFn = fn hresult::Hresult(void* self, long value, void** out);
<* `IVectorView<T>.GetAt`: element `index`, as an owned object. *>
alias GetAtFn = fn hresult::Hresult(void* self, uint index, void** out);
<* `IVectorView<T>.Size`. *>
alias GetSizeFn = fn hresult::Hresult(void* self, uint* out);

<* `IGlobalSystemMediaTransportControlsSessionManagerStatics`: slot 6 is `RequestAsync`. *>
struct ManagerStaticsVtbl
{
	winrt::IInspectableVtbl base;
	GetObjectFn request_async;
}

<* An object of the statics interface. *>
struct ManagerStatics
{
	ManagerStaticsVtbl* vtbl;
}

<* `IGlobalSystemMediaTransportControlsSessionManager`: the sessions the system knows about. *>
struct ManagerVtbl
{
	winrt::IInspectableVtbl base;
	GetObjectFn get_current_session;
	GetObjectFn get_sessions;
}

<* An object of the session manager interface. *>
struct Manager
{
	ManagerVtbl* vtbl;
}

<* `IGlobalSystemMediaTransportControlsSession`: one media session (one application). *>
struct SessionVtbl
{
	winrt::IInspectableVtbl base;
	GetObjectFn source_app_user_model_id; // 6, HSTRING
	GetObjectFn try_get_media_properties_async; // 7, IAsyncOperation<MediaProperties>
	GetObjectFn get_timeline_properties; // 8
	GetObjectFn get_playback_info; // 9
	GetObjectFn try_play_async; // 10, IAsyncOperation<Boolean>
	GetObjectFn try_pause_async; // 11
	GetObjectFn try_stop_async; // 12
	void* try_record_async; // 13
	void* try_fast_forward_async; // 14
	void* try_rewind_async; // 15
	GetObjectFn try_skip_next_async; // 16
	GetObjectFn try_skip_previous_async; // 17
	void* try_change_channel_up_async; // 18
	void* try_change_channel_down_async; // 19
	GetObjectFn try_toggle_play_pause_async; // 20
	SetIntAsyncFn try_change_auto_repeat_mode_async; // 21
	SetDoubleAsyncFn try_change_playback_rate_async; // 22
	SetBoolAsyncFn try_change_shuffle_active_async; // 23
	SetTicksAsyncFn try_change_playback_position_async; // 24
}

<* An object of the session interface. *>
struct Session
{
	SessionVtbl* vtbl;
}

<* `IGlobalSystemMediaTransportControlsSessionMediaProperties`: the track's text. Slots 6, 9, 10 are used. *>
struct MediaPropertiesVtbl
{
	winrt::IInspectableVtbl base;
	GetObjectFn title; // 6, HSTRING
	GetObjectFn subtitle; // 7
	GetObjectFn album_artist; // 8
	GetObjectFn artist; // 9
	GetObjectFn album_title; // 10
}

<* An object of the media properties interface. *>
struct MediaProperties
{
	MediaPropertiesVtbl* vtbl;
}

<* `IGlobalSystemMediaTransportControlsSessionPlaybackInfo`: status, controls, repeat, shuffle, rate. *>
struct PlaybackInfoVtbl
{
	winrt::IInspectableVtbl base;
	GetObjectFn controls; // 6, PlaybackControls
	GetIntFn playback_status; // 7
	void* playback_type; // 8
	GetObjectFn auto_repeat_mode; // 9, IReference<MediaPlaybackAutoRepeatMode>
	GetObjectFn playback_rate; // 10, IReference<Double>
	GetObjectFn is_shuffle_active; // 11, IReference<Boolean>
}

<* An object of the playback info interface. *>
struct PlaybackInfo
{
	PlaybackInfoVtbl* vtbl;
}

<* `IGlobalSystemMediaTransportControlsSessionTimelineProperties`: the position and when it was read. *>
struct TimelineVtbl
{
	winrt::IInspectableVtbl base;
	GetTicksFn start_time; // 6
	GetTicksFn end_time; // 7
	GetTicksFn min_seek_time; // 8
	GetTicksFn max_seek_time; // 9
	GetTicksFn position; // 10, TimeSpan
	GetTicksFn last_updated; // 11, DateTime
}

<* An object of the timeline interface. *>
struct Timeline
{
	TimelineVtbl* vtbl;
}

<* `IGlobalSystemMediaTransportControlsSessionPlaybackControls`: which controls the session offers. *>
struct PlaybackControlsVtbl
{
	winrt::IInspectableVtbl base;
	GetBoolFn is_play_enabled; // 6
	GetBoolFn is_pause_enabled; // 7
	GetBoolFn is_stop_enabled; // 8
	GetBoolFn is_record_enabled; // 9
	GetBoolFn is_fast_forward_enabled; // 10
	GetBoolFn is_rewind_enabled; // 11
	GetBoolFn is_next_enabled; // 12
	GetBoolFn is_previous_enabled; // 13
	GetBoolFn is_channel_up_enabled; // 14
	GetBoolFn is_channel_down_enabled; // 15
	GetBoolFn is_play_pause_toggle_enabled; // 16
	GetBoolFn is_shuffle_enabled; // 17
	GetBoolFn is_repeat_enabled; // 18
	GetBoolFn is_playback_rate_enabled; // 19
	GetBoolFn is_playback_position_enabled; // 20
}

<* An object of the playback controls interface. *>
struct PlaybackControls
{
	PlaybackControlsVtbl* vtbl;
}

<* `IReference<Boolean>` and `IReference<Double>`: a nullable value; `Value` is slot 6. *>
struct ReferenceBoolVtbl
{
	winrt::IInspectableVtbl base;
	GetBoolFn value;
}

<* An object of `IReference<Boolean>`. *>
struct ReferenceBool
{
	ReferenceBoolVtbl* vtbl;
}

// `IReference<MediaPlaybackAutoRepeatMode>`: an enumeration in a nullable box.
struct ReferenceIntVtbl
{
	winrt::IInspectableVtbl base;
	GetIntFn value;
}

<* An object of `IReference<MediaPlaybackAutoRepeatMode>`. *>
struct ReferenceInt
{
	ReferenceIntVtbl* vtbl;
}

struct ReferenceDoubleVtbl
{
	winrt::IInspectableVtbl base;
	GetDoubleFn value;
}

<* An object of `IReference<Double>`. *>
struct ReferenceDouble
{
	ReferenceDoubleVtbl* vtbl;
}

<* `IVectorView<T>`: slot 6 `GetAt`, slot 7 `Size`. *>
struct VectorViewVtbl
{
	winrt::IInspectableVtbl base;
	GetAtFn get_at;
	GetSizeFn size;
}

<* An object of a vector view. *>
struct VectorView
{
	VectorViewVtbl* vtbl;
}

<* `IAsyncOperation<TResult>`: slot 8 `GetResults`; slots 6 and 7 are the completion handler. *>
struct AsyncObjectVtbl
{
	winrt::IInspectableVtbl base;
	void* set_completed;
	void* completed;
	GetObjectFn get_results;
}

<* An `IAsyncOperation` whose result is an object. *>
struct AsyncObject
{
	AsyncObjectVtbl* vtbl;
}

<* `IAsyncOperation<Boolean>`: the same slots, with a `bool` result. *>
struct AsyncBoolVtbl
{
	winrt::IInspectableVtbl base;
	void* set_completed;
	void* completed;
	GetBoolFn get_results;
}

<* An `IAsyncOperation<Boolean>`. *>
struct AsyncBool
{
	AsyncBoolVtbl* vtbl;
}

<* Runtime class name and interface identifiers the backend activates or queries. *>
const String MANAGER_CLASS           = "Windows.Media.Control.GlobalSystemMediaTransportControlsSessionManager";
// IGlobalSystemMediaTransportControlsSessionManagerStatics (windows-rs define_interface, 2050c4ee-...).
const guid::Guid IID_MANAGER_STATICS = guid::guid("2050c4ee-11a0-57de-aed7-c97c70338245");

// Release an owned object of any interface: every object begins with IUnknown.
fn void release_object(void* object)
{
	if (object == null) return;
	winrt::IInspectable* unknown = (winrt::IInspectable*)object;
	unknown.vtbl.release(unknown);
}