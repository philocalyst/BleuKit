// Golden tests for the Linux text parsers. The fixtures are real output of this
// sandbox's kernel (proc_*.txt, os_release.txt, ...), see fixtures/README in the
// library. Synthetic inputs are marked as such.
module bleu::sysinfo::procfs_test;
import std::core::test, std::time, bleu::error, bleu::sysinfo, bleu::sysinfo::procfs;

fn String fixture_stat() @local => (String)$embed("../fixtures/proc_stat.txt");
fn String fixture_meminfo() @local => (String)$embed("../fixtures/proc_meminfo.txt");
fn String fixture_loadavg() @local => (String)$embed("../fixtures/proc_loadavg.txt");
fn String fixture_uptime() @local => (String)$embed("../fixtures/proc_uptime.txt");
fn String fixture_net_dev() @local => (String)$embed("../fixtures/proc_net_dev.txt");
fn String fixture_mounts() @local => (String)$embed("../fixtures/proc_mounts.txt");
fn String fixture_pid_stat() @local => (String)$embed("../fixtures/proc_pid_stat.txt");
fn String fixture_pid_status() @local => (String)$embed("../fixtures/proc_pid_status.txt");
fn String fixture_cmdline() @local => (String)$embed("../fixtures/pid_cmdline.bin");
fn String fixture_cpuinfo() @local => (String)$embed("../fixtures/proc_cpuinfo_first.txt");
fn String fixture_os_release() @local => (String)$embed("../fixtures/os_release.txt");
fn String fixture_passwd() @local => (String)$embed("../fixtures/etc_passwd_sample.txt");

// The aggregate line of the sample: user 164409, nice 0, system 86305, idle 1273691,
// iowait 1377, irq 0, softirq 9600, steal 7342 (USER_HZ ticks).
fn void stat_aggregate_and_cores() @test
{
	@pool()
	{
		delta::CpuLine[] lines = procfs::parse_stat(fixture_stat(), tmem)!!;
		test::eq(lines.len, 5);
		test::eq(lines[0].index, -1);
		test::eq(lines[0].ticks.busy, 164409UL + 86305 + 9600);
		test::eq(lines[0].ticks.total, 164409UL + 86305 + 9600 + 1273691 + 1377);
		test::eq(lines[1].index, 0);
		test::eq(lines[1].ticks.busy, 40917UL + 21002 + 4900);
		test::eq(lines[4].index, 3);
	};
}

fn void stat_without_aggregate_is_refused() @test
{
	@pool()
	{
		test::@error(procfs::parse_stat("cpu0 1 0 1 1 0 0 0 0\n", tmem), error::PROTOCOL);
		test::@error(procfs::parse_stat("cpu  1 0 1\n", tmem), error::PROTOCOL);
	};
}

fn void meminfo_matches_the_sample() @test
{
	@pool()
	{
		MemInfo info = procfs::parse_meminfo(fixture_meminfo())!!;
		test::eq(info.total, 16479424UL * 1024);
		test::eq(info.available, 15472216UL * 1024);
		test::eq(info.swap_total, 0UL);
		test::eq(info.shmem, 14968UL * 1024);
		test::eq(info.buffers + info.cached + info.sreclaimable - info.shmem, (103580UL + 1469600 + 119360 - 14968) * 1024);
	};
}

// Synthetic: a kernel before 3.14 has no MemAvailable, so available is estimated as
// free + buffers + cached + sreclaimable - shmem = 100 + 50 + 200 + 30 - 20 kB.
fn void meminfo_without_available_is_estimated() @test
{
	@pool()
	{
		String text = "MemTotal: 1000 kB\nMemFree: 100 kB\nBuffers: 50 kB\nCached: 200 kB\nSReclaimable: 30 kB\nShmem: 20 kB\nSwapTotal: 8 kB\nSwapFree: 2 kB\n";
		MemInfo info = procfs::parse_meminfo(text)!!;
		test::eq(info.available, 360UL * 1024);
		test::eq(info.swap_total - info.swap_free, 6UL * 1024);
	};
}

fn void meminfo_without_total_is_refused() @test
{
	@pool()
	{
		test::@error(procfs::parse_meminfo("MemFree: 1 kB\n"), error::PROTOCOL);
	};
}

fn void loadavg_and_uptime() @test
{
	@pool()
	{
		LoadAverage[3] averages = procfs::parse_loadavg(fixture_loadavg())!!;
		test::eq_approx((double)averages[0], 1.23, 2);
		test::eq_approx((double)averages[2], 0.83, 2);
		// 3855.92 s is 3 855 920 000 µs.
		test::eq(procfs::parse_uptime(fixture_uptime())!!, (Duration)3_855_920_000);
		test::eq(procfs::parse_uptime("12\n")!!, (Duration)12_000_000);
		test::@error(procfs::parse_loadavg("x 1 2\n"), error::PROTOCOL);
	};
}

fn void net_dev_reports_bytes_and_skips_loopback() @test
{
	@pool()
	{
		delta::NetCounters[] interfaces = procfs::parse_net_dev(fixture_net_dev(), tmem)!!;
		test::eq(interfaces.len, 3);
		delta::NetCounters eth0 = interfaces[2];
		test::@check(eth0.name == "eth0", "last interface is eth0");
		test::eq(eth0.received, 441342218UL);
		test::eq(eth0.sent, 156218907UL);
		foreach (counters : interfaces)
		{
			test::@check(counters.name != "lo", "loopback is not reported");
		}
	};
}

fn void mounts_decode_octal_escapes() @test
{
	@pool()
	{
		RawMount[] mounts = procfs::parse_mounts(fixture_mounts(), tmem)!!;
		test::@check(mounts.len == 26, "one entry per line");
		test::@check(mounts[0].fs_type == "proc" && mounts[0].mount_point == "/proc", "first line of the sample");
		// Synthetic: a space in a mount point is written \040 by the kernel.
		RawMount[] spaced = procfs::parse_mounts("/dev/sdb1 /media/My\\040Disk ext4 rw 0 0\n", tmem)!!;
		test::@check(spaced[0].mount_point == "/media/My Disk", "octal space decoded");
		test::@check(procfs::unescape_octal("a\\134b", tmem)!! == "a\\b", "backslash decoded");
	};
}

fn void only_real_disks_are_local() @test
{
	@pool()
	{
		test::@check(procfs::is_local_disk("/dev/vda"), "virtual disk");
		test::@check(!procfs::is_local_disk("/dev/loop3"), "snap or image loop device");
		test::@check(!procfs::is_local_disk("tmpfs"), "pseudo filesystem source");
		test::@check(!procfs::is_local_disk("proc"), "procfs source");
	};
}

fn void pid_stat_of_a_real_process() @test
{
	@pool()
	{
		StatFields fields = procfs::parse_pid_stat(fixture_pid_stat())!!;
		test::@check(fields.name == "cp", "command name between the parentheses");
		test::eq(fields.utime, 0UL);
		test::eq(fields.started, 385593UL);
	};
}

// Synthetic: the command name holds spaces and parentheses, which the parser must not split on.
fn void pid_stat_with_a_hostile_name() @test
{
	@pool()
	{
		String text = "42 (my (odd) name) S 1 42 42 0 -1 0 0 0 0 0 5 7 0 0 20 0 1 0 999\n";
		StatFields fields = procfs::parse_pid_stat(text)!!;
		test::@check(fields.name == "my (odd) name", "name is everything between the first ( and the last )");
		test::eq(fields.utime, 5UL);
		test::eq(fields.stime, 7UL);
		test::eq(fields.started, 999UL);
	};
}

fn void pid_status_has_uid_and_rss() @test
{
	@pool()
	{
		StatusFields fields = procfs::parse_status(fixture_pid_status())!!;
		test::eq(fields.uid, 0UL);
		test::@check(fields.has_rss, "a user process has a resident set");
		test::eq(fields.rss, 2064UL * 1024);
		// Synthetic: a kernel thread has a Uid line but no VmRSS line.
		StatusFields kernel = procfs::parse_status("Name:\tkthreadd\nUid:\t0\t0\t0\t0\n")!!;
		test::@check(!kernel.has_rss, "kernel thread has no resident set");
	};
}

fn void command_line_joins_arguments() @test
{
	@pool()
	{
		String text = procfs::command_line(fixture_cmdline(), tmem);
		test::@check(text == "cat -n /etc/os-release", "NUL separators become spaces");
		String empty = procfs::command_line("", tmem);
		test::@check(empty == "", "a kernel thread has no command line");
	};
}

fn void cpu_model_and_os_name() @test
{
	@pool()
	{
		String model = procfs::cpuinfo_model(fixture_cpuinfo(), tmem);
		test::@check(model == "Intel(R) Xeon(R) Processor @ 2.80GHz", "model name line");
		String pretty = procfs::os_release_value(fixture_os_release(), "PRETTY_NAME", tmem);
		test::@check(pretty == "Ubuntu 24.04.5 LTS", "quotes removed from PRETTY_NAME");
		test::@check(procfs::os_release_value(fixture_os_release(), "NOPE", tmem) == "", "absent key is empty");
	};
}

fn void passwd_maps_uid_to_name() @test
{
	@pool()
	{
		test::@check(procfs::passwd_name(fixture_passwd(), 0)!! == "root", "uid 0");
		test::@check(procfs::passwd_name(fixture_passwd(), 65534)!! == "nobody", "uid 65534");
		test::@error(procfs::passwd_name(fixture_passwd(), 999), NOT_FOUND);
	};
}

fn void sysfs_names_and_millidegrees() @test
{
	@pool()
	{
		test::eq(procfs::numbered_name("temp3_input", "temp", "_input")!!, 3);
		test::eq(procfs::numbered_name("thermal_zone12", "thermal_zone", "")!!, 12);
		test::@error(procfs::numbered_name("temp_input", "temp", "_input"), NOT_FOUND);
		test::@error(procfs::numbered_name("temp1_label", "temp", "_input"), NOT_FOUND);
		test::eq_approx((double)procfs::celsius_from_millidegrees("45500")!!, 45.5, 3);
		test::@error(procfs::celsius_from_millidegrees("warm"), error::PROTOCOL);
	};
}

