// Run with no UPower on the bus (run.sh stops the mock first): the backend must refuse.
module bleu::battery::upower_absent_test @feat(LINUX);
import std::time, bleu::battery, bleu::error;

fn void without_the_name_the_backend_is_refused() @test
{
	assert(@catch(battery::open(mem, { .backend = UPOWER, .poll = time::ms(50) })) == error::UNSUPPORTED);
}

fn void a_fake_tree_is_sysfs_only() @test
{
	assert(@catch(battery::open(mem, { .backend = UPOWER, .root = "/nonexistent-root" })) == error::UNSUPPORTED);
}