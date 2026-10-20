module bleu::notify;

<*
 The notification centre can only be the freedesktop server, which exists on
 Linux. macOS and Windows have no public API that lets a shell replace the
 system's notification UI, so their list is empty and `open` says UNSUPPORTED.
*>
fn Driver*[] platform_drivers()
{
	$switch:
		$case env::LINUX:
			return linux_drivers();
		$default:
			return { };
	$endswitch
}
