<*
 DDC/CI brightness on Linux: one `DdcDisplay` per connected external monitor,
 with its VCP 0x10 (luminance) read and written through `bleu::ddc`.

 A display is opened once and kept while its connector stays connected. The
 bus is attached through `OpenBusFn` when a test or another backend supplies one,
 otherwise through `/dev/i2c-N` (see `linux_i2c.c3`). The luminance maximum is
 remembered from the last read, so a write does not have to read first, which
 would double the time a ramp step takes.
*>
module bleu::brightness::linux_ddc @feat(LINUX);
import std::collections::list, std::collections::maybe, bleu::availability, bleu::brightness, bleu::brightness::drm, bleu::brightness::i2cdev, bleu::ddc::session, bleu::ddc::transport, bleu::ddc::vcp, bleu::error, bleu::unit;

<* One external monitor, behind one DDC/CI bus. *>
struct DdcDisplay
{
	String connector;
	int bus;
	bool opened;
	bool denied;
	I2cBus device;
	Transport transport;
	Session session;
	ushort maximum;
}

<*
 Make the display of `connector` on I2C bus `bus` ready: open the bus, or ask
 `open_bus` for its transport. Failure leaves the display unopened; the next
 pass tries again.
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
				self.denied = err == error::PERMISSION_DENIED;
				return;
			}
			else
			{
				self.device = device;
			}
			self.transport = &self.device;
		}
		self.session = session::open(self.transport, transport::real_sleeper(), session::default_options());
		self.opened = true;
	};
}

<* Release the bus. The display is unopened afterwards. *>
fn void DdcDisplay.detach(&self)
{
	if (!self.opened) return;
	self.device.close();
	self.opened = false;
}

<*
 Read the display's luminance. An unopened display, or one that does not answer
 VCP 0x10, reports the control unreadable with the reason.
*>
fn Control DdcDisplay.read(&self)
{
	if (!self.opened)
	{
		Availability state = self.denied
			? availability::no(PERMISSION_NEEDED, "the DDC/CI bus exists but may not be opened (group i2c)")
			: availability::no(HARDWARE_ABSENT, "the DDC/CI bus could not be opened");
		return { .mechanism = DDC, .availability = state };
	}
	if (try reading = self.session.get_vcp(vcp::VcpCode.LUMINANCE))
	{
		self.maximum = reading.maximum;
		if (reading.maximum > 0)
		{
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
	}
	self.maximum = 0;
	return { .mechanism = DDC, .availability = availability::no(HARDWARE_ABSENT, "the display did not report a VCP 0x10 range") };
}

<*
 Set the display's luminance to `level`, then read it back.

 @return? error::UNAVAILABLE : "The display's range is not known; it has not been read"
 @return? error::BACKEND_FAILURE, error::PROTOCOL, error::UNSUPPORTED : "The display refused or did not answer the write"
*>
fn Applied? DdcDisplay.write(&self, Level level)
{
	if (!self.opened || self.maximum == 0)
	{
		return error::raise(error::UNAVAILABLE, error::Domain.INTERNAL, 0, "the DDC/CI range of '%s' is not known", self.connector)~;
	}
	long max = (long)self.maximum;
	long raw = level.to_raw(0, max);
	self.session.set_vcp(vcp::VcpCode.LUMINANCE, (ushort)raw)!;
	Maybe{Level} read_back = { };
	if (try reading = self.session.get_vcp(vcp::VcpCode.LUMINANCE))
	{
		read_back = maybe::value(unit::from_raw((long)reading.current, 0, max));
	}
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
			display = alloc::new(allocator, DdcDisplay, { .connector = connector.name.copy(allocator), .bus = connector.bus });
		}
		else
		{
			displays.remove_at(index_of(displays, display));
		}
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
