// Location Services authorization, which decides whether CoreWLAN shows SSIDs
// and BSSIDs. Not run on macOS (see corewlan.c3).
//
// CLAuthorizationStatus values: CoreLocation's CLLocationManager.h (notDetermined 0,
// restricted 1, denied 2, authorizedAlways 3, authorizedWhenInUse 4). The
// class method `authorizationStatus` is the one present in every macOS the
// project targets; from macOS 11 the instance property replaces it, so this
// read is UNVERIFIED on current systems and should be checked on a Mac.
module bleu::network::corewlan_location @feat(DARWIN) @link("CoreLocation.framework");
import bleu::objc, bleu::network;

const long CL_AUTHORIZATION_NOT_DETERMINED = 0;
const long CL_AUTHORIZATION_RESTRICTED = 1;
const long CL_AUTHORIZATION_DENIED = 2;
const long CL_AUTHORIZATION_ALWAYS = 3;
const long CL_AUTHORIZATION_WHEN_IN_USE = 4;

<* This process's Location Services authorization for Wi-Fi names. *>
fn LocationAccess authorization()
{
	objc::ObjClass manager = objc::class_named("CLLocationManager");
	if (manager == null) return UNKNOWN;
	switch (manager.send(long, "authorizationStatus"))
	{
		case CL_AUTHORIZATION_NOT_DETERMINED: return NOT_DETERMINED;
		case CL_AUTHORIZATION_RESTRICTED: return RESTRICTED;
		case CL_AUTHORIZATION_DENIED: return DENIED;
		case CL_AUTHORIZATION_ALWAYS:
		case CL_AUTHORIZATION_WHEN_IN_USE: return AUTHORIZED;
		default: return UNKNOWN;
	}
}
