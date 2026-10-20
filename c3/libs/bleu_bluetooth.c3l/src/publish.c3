// Publication for every backend: a complete state is published only when it
// differs from the latest one, and the events of the difference follow it. The
// backends build snapshots on the worker thread and call these functions there.
module bleu::bluetooth;
import bleu::equal, bleu::observe;

<*
 Publish `snapshot` if it differs from the latest state, then emit the events
 of the difference. Consumes `snapshot`.
*>
fn void publish_changes(BluetoothHub* hub, Snapshot{State}* snapshot)
{
	Snapshot{State}* previous = null;
	if (try latest = hub.latest()) previous = latest;
	if (previous != null && equal::deep(previous.value, snapshot.value))
	{
		previous.release();
		snapshot.release();
		return;
	}
	Snapshot{State}* kept = snapshot.retain();
	hub.publish(snapshot);
	State empty;
	State before = previous ? previous.value : empty;
	emit_differences(hub, &before, &kept.value);
	if (previous) previous.release();
	kept.release();
}

// Events for every adapter and device that appeared, changed or vanished between two states.
fn void emit_differences(BluetoothHub* hub, State* before, State* after)
{
	foreach (&adapter : after.adapters)
	{
		sz old = find_adapter(before.adapters, adapter.address);
		if (old < 0)
		{
			emit(hub, EventKind.ADAPTER_ADDED, adapter.address, "");
		}
		else if (!equal::deep(before.adapters[old], *adapter))
		{
			emit(hub, EventKind.ADAPTER_CHANGED, adapter.address, "");
		}
	}
	foreach (&adapter : before.adapters)
	{
		if (find_adapter(after.adapters, adapter.address) < 0) emit(hub, EventKind.ADAPTER_REMOVED, adapter.address, "");
	}
	foreach (&device : after.devices)
	{
		sz old = find_device(before.devices, device.address);
		if (old < 0)
		{
			emit(hub, EventKind.DEVICE_ADDED, device.address, "");
		}
		else if (!equal::deep(before.devices[old], *device))
		{
			emit(hub, EventKind.DEVICE_CHANGED, device.address, "");
		}
	}
	foreach (&device : before.devices)
	{
		if (find_device(after.devices, device.address) < 0) emit(hub, EventKind.DEVICE_REMOVED, device.address, "");
	}
}

fn sz find_adapter(Adapter[] adapters, String address)
{
	foreach (i, &adapter : adapters)
	{
		if (adapter.address == address) return (sz)i;
	}
	return -1;
}

fn sz find_device(Device[] devices, String address)
{
	foreach (i, &device : devices)
	{
		if (device.address == address) return (sz)i;
	}
	return -1;
}

<* Send one event. The strings are copied into the event's own arena. *>
fn void emit(BluetoothHub* hub, EventKind kind, String address, String text)
{
	Snapshot{Event}* packet = hub.emit_begin();
	Allocator arena = packet.allocator();
	packet.value = { .kind = kind, .address = bluetooth::copy_text(address, arena), .text = bluetooth::copy_text(text, arena) };
	hub.emit(packet);
}


<* Publish an empty state: the backend has no controllers or devices now. *>
fn void publish_empty(BluetoothHub* hub)
{
	Snapshot{State}* snapshot = hub.begin();
	snapshot.value = { };
	publish_changes(hub, snapshot);
}

<* Adapters in address order, so that the state does not depend on the order the OS reports them in. *>
fn void sort_adapters(Adapter[] adapters)
{
	for (sz i = 1; i < adapters.len; i++)
	{
		Adapter key = adapters[i];
		sz j = i - 1;
		while (j >= 0 && adapters[j].address.compare_to(key.address) > 0)
		{
			adapters[j + 1] = adapters[j];
			j--;
		}
		adapters[j + 1] = key;
	}
}

<* Devices in address order. *>
fn void sort_devices(Device[] devices)
{
	for (sz i = 1; i < devices.len; i++)
	{
		Device key = devices[i];
		sz j = i - 1;
		while (j >= 0 && devices[j].address.compare_to(key.address) > 0)
		{
			devices[j + 1] = devices[j];
			j--;
		}
		devices[j + 1] = key;
	}
}
