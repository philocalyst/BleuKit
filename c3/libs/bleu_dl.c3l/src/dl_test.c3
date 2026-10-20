<*
 Tests run on the host with real system libraries. The candidates are the C
 library and libm, which every target ships under a known name.
*>
module bleu::dl::tests;
import bleu::dl, bleu::dl::lazy, bleu::error;

alias StrlenFn = fn usz(ZString s);
alias CosFn = fn double(double x);
alias NoSuchFn = fn int(int x);

struct LibcTable
{
	StrlenFn c_strlen @tag("sym", "strlen");
	NoSuchFn missing @tag("sym", "bleu_dl_no_such_symbol") @tag("optional", "true");
}

struct LibmTable
{
	CosFn cos_of @tag("sym", "cos");
}

struct RequiredMissingTable
{
	StrlenFn c_strlen @tag("sym", "strlen");
	NoSuchFn absent @tag("sym", "bleu_dl_no_such_symbol");
}

// The C library's file name differs per platform; the symbols used here exist in all of them.
fn String libc_name()
{
	$switch:
		$case $feat(WIN32):
			return "ucrtbase.dll";
		$case $feat(DARWIN):
			return "/usr/lib/libSystem.B.dylib";
		$default:
			return "libc.so.6";
	$endswitch
}

fn String libm_name()
{
	$switch:
		$case $feat(WIN32):
			return "ucrtbase.dll";
		$case $feat(DARWIN):
			return "/usr/lib/libSystem.B.dylib";
		$default:
			return "libm.so.6";
	$endswitch
}

fn void open_resolves_symbols() @test
{
	String[] names = { libc_name() };
	Library lib    = dl::open(names)!!;
	defer lib.close();
	assert(lib.has("strlen"));
	assert(!lib.has("bleu_dl_no_such_symbol"));
	assert(lib.name() == libc_name());
}

fn void bind_fills_members_and_reports_optional_gaps() @test
{
	String[] names = { libc_name() };
	Library lib    = dl::open(names)!!;
	defer lib.close();

	LibcTable table;
	dl::bind(&table, &lib)!!;
	assert(table.c_strlen("bleu") == 4);
	assert(table.missing == null);

	int unbound = 0;
	dl::@each_unbound(&table ; String member, String symbol)
	{
		assert(member == "missing");
		assert(symbol == "bleu_dl_no_such_symbol");
		unbound++;
	};
	assert(unbound == 1);
}

fn void bind_of_required_missing_symbol_fails_and_clears_table() @test
{
	String[] names = { libc_name() };
	Library lib    = dl::open(names)!!;
	defer lib.close();

	RequiredMissingTable table;
	if (catch err = dl::bind(&table, &lib))
	{
		assert(err == error::UNSUPPORTED);
		assert(error::last().status == error::Status.UNSUPPORTED);
		assert(error::last().message().contains("bleu_dl_no_such_symbol"));
		assert(error::last().message().contains("absent"));
	}
	else
	{
		unreachable("binding a missing required symbol must fail");
	}
	assert(table.c_strlen == null);
	assert(table.absent == null);
}

fn void open_failure_names_the_last_candidate() @test
{
	String[] names = { "libbleu_dl_no_such.so.9", "/nonexistent/dir/libbleu_dl_no.so" };
	if (catch err = dl::open(names))
	{
		assert(err == error::UNAVAILABLE);
		assert(error::last().status == error::Status.UNAVAILABLE);
		assert(error::last().message().contains("2 candidate(s)"));
		assert(error::last().message().contains("/nonexistent/dir/libbleu_dl_no.so"));
	}
	else
	{
		unreachable("no candidate exists, so open must fail");
	}
}

fn void symbol_lookup_failure_is_not_found() @test
{
	String[] names = { libc_name() };
	Library lib    = dl::open(names)!!;
	defer lib.close();
	if (catch err = lib.symbol("bleu_dl_no_such_symbol"))
	{
		assert(err == NOT_FOUND);
		assert(error::last().message().contains("bleu_dl_no_such_symbol"));
	}
	else
	{
		unreachable("the symbol does not exist");
	}
}

fn void libm_resolves_a_second_library() @test
{
	String[] names = { libm_name() };
	Library lib    = dl::open(names)!!;
	defer lib.close();
	LibmTable table;
	dl::bind(&table, &lib)!!;
	assert(table.cos_of(0.0) == 1.0);
}

fn void main_program_exposes_libc_on_posix() @test
{
	$if env::POSIX:
		Library program = dl::main_program()!!;
		defer program.close();
		assert(program.has("strlen"));
	$endif
}

// One shared table, bound on first use; the lazy instance is a module global, as in services.
lazy::Lazy{LibcTable} shared_libc;
lazy::Lazy{RequiredMissingTable} shared_missing;

fn void lazy_binds_once_and_shares_the_table() @test
{
	String[] names    = { libc_name() };
	LibcTable* first  = shared_libc.get(names)!!;
	LibcTable* second = shared_libc.get(names)!!;
	assert(first == second);
	assert(first.c_strlen("abc") == 3);
}

fn void lazy_caches_a_failed_bind() @test
{
	String[] names = { libc_name() };
	if (catch shared_missing.get(names))
	{
	} // the failure itself is what this test checks
	if (catch err = shared_missing.get(names))
	{
		assert(err == error::UNSUPPORTED);
		assert(error::last().message().contains("absent"));
	}
	else
	{
		unreachable("the required symbol is missing, so the cached outcome is a failure");
	}
}