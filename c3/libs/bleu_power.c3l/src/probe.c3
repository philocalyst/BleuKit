module bleu::power;

<* Mechanisms for the platform being compiled, best first. Exactly one branch survives preprocessing. *>
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