// With no portal on the bus the portal backend is refused, and automatic selection finds nothing.
module bleu::hotkey::portal_absent_test @feat(LINUX);
import bleu::error, bleu::hotkey;

fn void without_a_portal_the_backend_is_refused() @test
{
	assert(@catch(hotkey::open(mem, { .backend = PORTAL })) == error::UNSUPPORTED, "a forced backend that is not there");
	assert(@catch(hotkey::open(mem)) == error::UNAVAILABLE, "no backend at all");
}
