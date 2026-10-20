<*
 CoreWLAN's numbers, turned into Bleu's types. Pure: no Objective-C, so the
 file type-checks and its tests run on every platform.

 Sources:
 * CWSecurity, CWChannelBand and CWErr values: the CoreWLAN headers as
   generated into objc2-core-wlan 0.3.0
   (https://static.crates.io/crates/objc2-core-wlan/objc2-core-wlan-0.3.0.crate,
   src/generated/CoreWLANTypes.rs: CWSecurity lines 335-370, CWChannelBand 479-488,
   CWErr 115-184). The `kCWErr*` names are the header's doc aliases.
 * The 2.4 GHz channel 14 exception and the 5 and 6 GHz channel formulas: the
   IEEE 802.11 channel plans, as CoreWLAN's `CWChannel` documents its numbers.
*>
module bleu::network::corewlan_convert;
import bleu::error, bleu::network;

<* CWSecurity (CoreWLANTypes.rs 335-370). *>
const long CW_SECURITY_NONE              = 0;
const long CW_SECURITY_WEP               = 1;
const long CW_SECURITY_WPA_PERSONAL      = 2;
const long CW_SECURITY_WPA_PERSONAL_MIXED = 3;
const long CW_SECURITY_WPA2_PERSONAL     = 4;
const long CW_SECURITY_PERSONAL          = 5;
const long CW_SECURITY_DYNAMIC_WEP       = 6;
const long CW_SECURITY_WPA_ENTERPRISE    = 7;
const long CW_SECURITY_WPA_ENTERPRISE_MIXED = 8;
const long CW_SECURITY_WPA2_ENTERPRISE   = 9;
const long CW_SECURITY_ENTERPRISE        = 10;
const long CW_SECURITY_WPA3_PERSONAL     = 11;
const long CW_SECURITY_WPA3_ENTERPRISE   = 12;
const long CW_SECURITY_WPA3_TRANSITION   = 13;
const long CW_SECURITY_OWE               = 14;
const long CW_SECURITY_OWE_TRANSITION    = 15;

<* CWChannelBand (CoreWLANTypes.rs 479-488). *>
const long CW_BAND_2_GHZ = 1;
const long CW_BAND_5_GHZ = 2;
const long CW_BAND_6_GHZ = 3;

<* Center frequency of 2.4 GHz channel 14 (IEEE 802.11: the one channel off the 5 MHz grid). *>
const uint CHANNEL_14_MHZ = 2484;

<* 2.4 GHz channels 1-13: 2407 MHz + 5 MHz per channel. *>
const uint BAND_2_4_BASE_MHZ = 2407;
<* 5 GHz channels: 5000 MHz + 5 MHz per channel. *>
const uint BAND_5_BASE_MHZ = 5000;
<* 6 GHz channels: 5950 MHz + 5 MHz per channel. *>
const uint BAND_6_BASE_MHZ = 5950;
<* Channel-number step of the 5 and 6 GHz grids, in MHz. *>
const uint GRID_STEP_MHZ = 5;
<* The highest 2.4 GHz channel that sits on the 5 MHz grid. *>
const long LAST_2_4_GRID_CHANNEL = 13;

<*
 Bleu's security class for a CWSecurity value. Transition modes report the
 stronger mode's client-facing class (WPA2 PSK for WPA2/WPA3, OWE for OWE/OWE transition).
*>
fn Security security_from_cw(long security)
{
	switch (security)
	{
		case CW_SECURITY_NONE: return OPEN;
		case CW_SECURITY_WEP:
		case CW_SECURITY_DYNAMIC_WEP: return WEP;
		case CW_SECURITY_WPA_PERSONAL: return WPA_PSK;
		case CW_SECURITY_WPA_PERSONAL_MIXED:
		case CW_SECURITY_WPA2_PERSONAL:
		case CW_SECURITY_PERSONAL:
		case CW_SECURITY_WPA3_TRANSITION: return WPA2_PSK;
		case CW_SECURITY_WPA3_PERSONAL: return WPA3_SAE;
		case CW_SECURITY_OWE:
		case CW_SECURITY_OWE_TRANSITION: return OWE;
		case CW_SECURITY_WPA_ENTERPRISE:
		case CW_SECURITY_WPA_ENTERPRISE_MIXED:
		case CW_SECURITY_WPA2_ENTERPRISE:
		case CW_SECURITY_ENTERPRISE:
		case CW_SECURITY_WPA3_ENTERPRISE: return ENTERPRISE;
		default: return UNKNOWN;
	}
}

<*
 The CWSecurity values to probe with `supportsSecurity:`, strongest first. A
 network is classed by the first value it supports.
*>
long[15] PROBE_ORDER = {
	CW_SECURITY_WPA3_PERSONAL,
	CW_SECURITY_WPA3_TRANSITION,
	CW_SECURITY_WPA2_PERSONAL,
	CW_SECURITY_WPA_PERSONAL,
	CW_SECURITY_OWE,
	CW_SECURITY_WEP,
	CW_SECURITY_WPA3_ENTERPRISE,
	CW_SECURITY_WPA2_ENTERPRISE,
	CW_SECURITY_WPA_ENTERPRISE,
	CW_SECURITY_PERSONAL,
	CW_SECURITY_WPA_PERSONAL_MIXED,
	CW_SECURITY_ENTERPRISE,
	CW_SECURITY_DYNAMIC_WEP,
	CW_SECURITY_OWE_TRANSITION,
	CW_SECURITY_WPA_ENTERPRISE_MIXED,
};

fn long[] probe_order() => PROBE_ORDER[..];

<* Band of a CWChannelBand value. *>
fn Band band_from_cw(long band)
{
	switch (band)
	{
		case CW_BAND_2_GHZ: return GHZ_2_4;
		case CW_BAND_5_GHZ: return GHZ_5;
		case CW_BAND_6_GHZ: return GHZ_6;
		default: return UNKNOWN;
	}
}

<*
 Center frequency of a channel. Channel numbers are per band; a number that is
 not on the band's grid gives NOT_FOUND.
*>
fn MegaHertz? frequency_from_channel(long band, long number)
{
	if (number <= 0) return NOT_FOUND~;
	switch (band)
	{
		case CW_BAND_2_GHZ:
			if (number == 14) return (MegaHertz)CHANNEL_14_MHZ;
			if (number > LAST_2_4_GRID_CHANNEL) return NOT_FOUND~;
			return (MegaHertz)(BAND_2_4_BASE_MHZ + GRID_STEP_MHZ * (uint)number);
		case CW_BAND_5_GHZ:
			return (MegaHertz)(BAND_5_BASE_MHZ + GRID_STEP_MHZ * (uint)number);
		case CW_BAND_6_GHZ:
			return (MegaHertz)(BAND_6_BASE_MHZ + GRID_STEP_MHZ * (uint)number);
		default:
			return NOT_FOUND~;
	}
}

<*
 Failure class of a CWErr code (`kCWErr*`, CoreWLANTypes.rs 115-184). Codes
 about the password or the handshake are AUTH_REQUIRED: the network refused
 the credentials. Everything without a Bleu class is BACKEND_FAILURE.
*>
fn fault fault_from_cw_error(long code)
{
	switch (code)
	{
		case -3900: return error::INVALID_ARGUMENT; // kCWInvalidParameterErr
		case -3903: return error::UNSUPPORTED;      // kCWNotSupportedErr
		case -3905: return TIMEOUT;                 // kCWTimeoutErr
		case -3909: // kCWAssociationDeniedErr
		case -3910: // kCWAuthenticationAlgorithmUnsupportedErr
		case -3912: // kCWChallengeFailureErr
		case -3923: // kCWCipherSuiteRejectedErr
		case -3924: return error::AUTH_REQUIRED;    // kCWInvalidPMKErr
		case -3925: return TIMEOUT;                 // kCWSupplicantTimeoutErr
		case -3930: return error::PERMISSION_DENIED; // kCWOperationNotPermittedErr
		default: return error::BACKEND_FAILURE;
	}
}
