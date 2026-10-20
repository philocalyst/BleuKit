module bleu::sysinfo;

<* Backends for the platform being compiled, best first. *>
fn Driver*[] platform_drivers()
{
	$if env::LINUX:
		return linux_drivers();
	$else
		$if env::DARWIN:
			return macos_drivers();
		$else
			$if env::WIN32:
				return windows_drivers();
			$else
				return { };
			$endif
		$endif
	$endif
}