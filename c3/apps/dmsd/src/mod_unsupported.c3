<*
 The DMS modules with no Bleu service: every method answers `not supported: <why>`,
 and no capability is advertised. Methods come from the DMS handler tables (each
 `core/internal/server/<pkg>/handlers.go` case list, read from DMS master 8be08999):
 cups, tailscale, wellbeing, sysupdate, wallpaper, plugins, themes, registries, and the
 `files.*` methods of dankgo's files package (`dankgo/files/handlers.go`, prefix
 `files.` at DMS `router.go:143`). Streaming forms (`cups.subscribe`,
 `wallpaper.subscribe`) are refused the same way: no stream exists for them here.

 Source of the method names: docs/research/dms_surface.md section 2.3, checked against
 the handler files. Deviations and the reasons: docs/DMSD.md.
*>
module dmsd::unsupported_mod;
import bleu::ipc, dmsd::contract, dmsd::replies;

const String CUPS_REASON      = "not supported: printing is not part of Bleu; no CUPS client is built";
const String TAILSCALE_REASON = "not supported: Bleu has no Tailscale client; tailscaled's local API is not built";
const String WELLBEING_REASON = "not supported: no screen-time service is built into Bleu";
const String SYSUPDATE_REASON = "not supported: no package-update service is built into Bleu";
const String WALLPAPER_REASON = "not supported: no wallpaper service is built into Bleu";
const String FILES_REASON     = "not supported: no file service (listing, thumbnails, trash) is built into Bleu";
const String REGISTRY_REASON  = "not supported: DMS's plugin, theme and registry service is not part of Bleu";

// The refused methods, in DMS's handler order. Each row is one registered method.
const replies::Refusal[76] REFUSALS = {
	{ .method = "cups.subscribe", .text = CUPS_REASON },
	{ .method = "cups.getPrinters", .text = CUPS_REASON },
	{ .method = "cups.getJobs", .text = CUPS_REASON },
	{ .method = "cups.pausePrinter", .text = CUPS_REASON },
	{ .method = "cups.resumePrinter", .text = CUPS_REASON },
	{ .method = "cups.cancelJob", .text = CUPS_REASON },
	{ .method = "cups.purgeJobs", .text = CUPS_REASON },
	{ .method = "cups.getDevices", .text = CUPS_REASON },
	{ .method = "cups.getPPDs", .text = CUPS_REASON },
	{ .method = "cups.getClasses", .text = CUPS_REASON },
	{ .method = "cups.createPrinter", .text = CUPS_REASON },
	{ .method = "cups.deletePrinter", .text = CUPS_REASON },
	{ .method = "cups.acceptJobs", .text = CUPS_REASON },
	{ .method = "cups.rejectJobs", .text = CUPS_REASON },
	{ .method = "cups.setPrinterShared", .text = CUPS_REASON },
	{ .method = "cups.setPrinterLocation", .text = CUPS_REASON },
	{ .method = "cups.setPrinterInfo", .text = CUPS_REASON },
	{ .method = "cups.moveJob", .text = CUPS_REASON },
	{ .method = "cups.printTestPage", .text = CUPS_REASON },
	{ .method = "cups.addPrinterToClass", .text = CUPS_REASON },
	{ .method = "cups.removePrinterFromClass", .text = CUPS_REASON },
	{ .method = "cups.deleteClass", .text = CUPS_REASON },
	{ .method = "cups.restartJob", .text = CUPS_REASON },
	{ .method = "cups.holdJob", .text = CUPS_REASON },
	{ .method = "cups.testConnection", .text = CUPS_REASON },
	{ .method = "tailscale.getStatus", .text = TAILSCALE_REASON },
	{ .method = "tailscale.refresh", .text = TAILSCALE_REASON },
	{ .method = "tailscale.connect", .text = TAILSCALE_REASON },
	{ .method = "tailscale.disconnect", .text = TAILSCALE_REASON },
	{ .method = "tailscale.setExitNode", .text = TAILSCALE_REASON },
	{ .method = "tailscale.setAllowLanAccess", .text = TAILSCALE_REASON },
	{ .method = "wellbeing.getState", .text = WELLBEING_REASON },
	{ .method = "wellbeing.setState", .text = WELLBEING_REASON },
	{ .method = "wellbeing.setLimits", .text = WELLBEING_REASON },
	{ .method = "wellbeing.summary", .text = WELLBEING_REASON },
	{ .method = "wellbeing.clear", .text = WELLBEING_REASON },
	{ .method = "sysupdate.getState", .text = SYSUPDATE_REASON },
	{ .method = "sysupdate.refresh", .text = SYSUPDATE_REASON },
	{ .method = "sysupdate.upgrade", .text = SYSUPDATE_REASON },
	{ .method = "sysupdate.cancel", .text = SYSUPDATE_REASON },
	{ .method = "sysupdate.acquire", .text = SYSUPDATE_REASON },
	{ .method = "sysupdate.release", .text = SYSUPDATE_REASON },
	{ .method = "sysupdate.releases", .text = SYSUPDATE_REASON },
	{ .method = "sysupdate.setInterval", .text = SYSUPDATE_REASON },
	{ .method = "wallpaper.getState", .text = WALLPAPER_REASON },
	{ .method = "wallpaper.setConfig", .text = WALLPAPER_REASON },
	{ .method = "wallpaper.trigger", .text = WALLPAPER_REASON },
	{ .method = "wallpaper.subscribe", .text = WALLPAPER_REASON },
	{ .method = "files.list", .text = FILES_REASON },
	{ .method = "files.watch", .text = FILES_REASON },
	{ .method = "files.unwatch", .text = FILES_REASON },
	{ .method = "files.stat", .text = FILES_REASON },
	{ .method = "files.count", .text = FILES_REASON },
	{ .method = "files.thumbnail", .text = FILES_REASON },
	{ .method = "files.icon", .text = FILES_REASON },
	{ .method = "files.size", .text = FILES_REASON },
	{ .method = "files.sizeCancel", .text = FILES_REASON },
	{ .method = "files.userDirs", .text = FILES_REASON },
	{ .method = "files.mkdir", .text = FILES_REASON },
	{ .method = "files.rename", .text = FILES_REASON },
	{ .method = "files.trash", .text = FILES_REASON },
	{ .method = "plugins.list", .text = REGISTRY_REASON },
	{ .method = "plugins.listInstalled", .text = REGISTRY_REASON },
	{ .method = "plugins.install", .text = REGISTRY_REASON },
	{ .method = "plugins.uninstall", .text = REGISTRY_REASON },
	{ .method = "plugins.update", .text = REGISTRY_REASON },
	{ .method = "plugins.search", .text = REGISTRY_REASON },
	{ .method = "themes.list", .text = REGISTRY_REASON },
	{ .method = "themes.listInstalled", .text = REGISTRY_REASON },
	{ .method = "themes.install", .text = REGISTRY_REASON },
	{ .method = "themes.uninstall", .text = REGISTRY_REASON },
	{ .method = "themes.update", .text = REGISTRY_REASON },
	{ .method = "themes.search", .text = REGISTRY_REASON },
	{ .method = "registries.list", .text = REGISTRY_REASON },
	{ .method = "registries.add", .text = REGISTRY_REASON },
	{ .method = "registries.remove", .text = REGISTRY_REASON },
};

// The module's descriptor for `main`. It has no state, no topic and no capability.
const contract::Module DESCRIPTOR = {
	.name = "unsupported",
	.start = &start,
	.stop = &stop,
};

fn contract::Module descriptor() => DESCRIPTOR;

<* Register the refused methods. Nothing can fail here: the backend is not needed. *>
fn bool start(contract::Context* context, contract::Module* self)
{
	replies::register_all(context.server, REFUSALS[..], &handle_refused)!!;
	return true;
}

// Nothing was started, so there is nothing to stop.
fn void stop(contract::Context* context, contract::Module* self) {}

fn void handle_refused(void* context, ipc::Call* call)
{
	replies::answer(REFUSALS[..], call);
}
