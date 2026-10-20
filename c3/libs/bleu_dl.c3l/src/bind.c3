// A table is a plain struct. Each member is a function-pointer type annotated
// with the C symbol it stands for, with a tag:
//
//     alias GetBrightnessFn = fn int(uint display, float* out);
//     alias SetBrightnessFn = fn int(uint display, float value);
//     struct DisplayServices
//     {
//         GetBrightnessFn get_brightness @tag("sym", "DisplayServicesGetBrightness");
//         SetBrightnessFn set_brightness @tag("sym", "DisplayServicesSetBrightness")
//                                        @tag("optional", "true");
//     }
//
//     DisplayServices api;
//     dl::bind(&api, &library)!;
//
// Members are resolved at compile time from the struct's reflection ($foreach
// over the members, get_tag, has_tag), so adding a symbol is one line and no
// separate table of names is kept by hand.
//
// Why a tag and not a parallel array of names: struct members carry @tag in
// 0.8.5 (MANUAL 7_4 Reflection, 7_2 @tag), so the symbol sits beside the member
// it binds and a mismatched name list cannot compile.
//
// Why an alias and not an inline function type: 0.8.5 rejects a function type
// written directly as a member declaration; the alias is accepted.
//
// Calling convention: the Windows x86-64 and AArch64 targets have a single
// calling convention, which C3's default `fn` matches. 32-bit stdcall is out of
// scope.
module bleu::dl;
import bleu::error, bleu::dl::native;

<*
 Resolve every member of `table` from `library`, in declaration order. A
 failed bind leaves every member null.

 @param table : "Pointer to a struct whose members are function pointers, each with a sym tag naming its C symbol"
 @param library : "The library to resolve from; it must stay loaded while the table is used"
 @return? error::UNSUPPORTED : "A required member's symbol is missing; the message names both"
*>
macro void? bind(table, library)
{
	*table = {};
	$foreach $member : $Typeof(*table)::members:
		$if !$member.has_tag("sym"):
			$error "every member of a bound table needs @tag(\"sym\", \"<C symbol>\")";
		$endif
		{
			const String SYMBOL = $member.get_tag("sym");
			void* address = library.find(SYMBOL);
			$if $member.has_tag("optional") &&& $member.get_tag("optional") == "true":
				// An absent optional symbol stays null: the caller decides what that means.
			$else
				if (!address)
				{
					*table = {};
					return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0,
						"required symbol '%s' (member '%s') is not exported by %s",
						SYMBOL, $member.name, library.name)~;
				}
			$endif
			table.$member = ($Typefrom($member.type))address;
		}
	$endforeach
}

// Usage (the trailing block receives the two names):
//
//     each_unbound(&api; String member, String symbol)
//     {
//         io::printfn("%s is not available: %s", member, symbol);
//     };
<*
 Visit every optional member that did not resolve, in declaration order.
 The block receives the member's name and the C symbol it wanted. A backend
 uses it to say exactly which part of a capability is missing.

 @param table : "Pointer to a table that has been through bind"
*>
macro @each_unbound(table; @body(String member, String symbol))
{
	$foreach $member : $Typeof(*table)::members:
		$if $member.has_tag("optional") &&& $member.get_tag("optional") == "true":
			if (!table.$member) @body($member.name, $member.get_tag("sym"));
		$endif
	$endforeach
}
