<*
 LockWorkStation (user32.dll). Signature from windows-sys 0.59.0
 (`System/Shutdown/mod.rs`); the Learn page was read, single source (V54).
*>
module bleu::power::windows_lock @feat(WIN32) @link("user32");

extern fn int lockWorkStation() @cname("LockWorkStation");
