// Table tests for the MCCS codes and value names. Expected names and kinds are
// the ddcutil `vcp_feature_codes.c` entries (`v20_name`, `v20_flags`) and the value
// tables `x60_v2_input_source_values` and `xd6_power_mode_values`.
module bleu::ddc::vcp_test;
import bleu::ddc::vcp;

fn void feature_lookup_returns_name_kind_and_access() @test
{
	vcp::VcpFeature f = vcp::feature(vcp::VcpCode.CONTRAST)!!;
	test::eq(f.name, "Contrast");
	test::eq(f.kind, vcp::VcpKind.CONTINUOUS);
	test::eq(f.access, vcp::VcpAccess.READ_WRITE);
	vcp::VcpFeature vf = vcp::feature(vcp::VcpCode.VCP_VERSION)!!;
	test::eq(vf.access, vcp::VcpAccess.READ_ONLY);
	test::@error(vcp::feature((vcp::VcpCode)0x77), NOT_FOUND);
}

fn void every_table_entry_is_unique() @test
{
	foreach (i, &a : vcp::FEATURES)
	{
		foreach (j, &b : vcp::FEATURES)
		{
			if (i != j) test::eq(a.code != b.code, true);
		}
	}
}

fn void input_source_names_follow_mccs_2_2() @test
{
	test::eq(vcp::input_source_name(0x0F)!!, "DisplayPort-1");
	test::eq(vcp::input_source_name(0x11)!!, "HDMI-1");
	test::eq(vcp::input_source_name(0x12)!!, "HDMI-2");
	test::eq(vcp::input_source_name(0x01)!!, "VGA-1");
	// 0x1B is not in the MCCS table ddcutil reproduces, so it is not named here.
	test::@error(vcp::input_source_name(0x1B), NOT_FOUND);
}

fn void power_mode_values() @test
{
	test::eq(vcp::power_mode_name((char)vcp::PowerMode.ON)!!, "DPM: On, DPMS: Off");
	test::eq(vcp::power_mode_name((char)vcp::PowerMode.OFF_SOFT)!!, "DPM: Off, DPMS: Off");
	test::eq(vcp::power_mode_name((char)vcp::PowerMode.OFF_HARD)!!, "Write only value to turn off display");
	test::@error(vcp::power_mode_name(0x09), NOT_FOUND);
}
