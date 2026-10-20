// Capabilities parser tests. The strings are monitors that ddcutil uses in its
// own tests (`src/vcp/parse_capabilities.c`, `test_cap_strings`: the Wacom One
// 13 and the Asus PB287 entries), plus strings built for each tolerated
// irregularity. Expected results were written by hand from each string before
// the parser was run.
module bleu::ddc::capabilities_test;
import std::core::mem, bleu::ddc::vcp, bleu::ddc::capabilities;

fn bool contains(char[] list, char value) @private
{
	foreach (c : list)
	{
		if (c == value) return true;
	}
	return false;
}

fn bool same_bytes(char[] a, char[] b) @private
{
	return a.len == b.len && mem::equals(a.ptr, b.ptr, a.len);
}

fn void wacom_one_13() @test
{
	@pool()
	{
		Capabilities caps = capabilities::parse(string::tformat("%s%s%s%s%s", "(prot(monitor)type(LCD)model(Wacom One 13)cmds(01 02 03 06 07 E3 F3)", "vcp(04 05 08 12 14(04 05 06 08 0B) 16 18 1A 6B AC AE B2 B6 C8 C9 ", "CC(01 02 03 04 05 06 07 08 09 0A 0D 14 1E 26) D6(01 04 ) DA(00 01) DF", " E1(00 01 02) E4(04 05 06 08 0B) EF(00 01 02 03) F2)", "mswhql(1)asset_eep(40)mccs_ver(2.2))"), tmem);
		test::eq(caps.validity, capabilities::Validity.VALID);
		test::eq(caps.model, "Wacom One 13");
		test::eq(caps.mccs_version, "2.2");
		test::eq(same_bytes(caps.commands, { 0x01, 0x02, 0x03, 0x06, 0x07, 0xE3, 0xF3 }), true);
		test::eq(caps.features.len, (sz)23);
		test::eq(caps.supports(VcpCode.CONTRAST), true);
		test::eq(caps.supports(VcpCode.SELECT_COLOR_PRESET), true);
		test::eq(caps.supports(VcpCode.INPUT_SOURCE), false);
		// 0x14 lists five values; 0x12 has no list, so its value list is empty.
		test::eq(same_bytes(caps.allowed_values(VcpCode.SELECT_COLOR_PRESET)!!, { 0x04, 0x05, 0x06, 0x08, 0x0B }), true);
		test::eq(caps.allowed_values(VcpCode.CONTRAST)!!.len, (sz)0);
		test::eq(caps.allowed_values((VcpCode)0xDF)!!.len, (sz)0);
		// 0xCC lists 14 values.
		test::eq(caps.allowed_values((VcpCode)0xCC)!!.len, (sz)14);
		// 0xD6 lists two values, the trailing blank before ')' is not a value.
		test::eq(same_bytes(caps.allowed_values(VcpCode.POWER_MODE)!!, { 0x01, 0x04 }), true);
		test::@error(caps.allowed_values(VcpCode.INPUT_SOURCE), NOT_FOUND);
	};
}

fn void asus_pb287_bare_model() @test
{
	@pool()
	{
		// "model LCDPB287" has no parentheses. The value is taken as the next word
		// and the result is USABLE, not INVALID.
		Capabilities caps = capabilities::parse(string::tformat("%s%s%s%s", "(prot(monitor) type(LCD)model LCDPB287 cmds(01 02 03 07 0C F3) ", "vcp(02 04 05 08 0B 0C 10 12 14(05 06 08 0B) 16 18 1A 60(11 12 0F) ", "62 6C 6E 70 8D(01 02) A8 AC AE B6 C6 C8 C9 D6(01 04) DF) ", "mccs_ver(2.1)asset_eep(32)mpu(01)mswhql(1))"), tmem);
		test::eq(caps.validity, capabilities::Validity.USABLE);
		test::eq(caps.model, "LCDPB287");
		test::eq(caps.mccs_version, "2.1");
		test::eq(same_bytes(caps.allowed_values(VcpCode.INPUT_SOURCE)!!, { 0x11, 0x12, 0x0F }), true);
		test::eq(caps.supports((VcpCode)0xA8), true);
		test::eq(caps.commands.len, (sz)6);
	};
}

fn void run_together_codes_and_values() @test
{
	@pool()
	{
		// Codes and values run together, as the Access.bus specification allows.
		Capabilities caps = capabilities::parse(string::tformat("%s%s", "(vcp(0203(10 00)0405080B0C101214(05 07 08 0B) 16181A5260(3033 04)6C6E70", "87ACAEB6C0C6C8C9D6(01 04)DFE4E5E6E7E8E9EAEBED(00 10 20 40)EE(00 01)FE(01 02 03)FF)mccs_ver(2.1))"), tmem);
		test::eq(caps.validity, capabilities::Validity.VALID);
		test::eq(caps.supports((VcpCode)0x02), true);
		test::eq(caps.allowed_values((VcpCode)0x02)!!.len, (sz)0);
		test::eq(same_bytes(caps.allowed_values((VcpCode)0x03)!!, { 0x10, 0x00 }), true);
		test::eq(same_bytes(caps.allowed_values((VcpCode)0x14)!!, { 0x05, 0x07, 0x08, 0x0B }), true);
		// The list "(3033 04)" belongs to 0x60 and is three values: 30, 33, 04.
		test::eq(same_bytes(caps.allowed_values((VcpCode)0x60)!!, { 0x30, 0x33, 0x04 }), true);
		test::eq(same_bytes(caps.allowed_values((VcpCode)0xD6)!!, { 0x01, 0x04 }), true);
		test::eq(same_bytes(caps.allowed_values((VcpCode)0xED)!!, { 0x00, 0x10, 0x20, 0x40 }), true);
		test::eq(caps.supports((VcpCode)0xFF), true);
		test::eq(caps.mccs_version, "2.1");
	};
}

fn void unbalanced_values_keep_codes_read_so_far() @test
{
	@pool()
	{
		// The outer parenthesis closes "vcp(" too early, so the vcp value is cut off
		// after "14(05 06 16". The codes before it survive.
		Capabilities caps = capabilities::parse("(vcp(10 12 14(05 06 16)", tmem);
		test::eq(caps.validity, capabilities::Validity.INVALID);
		test::eq(caps.supports(VcpCode.LUMINANCE), true);
		test::eq(caps.supports(VcpCode.CONTRAST), true);
		test::eq(same_bytes(caps.allowed_values(VcpCode.SELECT_COLOR_PRESET)!!, { 0x05, 0x06, 0x16 }), true);
		test::eq(caps.problem.len > 0, true);
	};
}

fn void truncated_mid_list_is_invalid() @test
{
	@pool()
	{
		// A flaky monitor sends the string cut in the middle of a value list.
		Capabilities caps = capabilities::parse("(prot(monitor)vcp(10 12 14(05 0", tmem);
		test::eq(caps.validity, capabilities::Validity.INVALID);
		test::eq(caps.supports(VcpCode.LUMINANCE), true);
		test::eq(caps.supports(VcpCode.CONTRAST), true);
		test::eq(same_bytes(caps.allowed_values(VcpCode.SELECT_COLOR_PRESET)!!, { 0x05 }), true);
	};
}

fn void missing_outer_parenthesis_is_invalid() @test
{
	@pool()
	{
		Capabilities caps = capabilities::parse("(prot(monitor)vcp(10 12)", tmem);
		test::eq(caps.validity, capabilities::Validity.INVALID);
		test::eq(caps.supports(VcpCode.CONTRAST), true);
	};
}

fn void vendor_segment_with_nested_parentheses_is_skipped() @test
{
	@pool()
	{
		Capabilities caps = capabilities::parse("(vcpname(E0 (nested) E1)vcp(10 12)mccs_ver(2.2))", tmem);
		test::eq(caps.validity, capabilities::Validity.VALID);
		test::eq(caps.features.len, (sz)2);
		test::eq(caps.supports((VcpCode)0xE0), false);
	};
}

fn void string_without_vcp_segment_is_usable() @test
{
	@pool()
	{
		Capabilities caps = capabilities::parse("(prot(monitor)type(LCD)model(X)cmds(01 F3))", tmem);
		test::eq(caps.validity, capabilities::Validity.USABLE);
		test::eq(caps.features.len, (sz)0);
		test::eq(caps.supports(VcpCode.LUMINANCE), false);
		test::eq(same_bytes(caps.commands, { 0x01, 0xF3 }), true);
		test::eq(caps.problem, "no vcp segment");
	};
}

fn void string_without_outer_parentheses() @test
{
	@pool()
	{
		// Apple Cinema Display: the whole string has no outer parentheses.
		Capabilities caps = capabilities::parse("prot(monitor)vcp(10)", tmem);
		test::eq(caps.validity, capabilities::Validity.VALID);
		test::eq(caps.supports(VcpCode.LUMINANCE), true);
	};
}

fn void invalid_code_is_skipped_with_its_list() @test
{
	@pool()
	{
		Capabilities caps = capabilities::parse("(vcp(10 ZZ(01) 12))", tmem);
		test::eq(caps.validity, capabilities::Validity.USABLE);
		test::eq(caps.features.len, (sz)2);
		test::eq(caps.supports(VcpCode.CONTRAST), true);
		test::eq(caps.supports((VcpCode)0x01), false);
	};
}

fn void repeated_code_is_kept_once() @test
{
	@pool()
	{
		Capabilities caps = capabilities::parse("(vcp(10 10 12))", tmem);
		test::eq(caps.validity, capabilities::Validity.USABLE);
		test::eq(caps.features.len, (sz)2);
	};
}

fn void nul_padding_and_blanks_are_ignored() @test
{
	@pool()
	{
		Capabilities caps = capabilities::parse("(vcp(10 12))\0\0  ", tmem);
		test::eq(caps.validity, capabilities::Validity.VALID);
		test::eq(caps.features.len, (sz)2);
	};
}

fn void odd_length_command_token_is_dropped() @test
{
	@pool()
	{
		// "E33" has an odd number of digits: that token is dropped, the rest is kept.
		Capabilities caps = capabilities::parse("(cmds(01 02 E33 F3)vcp(10))", tmem);
		test::eq(caps.validity, capabilities::Validity.USABLE);
		test::eq(same_bytes(caps.commands, { 0x01, 0x02, 0xF3 }), true);
		test::eq(caps.supports(VcpCode.LUMINANCE), true);
	};
}

fn void empty_string_has_no_features() @test
{
	@pool()
	{
		Capabilities caps = capabilities::parse("", tmem);
		test::eq(caps.validity, capabilities::Validity.USABLE);
		test::eq(caps.features.len, (sz)0);
		test::eq(caps.commands.len, (sz)0);
	};
}
