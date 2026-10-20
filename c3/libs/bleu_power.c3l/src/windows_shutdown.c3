<*
 InitiateSystemShutdownExW (advapi32.dll). Signature from windows-sys 0.59.0
 (`System/Shutdown/mod.rs`); single source for the semantics (V52).
*>
module bleu::power::windows_shutdown @feat(WIN32) @link("advapi32");

extern fn int initiateSystemShutdownExW(
	void* machine,
	void* message,
	uint timeout_seconds,
	int force_apps_closed,
	int reboot_after,
	uint reason
) @cname("InitiateSystemShutdownExW");
