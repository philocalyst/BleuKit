// The procfs backend against a fake root: a directory tree with the files the
// kernel would have, rewritten between two samples so the deltas are known.
// Nothing outside the fake root is read, except statvfs on the fake mount point
// (a directory inside the fake root) and the kernel's uname.
module bleu::sysinfo::linux_test @feat(LINUX);
import std::core::test, std::io::path, std::os::process, std::time, std::time::clock, bleu::error, bleu::observe, bleu::operation, bleu::rt::fs, bleu::stream, bleu::sysinfo;

// Creates `root`/`relative` with `text`, creating directories as needed.
fn void write_file(String root, String relative, String text) @local
{
	String full = string::tformat("%s%s", root, relative);
	sz slash    = full.rindex_of_char('/')!!;
	path::mkdir((Path)full[0:slash], true)!!;
	fs::write_text(full, text)!!;
}

fn String make_root() @local
{
	String root = string::tformat("/tmp/bleu-sysinfo-%d", clock::now());
	write_file(
		root,
		"/proc/stat",
		"cpu  100 0 100 800 0 0 0 0 0 0\ncpu0 50 0 50 400 0 0 0 0 0 0\ncpu1 50 0 50 400 0 0 0 0 0 0\n"
	);
	write_file(
		root,
		"/proc/meminfo",
		"MemTotal: 16479424 kB\nMemFree: 14068852 kB\nMemAvailable: 15472216 kB\nBuffers: 103580 kB\nCached: 1469600 kB\nSReclaimable: 119360 kB\nShmem: 14968 kB\nSwapTotal: 0 kB\nSwapFree: 0 kB\n"
	);
	write_file(root, "/proc/loadavg", "1.23 0.85 0.83 5/116 31806\n");
	write_file(root, "/proc/uptime", "3855.92 12736.91\n");
	write_file(
		root,
		"/proc/net/dev",
		"Inter-|   Receive\n face |bytes\n  eth0: 1000 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0\n"
	);
	write_file(root, "/proc/mounts", "proc /proc proc rw 0 0\n/dev/fake /mnt/fake ext4 rw 0 0\n");
	write_file(root, "/proc/sys/kernel/hostname", "fakehost\n");
	write_file(root, "/proc/cpuinfo", "processor\t: 0\nmodel name\t: Fake CPU 9000\n");
	write_file(root, "/proc/100/stat", "100 (fake) S 1 100 100 0 -1 0 0 0 0 0 100 0 0 0 20 0 1 0 5000\n");
	write_file(root, "/proc/100/status", "Name:\tfake\nUid:\t0\t0\t0\t0\nVmRSS:\t    2048 kB\n");
	write_file(root, "/proc/100/cmdline", "fake\0--run\0");
	write_file(root, "/proc/101/stat", "101 (kthreadd) S 0 0 0 0 -1 0 0 0 0 0 0 0 0 0 20 0 1 0 5000\n");
	write_file(root, "/proc/101/status", "Name:\tkthreadd\nUid:\t0\t0\t0\t0\n");
	write_file(root, "/etc/passwd", "root:x:0:0:root:/root:/bin/bash\n");
	write_file(root, "/etc/os-release", "NAME=\"Fake\"\nPRETTY_NAME=\"Fake Linux 1.0\"\n");
	write_file(root, "/sys/devices/system/cpu/cpu0/cpufreq/scaling_cur_freq", "2400000\n");
	write_file(root, "/sys/class/hwmon/hwmon0/name", "coretemp\n");
	write_file(root, "/sys/class/hwmon/hwmon0/temp1_input", "45000\n");
	write_file(root, "/sys/class/hwmon/hwmon0/temp1_label", "Package id 0\n");
	path::mkdir((Path)string::tformat("%s/mnt/fake", root), true)!!;
	return root;
}

// Second sample: CPU 80 % busy over the window, eth0 receives 500 more bytes, pid 100 ran one more tick,
// and a second volume is mounted.
fn void make_second_sample(String root) @local
{
	write_file(
		root,
		"/proc/stat",
		"cpu  300 0 300 900 0 0 0 0 0 0\ncpu0 150 0 150 450 0 0 0 0 0 0\ncpu1 150 0 150 450 0 0 0 0 0 0\n"
	);
	write_file(
		root,
		"/proc/net/dev",
		"Inter-|   Receive\n face |bytes\n  eth0: 1500 0 0 0 0 0 0 0 2000 0 0 0 0 0 0 0\n"
	);
	write_file(root, "/proc/100/stat", "100 (fake) S 1 100 100 0 -1 0 0 0 0 0 101 0 0 0 20 0 1 0 5000\n");
	write_file(
		root,
		"/proc/mounts",
		"proc /proc proc rw 0 0\n/dev/fake /mnt/fake ext4 rw 0 0\n/dev/fake2 /mnt/fake2 ext4 rw 0 0\n"
	);
	path::mkdir((Path)string::tformat("%s/mnt/fake2", root), true)!!;
}

fn void reads_the_whole_machine_from_a_fake_root() @test
{
	@pool()
	{
		String root = make_root();
		Sysinfo* service = sysinfo::open(
			mem,
			{ .backend = PROCFS, .root = root, .interval = time::ms(200), .process_count = 5 }
		)!!;
		defer service.close();
		test::@check(service.backend_name() == "procfs", "backend name");
		test::@check(service.capability(CPU_FREQUENCY).ok(), "cpu0 exposes cpufreq in the fake root");
		test::@check(service.capability(TEMPERATURES).ok(), "hwmon sensors exist in the fake root");
		Snapshot{State}* first = service.wait_after(0, time::ms(2000))!!;
		defer first.release();
		State* state = &first.value;
		test::@check(state.cpu.model == "Fake CPU 9000", "model from cpuinfo");
		test::@check(state.cpu.cores.len == 2 && state.cpu.cores[0].name == "cpu0", "two cores named cpuN");
		test::@check(!state.cpu.usage.has_value, "first sample: total usage unknown, not zero");
		test::@check(
			state.cpu.cores[0].frequency.has_value && (uint)state.cpu.cores[0].frequency.value == 2400,
			"cpu0 frequency in MHz"
		);
		test::@check(!state.cpu.cores[1].frequency.has_value, "cpu1 has no cpufreq: unknown");
		test::@check(
			state.memory.total == 16479424UL * 1024
				&& state.memory.used == state.memory.total - state.memory.available,
			"memory total and used"
		);
		test::@check(state.memory.swap_total == 0, "no swap");
		test::@check(
			state.identity.hostname == "fakehost" && state.identity.os == "Fake Linux 1.0",
			"hostname and os from the fake files"
		);
		test::@check(state.identity.uptime == (Duration)3_855_920_000, "uptime from /proc/uptime");
		test::@check(
			state.temperatures.len == 1 && state.temperatures[0].name == "coretemp Package id 0",
			"hwmon sensor with its label"
		);
		test::eq_approx((double)state.temperatures[0].value, 45.0, 3);
		test::@check(
			state.mounts.len == 1 && state.mounts[0].mount_point == "/mnt/fake" && state.mounts[0].total > 0,
			"one local disk, usage from statvfs"
		);
		test::@check(state.interfaces.len == 1 && !state.interfaces[0].receive.has_value, "first sample: no rate yet");
		test::@check(
			state.processes.len == 2 && state.processes[0].pid == 100 && state.processes[0].command == "fake --run",
			"busiest first, command line joined"
		);
		test::@check(
			state.processes[0].user == "root" && (uint)state.processes[0].memory.value == 2048 * 1024,
			"owner and resident memory"
		);
		test::@check(
			state.processes[1].command == "" && !state.processes[1].memory.has_value,
			"kernel thread: no command line, no resident set"
		);
		test::@check(!state.processes[0].cpu.has_value, "first sample: process CPU unknown");

		// The second sample must show the deltas. Samples may land before the files change,
		// so keep waiting until one reflects the new counters.
		Reader{Event}* events = service.subscribe()!!;
		defer events.release();
		make_second_sample(root);
		ulong seen = first.generation;
		bool done  = false;
		for (int attempt = 0; attempt < 20 && !done; attempt++)
		{
			Snapshot{State}* next = service.wait_after(seen, time::ms(2000))!!;
			defer next.release();
			seen = next.generation;
			State* later = &next.value;
			done = later.cpu.usage.has_value && later.interfaces[0].receive.has_value
				&& later.processes[0].cpu.has_value;
			if (done)
			{
				test::eq_approx((double)later.cpu.usage.value, 80.0, 3);
				test::@check(later.interfaces[0].receive.value > 0, "eth0 receive rate is positive");
				test::@check(
					later.processes[0].cpu.value > (Percent)0 && later.processes[0].cpu.value <= (Percent)200,
					"process share is within two processors"
				);
			}
		}
		test::@check(done, "a sample with deltas arrived");
		Snapshot{Event}* announced = events.next(time::sec(2))!!;
		defer announced.release();
		test::@check(
			announced.value.kind == MOUNT_ADDED && announced.value.name == "/mnt/fake2",
			"a new volume is announced as an event"
		);
	};
}

fn void kill_of_a_missing_process_fails_with_not_found() @test
{
	@pool()
	{
		String root      = make_root();
		Sysinfo* service = sysinfo::open(mem, { .backend = PROCFS, .root = root, .interval = time::ms(200) })!!;
		defer service.close();
		// pid_max is at most 4 194 304 on Linux, so this process cannot exist and nothing is signalled.
		Operation{KillReceipt}* operation = service.kill(2147483646, TERMINATE)!!;
		defer operation.release();
		test::@error(operation.wait(time::sec(2)), NOT_FOUND);
	};
}

fn void kill_of_pid_zero_is_refused_before_anything_is_signalled() @test
{
	@pool()
	{
		String root      = make_root();
		Sysinfo* service = sysinfo::open(mem, { .backend = PROCFS, .root = root, .interval = time::ms(200) })!!;
		defer service.close();
		// kill(0) signals the caller's whole process group, this test runner included: the refusal must be synchronous.
		test::@error(service.kill(0, TERMINATE), error::INVALID_ARGUMENT);
	};
}

fn void killing_a_child_this_test_spawned_ends_it() @test
{
	@pool()
	{
		String root      = make_root();
		Sysinfo* service = sysinfo::open(mem, { .backend = PROCFS, .root = root, .interval = time::ms(200) })!!;
		defer service.close();
		std::os::process::Process child = process::spawn(
			{ "sleep", "30" },
			process::SpawnOptions.INHERIT_ENV,
			{},
			process::INHERIT,
			process::INHERIT,
			process::INHERIT
		)!!;
		defer (void)child.destroy();
		uint target = (uint)child.child;
		Operation{KillReceipt}* operation = service.kill(target, TERMINATE)!!;
		defer operation.release();
		KillReceipt receipt = operation.wait(time::sec(5))!!;
		test::@check(receipt.pid == target && receipt.mode == TERMINATE, "the receipt names the child and the mode");
		(void)child.join()!!;
	};
}

fn void offline_cpu_does_not_shift_the_frequencies() @test
{
	@pool()
	{
		String root = make_root();
		// cpu1 is offline: it has no /proc/stat line, and its stale frequency file must not be read for cpu2.
		write_file(
			root,
			"/proc/stat",
			"cpu  100 0 100 800 0 0 0 0 0 0\ncpu0 50 0 50 400 0 0 0 0 0 0\ncpu2 50 0 50 400 0 0 0 0 0 0\n"
		);
		write_file(root, "/sys/devices/system/cpu/cpu1/cpufreq/scaling_cur_freq", "111000\n");
		write_file(root, "/sys/devices/system/cpu/cpu2/cpufreq/scaling_cur_freq", "2222000\n");
		Sysinfo* service = sysinfo::open(mem, { .backend = PROCFS, .root = root, .interval = time::ms(200) })!!;
		defer service.close();
		Snapshot{State}* snapshot = service.wait_after(0, time::sec(5))!!;
		defer snapshot.release();
		CpuCore[] cores = snapshot.value.cpu.cores;
		test::eq(cores.len, 2);
		test::@check(cores[1].name == "cpu2", "the second core is cpu2");
		test::@check(cores[1].frequency.has_value && cores[1].frequency.value == (Mhz)2222, "cpu2 keeps its own clock");
	};
}

fn void an_interval_below_the_minimum_is_refused() @test
{
	@pool()
	{
		test::@error(sysinfo::open(mem, { .backend = PROCFS, .interval = time::ms(50) }), error::INVALID_ARGUMENT);
	};
}