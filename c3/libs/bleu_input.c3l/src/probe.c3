<*
 The backends of the platform being compiled, best first.
*>
module bleu::input;

<* Backends for the platform being compiled, best first; defined per platform in its own file. *>
fn Driver*[] platform_drivers()
{
	$switch:
		$case env::LINUX:
			return linux_drivers();
		$case env::DARWIN:
			return darwin_drivers();
		$case env::WIN32:
			return windows_drivers();
		$default:
			return { };
	$endswitch
}