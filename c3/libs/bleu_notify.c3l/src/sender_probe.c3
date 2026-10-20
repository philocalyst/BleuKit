module bleu::notify::sender;

<* The sender backend of this platform; defined per platform in the gated sender files. *>
fn SenderDriver* platform_sender_driver()
{
	$switch:
		$case env::LINUX:
			return linux_sender_driver();
		$case env::DARWIN:
			return darwin_sender_driver();
		$case env::WIN32:
			return windows_sender_driver();
		$default:
			unreachable("no notification sender exists for this platform");
	$endswitch
}