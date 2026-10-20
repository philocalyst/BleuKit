<*
 DDC/CI brightness on Linux: one `DdcDisplay` per connected external monitor,
 with its VCP 0x10 (luminance) read and written through `bleu::ddc`.

 A display is opened once and kept while its connector stays connected. The
 bus is attached through `OpenBusFn` when a test or another backend supplies one,
 otherwise through `/dev/i2c-N` (see `linux_i2c.c3`); only a bus opened here is
 locked and closed here. The luminance maximum is remembered from the last read, so a
 write does not have to read first, which would double the time a ramp step takes.
 A transfer that keeps failing detaches the display, and the next pass opens it again.
*>
module bleu::brightness::linux_ddc @feat(LINUX);
import std::collections::list, std::collections::maybe, bleu::availability, bleu::brightness, bleu::brightness::drm, bleu::brightness::i2cdev, bleu::ddc::session, bleu::ddc::transport, bleu::ddc::vcp, bleu::error, bleu::unit;

<* Consecutive failed transfers after which the display is detached and its bus opened again. *>
const uint DETACH_AFTER = 3;

<* One external monitor, behind one DDC/CI bus. *>
struct DdcDisplay
{
	String connector;
	int bus;
	bool opened;
	bool owns_bus;
	Availability unopened;
	I2cBus device;
	Transport transport;
	Session session;
	ushort maximum;
	uint failures;
}

<*
 Make the display of `connector` on I2C bus `bus` ready: open the bus, or ask
 `open_bus` for its transport. Failure leaves the display unopened, with the reason
 in `unopened`; the next pass tries again.
*>
fn void DdcDisplay.attach(&self, String root, OpenBusFn open_bus, void* context)
{
	@pool()
	{
		String path = string::tformat("%s/dev/i2c-%d", root, self.bus);
		if (open_bus)
		{
			Transport? channel = open_bus(context, path);
			if (catch err = channel)
			{
				self.unopened = open_failure(err);
				return;
			}
			else
			{
				self.transport = channel;
			}
		}
		else
		{
			I2cBus? device = i2cdev::open_device(path);
			if (catch err = device)
			{
				self.unopened = open_failure(err);
				return;
			}
			else
			{
				self.device = device;
				self.owns_bus = true;
			}
			self.transport = &self.device;
		}
		self.session = session::open(self.transport, transport::real_sleeper(), session::default_options());
		self.opened = true;
		self.failures = 0;
	};
}

// Why a display's bus did not open, as the availability a read reports.
fn Availability open_failure(fault failure) @private
{
	if (failure == error::PERMISSION_DENIED) return availability::no(
		PERMISSION_NEEDED,
		"the DDC/CI bus exists but may not be opened (group i2c)"
	);
	return availability::no(HARDWARE_ABSENT, "the DDC/CI bus could not be opened");
}

<* Release the bus, if it was opened here. The display is unopened afterwards. *>
fn void DdcDisplay.detach(&self)
{
	if (!self.opened) return;
	if (self.owns_bus) self.device.close();
	self.owns_bus = false;
	self.opened = false;
}

// Take the bus for one transaction. A bus given through `open_bus` has no lock to take.
fn void? DdcDisplay.lock_bus(&self)
{
	if (!self.owns_bus) return;
	self.device.lock_exclusive()!;
}

// Release the transaction's lock. The bus is unlocked whenever it is not in use.
fn void DdcDisplay.unlock_bus(&self)
{
	if (self.owns_bus) self.device.unlock_exclusive();
}

// A transfer failed: count it, so that a display that keeps failing is detached.
fn void DdcDisplay.transfer_failed(&self)
{
	self.failures++;
}

<*
 Read the display's luminance. An unopened display reports why it is unopened. A
 transfer that fails keeps the last known range: the value is then unreadable, but a
 write can still be carried out with that range.
*>
fn Control DdcDisplay.read(&self)
{
	if (!self.opened) return { .mechanism = DDC, .availability = self.unopened };
	if (catch err = self.lock_bus())
	{
		return {
			.mechanism = DDC,
			.availability = availability::no(HARDWARE_ABSENT, "the DDC/CI bus is busy: another process holds its lock"),
		};
	}
	defer self.unlock_bus();
	if (try reading = self.session.get_vcp(vcp::VcpCode.LUMINANCE))
	{
		self.failures = 0;
		if (reading.maximum > 0)
		{
			self.maximum = reading.maximum;
			long max = (long)reading.maximum;
			return {
				.mechanism = DDC,
				.readable = true,
				.writable = true,
				.availability = availability::YES,
				.level = maybe::value(unit::from_raw((long)reading.current, 0, max)),
				.raw = maybe::value((long)reading.current),
				.raw_min = 0,
				.raw_max = max,
			};
		}
		self.maximum = 0;
		return {
			.mechanism = DDC,
			.availability = availability::no(HARDWARE_ABSENT, "the display did not report a VCP 0x10 range")
		};
	}
	self.transfer_failed();
	if (self.maximum == 0)
	{
		return {
			.mechanism = DDC,
			.availability = availability::no(HARDWARE_ABSENT, "the display did not answer the VCP 0x10 query"),
		};
	}
	return {
		.mechanism = DDC,
		.writable = true,
		.availability = availability::YES,
		.raw_min = 0,
		.raw_max = (long)self.maximum,
	};
}

<*
 Set the display's luminance to `level`, then read it back. The read-back must agree with
 the raw value written, to within one device step; otherwise the display did not take it.

 @return? error::UNAVAILABLE : "The display's range is not known; it has not been read"
 @return? error::BACKEND_FAILURE, error::PROTOCOL, error::UNSUPPORTED : "The display refused or did not answer the write, or did not take the value"
*>
fn Applied? DdcDisplay.write(&self, Level level)
{
	if (!self.opened || self.maximum == 0)
	{
		return error::raise(
			error::UNAVAILABLE,
			error::Domain.INTERNAL,
			0,
			"the DDC/CI range of '%s' is not known",
			self.connector
		)~;
	}
	long max = (long)self.maximum;
	long raw = level.to_raw(0, max);
	self.lock_bus()!;
	defer self.unlock_bus();
	if (catch err = self.session.set_vcp(vcp::VcpCode.LUMINANCE, (ushort)raw))
	{
		self.transfer_failed();
		return err~;
	}
	self.failures = 0;
	Maybe{Level} read_back = { };
	if (try reading = self.session.get_vcp(vcp::VcpCode.LUMINANCE))
	{
		read_back = maybe::value(unit::from_raw((long)reading.current, 0, max));
	}
	brightness::confirm_read_back(self.connector, raw, 0, max, read_back)!;
	return brightness::applied_at(DDC, level, raw, 0, max, read_back);
}

<*
 Bring the list of displays in line with the connected connectors: keep the
 displays that are still connected, open the new ones, and close the rest.
 `displays` is owned by the caller and its elements are allocated from `allocator`.
*>
fn void sync_displays(List{DdcDisplay*}* displays, Allocator allocator, String root, OpenBusFn open_bus, void* context)
{
	Connector[] connected = drm::connectors(tmem, root) ?? { };
	List{DdcDisplay*} next;
	next.init(allocator);
	foreach (connector : connected)
	{
		DdcDisplay* display = find_display(displays, connector.name, connector.bus);
		if (!display)
		{
			display = alloc::new(
				allocator,
				DdcDisplay,
				{ .connector = connector.name.copy(allocator), .bus = connector.bus, .device = { .fd = -1 } }
			);
		}
		else
		{
			displays.remove_at(index_of(displays, display));
		}
		if (display.failures >= DETACH_AFTER) display.detach();
		if (!display.opened) display.attach(root, open_bus, context);
		next.push(display);
	}
	foreach (display : *displays)
	{
		display.detach();
		alloc::free(allocator, display.connector.ptr);
		alloc::free(allocator, display);
	}
	displays.free();
	*displays = next;
}

<* The display of `connector` on `bus`, or null. *>
fn DdcDisplay* find_display(List{DdcDisplay*}* displays, String connector, int bus) @private
{
	foreach (display : *displays)
	{
		if (display.connector == connector && display.bus == bus) return display;
	}
	return null;
}

<* Index of `display` in `displays`. The display must be in the list. *>
fn sz index_of(List{DdcDisplay*}* displays, DdcDisplay* display) @private
{
	for (sz i = 0; i < displays.len(); i++)
	{
		if (displays.get(i) == display) return i;
	}
	unreachable("the display is in the list");
}