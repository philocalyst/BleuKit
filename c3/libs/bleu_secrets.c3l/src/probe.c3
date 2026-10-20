module bleu::secrets;

<* Backends for the platform being compiled, best first. *>
fn Driver*[] platform_drivers()
{
	$if env::LINUX:
		return linux_drivers();
	$else
		return { };
	$endif
}
