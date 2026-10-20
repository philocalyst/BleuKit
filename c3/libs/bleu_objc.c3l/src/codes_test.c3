module bleu::objc::codes;
import bleu::error;

// Each Mach and IOKit class from codes.c3, and the KERN_RESOURCE_SHORTAGE choice (R-10).
fn void mach_classes() @test
{
	assert(classify_mach((int)(uint)MachCode.KERN_INVALID_ARGUMENT) == error::INVALID_ARGUMENT);
	assert(classify_mach((int)(uint)MachCode.IO_BAD_ARGUMENT) == error::INVALID_ARGUMENT);
	assert(classify_mach((int)(uint)MachCode.KERN_NO_ACCESS) == error::PERMISSION_DENIED);
	assert(classify_mach((int)(uint)MachCode.KERN_DENIED) == error::PERMISSION_DENIED);
	assert(classify_mach((int)(uint)MachCode.IO_NOT_PERMITTED) == error::PERMISSION_DENIED);
	assert(classify_mach((int)(uint)MachCode.IO_NOT_PRIVILEGED) == error::PERMISSION_DENIED);
	assert(classify_mach((int)(uint)MachCode.KERN_NOT_FOUND) == NOT_FOUND);
	assert(classify_mach((int)(uint)MachCode.IO_NO_DEVICE) == NOT_FOUND);
	assert(classify_mach((int)(uint)MachCode.IO_NOT_FOUND) == NOT_FOUND);
	assert(classify_mach((int)(uint)MachCode.KERN_OPERATION_TIMED_OUT) == TIMEOUT);
	assert(classify_mach((int)(uint)MachCode.IO_TIMEOUT) == TIMEOUT);
	assert(classify_mach((int)(uint)MachCode.KERN_ABORTED) == error::CANCELLED);
	assert(classify_mach((int)(uint)MachCode.IO_ABORTED) == error::CANCELLED);
	assert(classify_mach((int)(uint)MachCode.IO_BUSY) == error::BUSY);
	assert(classify_mach((int)(uint)MachCode.IO_EXCLUSIVE_ACCESS) == error::BUSY);
	assert(classify_mach((int)(uint)MachCode.KERN_RESOURCE_SHORTAGE) == error::NO_MEMORY);
	assert(classify_mach((int)(uint)MachCode.IO_NO_MEMORY) == error::NO_MEMORY);
	assert(classify_mach((int)(uint)MachCode.KERN_NOT_SUPPORTED) == error::UNSUPPORTED);
	assert(classify_mach((int)(uint)MachCode.IO_UNSUPPORTED) == error::UNSUPPORTED);
	assert(classify_mach((int)(uint)MachCode.IO_NOT_OPEN) == error::INVALID_STATE);
	assert(classify_mach((int)(uint)MachCode.IO_NOT_ATTACHED) == error::INVALID_STATE);
	assert(classify_mach((int)(uint)MachCode.IO_OFFLINE) == error::UNAVAILABLE);
	assert(classify_mach((int)(uint)MachCode.IO_NO_MEDIA) == error::UNAVAILABLE);
	assert(classify_mach((int)(uint)MachCode.IO_IPC_ERROR) == error::DISCONNECTED);
	assert(classify_mach((int)(uint)MachCode.IO_NOT_RESPONDING) == error::DISCONNECTED);
}

// Codes without a clear class, and values outside the table, fall back to BACKEND_FAILURE.
fn void mach_fallback() @test
{
	assert(classify_mach((int)(uint)MachCode.KERN_FAILURE) == error::BACKEND_FAILURE);
	assert(classify_mach((int)(uint)MachCode.IO_ERROR) == error::BACKEND_FAILURE);
	assert(classify_mach((int)(uint)MachCode.IO_INTERNAL_ERROR) == error::BACKEND_FAILURE);
	assert(classify_mach(0x12345) == error::BACKEND_FAILURE);
}

// Cocoa file, user and feature codes from objc2-foundation FoundationErrors.rs.
fn void ns_cocoa_classes() @test
{
	assert(classify_ns("NSCocoaErrorDomain", 4) == NOT_FOUND);
	assert(classify_ns("NSCocoaErrorDomain", 260) == NOT_FOUND);
	assert(classify_ns("NSCocoaErrorDomain", 257) == error::PERMISSION_DENIED);
	assert(classify_ns("NSCocoaErrorDomain", 513) == error::PERMISSION_DENIED);
	assert(classify_ns("NSCocoaErrorDomain", 255) == error::BUSY);
	assert(classify_ns("NSCocoaErrorDomain", 3072) == error::CANCELLED);
	assert(classify_ns("NSCocoaErrorDomain", 3328) == error::UNSUPPORTED);
	assert(classify_ns("NSCocoaErrorDomain", 9999) == error::BACKEND_FAILURE);
}

// errno values from xnu bsd/sys/errno.h, under NSPOSIXErrorDomain.
fn void ns_posix_classes() @test
{
	assert(classify_ns("NSPOSIXErrorDomain", 1) == error::PERMISSION_DENIED);
	assert(classify_ns("NSPOSIXErrorDomain", 13) == error::PERMISSION_DENIED);
	assert(classify_ns("NSPOSIXErrorDomain", 2) == NOT_FOUND);
	assert(classify_ns("NSPOSIXErrorDomain", 16) == error::BUSY);
	assert(classify_ns("NSPOSIXErrorDomain", 22) == error::INVALID_ARGUMENT);
	assert(classify_ns("NSPOSIXErrorDomain", 12) == error::NO_MEMORY);
	assert(classify_ns("NSPOSIXErrorDomain", 45) == error::UNSUPPORTED);
	assert(classify_ns("NSPOSIXErrorDomain", 60) == TIMEOUT);
	assert(classify_ns("NSPOSIXErrorDomain", 89) == error::CANCELLED);
	assert(classify_ns("NSPOSIXErrorDomain", 5) == error::BACKEND_FAILURE);
}

// errAEEventNotPermitted (-1743) is the only OSStatus with a class; a different domain never matches it.
fn void ns_os_status_classes() @test
{
	assert(classify_ns("NSOSStatusErrorDomain", -1743) == error::PERMISSION_DENIED);
	assert(classify_ns("NSOSStatusErrorDomain", -1744) == error::BACKEND_FAILURE);
	assert(classify_ns("NSCocoaErrorDomain", -1743) == error::BACKEND_FAILURE);
	assert(classify_ns("SomeOtherDomain", 4) == error::BACKEND_FAILURE);
}
