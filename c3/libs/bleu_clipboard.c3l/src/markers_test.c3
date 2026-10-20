module bleu::clipboard;
import std::core::test;

fn void concealed_markers_win_over_everything() @test
{
	test::eq(privacy_of({ "text/plain", MARKER_KDE_PASSWORD_HINT }), Privacy.CONCEALED);
	test::eq(privacy_of({ MARKER_NSPASTEBOARD_TRANSIENT, MARKER_NSPASTEBOARD_CONCEALED }), Privacy.CONCEALED);
	test::eq(privacy_of({ MARKER_WINDOWS_EXCLUDE_ALL }), Privacy.CONCEALED);
}

fn void transient_markers_are_transient() @test
{
	test::eq(privacy_of({ MARKER_NSPASTEBOARD_TRANSIENT }), Privacy.TRANSIENT);
	test::eq(privacy_of({ "text/plain", MARKER_WINDOWS_NO_HISTORY }), Privacy.TRANSIENT);
}

fn void ordinary_content_is_open() @test
{
	test::eq(privacy_of({ "text/plain", "image/png" }), Privacy.OPEN);
	test::eq(privacy_of({ }), Privacy.OPEN);
}
