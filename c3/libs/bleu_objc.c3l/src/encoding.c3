<*
 Objective-C type encodings for C3 types, built at compile time.

 This module is pure compile-time logic with no `@feat`, so every target compiles
 it and its `@test`s run on Linux. `class.c3` (Darwin only) uses `signature` to
 register methods.

 Sources: Apple objc4 `runtime/objc.h` (the `OBJC_BOOL_IS_BOOL` rule, which defers
 to `__OBJC_BOOL_IS_BOOL`) and clang `lib/Frontend/InitPreprocessor.cpp:998-999`
 and `lib/Basic/Targets/AArch64.cpp:1915` (arm64 Darwin BOOL is `_Bool`, x86_64 is
 `signed char`). The other codes follow the `@encode` table in the Objective-C
 runtime programming guide.
*>
module bleu::objc::encoding;
import std::os::darwin::objc;

<*
 The Objective-C type code for a C3 type, at compile time.

 Mapping (from `@encode`): void `v`, C3 `bool` `B` on arm64 and `c` on x86_64
 (BOOL is C `_Bool` on arm64 macOS and `signed char` on x86_64 macOS), signed integers `c s i q` by size,
 unsigned integers `C S I Q`, `float` `f`, `double` `d`, pointers `@`, and SEL `:`.
 Pointers are encoded as objects because almost every AppKit, CoreWLAN and
 CoreAudio callback argument is an `id`. A raw `void*` argument must be
 documented at the call site. Typedefs are looked through. Any other type is
 a compile-time error, so a struct cannot silently get a wrong encoding.

 `ObjSel` is a typedef of `void*`, so the SEL test compares the type by name. It
 exists only on Darwin, so the test is compiled only there.
*>
macro ZString type_code($Type)
{
	$switch $Type::kind:
		$case VOID:
			return "v";
		$case BOOL:
			$if $feat(AARCH64):
				return "B";
			$else
				return "c";
			$endif
		$case SIGNED_INT:
			$switch $Type::size:
				$case 1:
					return "c";
				$case 2:
					return "s";
				$case 4:
					return "i";
				$default:
					return "q";
			$endswitch
		$case UNSIGNED_INT:
			$switch $Type::size:
				$case 1:
					return "C";
				$case 2:
					return "S";
				$case 4:
					return "I";
				$default:
					return "Q";
			$endswitch
		$case FLOAT:
			$if $Type::size == 4:
				return "f";
			$else return "d";
		$endif
	$case POINTER:
		return "@";
	$case TYPEDEF:
		$if $feat(DARWIN):
			$if $Type == ObjSel:
				return ":";
			$endif
		$endif
		return type_code($Type::inner);
	$default:
		$error "bleu::objc: no Objective-C type encoding for this C3 type";
$endswitch
}

<*
 A complete method type encoding, built at compile time from the return type
 and sample values for the explicit arguments. Samples are typed casts such as
 `(bool)false` or `(void*)null`; only their types are read. The receiver (`@`)
 and the selector (`:`) are implied.

 signature(void, (void*)null)       // "v@:@"   e.g. windowWillClose:
 signature(double)                  // "d@:"
 signature(int, (ulong)0)           // "i@:Q"

 @param $Ret : "The C3 return type (`void` for no return)"
 @return "A compile-time string literal"
*>
macro ZString signature($Ret, ...)
{
	var $string = "";
	$string = $string +++ @sprintf("%s", type_code($Ret));
	$string = $string +++ "@:";
	$for sz $i = 0; $i < $vaarg.len; $i++:
		$string = $string +++ @sprintf("%s", type_code($Typeof($vaarg[$i])));
	$endfor
	return $string;
}