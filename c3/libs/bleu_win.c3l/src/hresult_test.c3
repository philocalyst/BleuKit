// Unit tests for HRESULT classification and the fault mapping. Expected codes
// are the winerror.h values cross-checked in docs/research/bleu_win.md.
module bleu::win::hresult;
import bleu::error;

fn void hresult_facility_and_failure_bits() @test
{
	assert(((Hresult)E_ACCESSDENIED).failed());
	assert(((Hresult)S_FALSE).succeeded());
	assert(((Hresult)E_ACCESSDENIED).is_win32());
	assert(!((Hresult)E_NOTIMPL).is_win32());
}

fn void from_win32_matches_the_macro() @test
{
	assert((uint)from_win32(ERROR_ACCESS_DENIED) == E_ACCESSDENIED);
	assert((uint)from_win32(ERROR_OUTOFMEMORY) == E_OUTOFMEMORY);
	assert((uint)from_win32(ERROR_INVALID_PARAMETER) == E_INVALIDARG);
	assert((uint)from_win32(RPC_S_SERVER_UNAVAILABLE) == 0x800706BA);
	assert((uint)from_win32(0) == S_OK);
}

fn void to_fault_maps_the_hresult_table() @test
{
	assert(((Hresult)E_ACCESSDENIED).to_fault() == error::PERMISSION_DENIED);
	assert(((Hresult)E_OUTOFMEMORY).to_fault() == error::NO_MEMORY);
	assert(((Hresult)E_INVALIDARG).to_fault() == error::INVALID_ARGUMENT);
	assert(((Hresult)E_NOTIMPL).to_fault() == error::UNSUPPORTED);
	assert(((Hresult)RPC_E_DISCONNECTED).to_fault() == error::DISCONNECTED);
	assert(((Hresult)from_win32(RPC_S_SERVER_UNAVAILABLE)).to_fault() == error::DISCONNECTED);
	assert(((Hresult)E_FAIL).to_fault() == error::BACKEND_FAILURE);
}

fn void win32_codes_map_to_excuses() @test
{
	assert(win32_to_fault(ERROR_FILE_NOT_FOUND) == NOT_FOUND);
	assert(win32_to_fault(ERROR_NOT_FOUND) == NOT_FOUND);
	assert(win32_to_fault(ERROR_TIMEOUT) == TIMEOUT);
	assert(win32_to_fault(WAIT_TIMEOUT) == TIMEOUT);
	assert(win32_to_fault(ERROR_BUSY) == error::BUSY);
	assert(win32_to_fault(ERROR_CANCELLED) == error::CANCELLED);
	assert(win32_to_fault(ERROR_NOT_SUPPORTED) == error::UNSUPPORTED);
	assert(win32_to_fault(ERROR_HOTKEY_ALREADY_REGISTERED) == error::BUSY);
	assert(win32_to_fault(ERROR_HOTKEY_NOT_REGISTERED) == NOT_FOUND);
	assert(win32_to_fault(9999) == error::BACKEND_FAILURE);
}