<*
 macOS layouts and constants for the Unix socket layer.

 Sources (two independent ones for each value):
   - struct msghdr { void *msg_name; socklen_t msg_namelen; struct iovec *msg_iov;
     int msg_iovlen; void *msg_control; socklen_t msg_controllen; int msg_flags; }:
     XNU bsd/sys/socket.h lines 603-611
     (https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/sys/socket.h), and
     libc 0.2.170 src/unix/bsd/mod.rs:85-95 (https://static.crates.io/crates/libc/libc-0.2.170.crate)
   - struct cmsghdr { socklen_t cmsg_len; int cmsg_level; int cmsg_type; }: XNU socket.h lines 652-656;
     CMSG_DATA and CMSG_SPACE use __DARWIN_ALIGN32, which masks with sizeof(__uint32_t) - 1 = 3:
     libc 0.2.170 src/unix/bsd/apple/mod.rs:5615-5617 and 5694-5712
   - struct sockaddr_un { unsigned char sun_len; sa_family_t sun_family; char sun_path[104]; }:
     XNU bsd/sys/un.h lines 77-79 (https://raw.githubusercontent.com/apple-oss-distributions/xnu/main/bsd/sys/un.h);
     libc 0.2.170 src/unix/bsd/mod.rs:137-141
   - SOL_SOCKET 0xffff: XNU bsd/sys/socket.h; libc 0.2.170 src/unix/bsd/apple/mod.rs:4353
   - SCM_RIGHTS 0x01: XNU socket.h line 726; libc 0.2.170 src/unix/bsd/mod.rs:331
   - SO_NOSIGPIPE 0x1022: XNU socket.h line 174; libc 0.2.170 src/unix/bsd/apple/mod.rs:4382
   - SOL_LOCAL 0, LOCAL_PEERCRED 0x001, LOCAL_PEERPID 0x002: XNU bsd/sys/un.h lines 85-89;
     libc 0.2.170 src/unix/bsd/apple/mod.rs:4338-4343
   - struct xucred { u_int cr_version; uid_t cr_uid; short cr_ngroups; gid_t cr_groups[NGROUPS]; }
     with XUCRED_VERSION 0: XNU bsd/sys/ucred.h lines 203-209; NGROUPS_MAX 16: XNU bsd/sys/syslimits.h line 104
   - F_SETFD 2, F_GETFL 3, F_SETFL 4, FD_CLOEXEC 1, O_NONBLOCK 0x4, F_DUPFD_CLOEXEC 67:
     XNU bsd/sys/fcntl.h lines 115, 279-282, 397, 401; libc 0.2.170 src/unix/bsd/apple/mod.rs:3736-3740
   - MSG_TRUNC 0x10, MSG_CTRUNC 0x20: XNU socket.h lines 617-618; libc apple mod.rs:4395-4396
   - Darwin has no SOCK_CLOEXEC, no accept4 and no MSG_CMSG_CLOEXEC, so close-on-exec is set with
     fcntl(F_SETFD) after creation, accept(2) and recvmsg(2). The window in which a concurrent fork
     could inherit a descriptor is therefore wider than on Linux; this is recorded in the research notes.
*>
module bleu::rt::unix @feat(DARWIN);
import libc, bleu::error, bleu::rt;

const CInt F_SETFD = 2;
const CInt F_GETFL = 3;
const CInt F_SETFL = 4;
const CInt FD_CLOEXEC = 1;
const CInt O_NONBLOCK_FLAG = 0x4;
const CInt F_DUPFD_CLOEXEC = 67;

// No SOCK_CLOEXEC on Darwin: configure_socket sets FD_CLOEXEC after creation.
const CInt SOCKET_CLOEXEC = 0;

const CInt SOL_SOCKET = 0xffff;
const CInt SO_NOSIGPIPE = 0x1022;
const CInt SCM_RIGHTS_TYPE = 1;
const CInt SOL_LOCAL = 0;
const CInt LOCAL_PEERCRED = 0x001;
const CInt LOCAL_PEERPID = 0x002;

const CInt MSG_TRUNC_FLAG = 0x10;
const CInt MSG_CTRUNC_FLAG = 0x20;
const CInt MSG_CMSG_CLOEXEC_FLAG = 0;

// SO_NOSIGPIPE is set on each socket instead, so sends pass no flag.
const CInt SEND_FLAGS = 0;

// sizeof(__uint32_t) - 1: __DARWIN_ALIGN32 aligns cmsghdr data to 4 bytes.
const usz CMSG_ALIGN_MASK = 3;

// NGROUPS_MAX on Darwin (syslimits.h).
const usz NGROUPS = 16;

// struct sockaddr_un with sun_len, the Darwin layout.
struct SockAddrUn
{
	char sun_len;
	char sun_family;
	char[104] sun_path;
}

// struct msghdr, the XNU layout: iovlen is an int, controllen a socklen_t.
struct MsgHdr
{
	void* msg_name;
	SockLen msg_namelen;
	IoVec* msg_iov;
	CInt msg_iovlen;
	void* msg_control;
	SockLen msg_controllen;
	CInt msg_flags;
}

// struct cmsghdr, the XNU layout.
struct CmsgHdr
{
	SockLen cmsg_len;
	CInt cmsg_level;
	CInt cmsg_type;
}

// sizeof(struct cmsghdr) before alignment.
const usz CMSG_HEADER_SIZE = CmsgHdr::size;

// struct xucred, as LOCAL_PEERCRED returns it.
struct Xucred
{
	CUInt cr_version;
	CUInt cr_uid;
	CShort cr_ngroups;
	CUInt[NGROUPS] cr_groups;
}

// The XUCRED_VERSION this layout is written for (ucred.h).
const CUInt XUCRED_VERSION = 0;

extern fn CInt sys_accept(CInt fd, void* addr, SockLen* len) @cname("accept");
extern fn CInt sys_setsockopt(CInt fd, CInt level, CInt name, void* value, SockLen len) @cname("setsockopt");

// Attach the buffers of a message. `control` is the ancillary-data buffer.
fn void MsgHdr.attach(&self, IoVec* iov, usz iov_count, void* control, usz control_len)
{
	self.msg_iov = iov;
	self.msg_iovlen = (CInt)iov_count;
	self.msg_control = control;
	self.msg_controllen = (SockLen)control_len;
}

<* Bytes of ancillary data the kernel wrote into the control buffer. *>
fn usz MsgHdr.received_control_len(self) => (usz)self.msg_controllen;

<* MSG_* flags the kernel set on the received message. *>
fn CInt MsgHdr.received_flags(self) => self.msg_flags;

// Write a cmsghdr carrying `data_len` bytes of SCM_RIGHTS descriptors.
fn void CmsgHdr.set_rights(&self, usz data_len)
{
	self.cmsg_len = (SockLen)(cmsg_align(CMSG_HEADER_SIZE) + data_len);
	self.cmsg_level = SOL_SOCKET;
	self.cmsg_type = SCM_RIGHTS_TYPE;
}

<* The cmsg_len field: header plus data, unaligned. *>
fn usz CmsgHdr.length(self) => (usz)self.cmsg_len;

<* True for an SCM_RIGHTS header. *>
fn bool CmsgHdr.is_rights(self) => self.cmsg_level == SOL_SOCKET && self.cmsg_type == SCM_RIGHTS_TYPE;

// Fill `addr` for a filesystem path. Abstract names are a Linux feature.
fn SockLen? socket_address(SockAddrUn* addr, String path)
{
	if (path.len == 0) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "socket path is empty")~;
	if (path[0] == '@' || path[0] == 0)
	{
		return error::raise(error::UNSUPPORTED, error::Domain.INTERNAL, 0, "abstract socket names exist only on Linux")~;
	}
	usz capacity = addr.sun_path.len;
	// One byte is reserved for the terminating NUL.
	if (path.len >= capacity) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "socket path is %d bytes, at most %d", path.len, capacity - 1)~;
	addr.sun_family = (char)AF_UNIX_FAMILY;
	mem::copy(&addr.sun_path, path.ptr, path.len);
	addr.sun_path[path.len] = 0;
	addr.sun_len = (char)(SUN_PATH_OFFSET + path.len + 1);
	return (SockLen)addr.sun_len;
}

// accept(2); close-on-exec is set by configure_socket on the result.
fn CInt accept_raw(CInt listener) => sys_accept(listener, null, null);

// Close-on-exec, and no SIGPIPE on a write to a closed peer (per socket, since
// there is no per-send flag).
fn void? configure_socket(Fd* fd) @private
{
	if (rt::fcntl(fd.raw(), F_SETFD, FD_CLOEXEC) < 0) return errno_fault("fcntl(F_SETFD)", libc::errno())~;
	CInt on = 1;
	if (sys_setsockopt(fd.raw(), SOL_SOCKET, SO_NOSIGPIPE, &on, (SockLen)CInt::size) != 0)
	{
		return errno_fault("setsockopt(SO_NOSIGPIPE)", libc::errno())~;
	}
}

// Received descriptors have no MSG_CMSG_CLOEXEC on Darwin: set close-on-exec here.
fn void? configure_received_fd(Fd* fd) @private
{
	if (rt::fcntl(fd.raw(), F_SETFD, FD_CLOEXEC) < 0) return errno_fault("fcntl(F_SETFD)", libc::errno())~;
}

// LOCAL_PEERCRED gives the uid and groups, LOCAL_PEERPID the pid.
fn PeerCredentials? read_peer_credentials(CInt fd)
{
	Xucred cred;
	SockLen len = (SockLen)Xucred::size;
	if (sys_getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &cred, &len) != 0)
	{
		return errno_fault("getsockopt(LOCAL_PEERCRED)", libc::errno())~;
	}
	if (cred.cr_version != XUCRED_VERSION) return error::raise(error::PROTOCOL, error::Domain.INTERNAL, 0, "xucred version %d", cred.cr_version)~;
	CInt pid;
	SockLen pid_len = (SockLen)CInt::size;
	if (sys_getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &pid_len) != 0)
	{
		return errno_fault("getsockopt(LOCAL_PEERPID)", libc::errno())~;
	}
	// cr_groups[0] is the effective gid (`cr_gid` in ucred.h).
	return { .pid = pid, .uid = cred.cr_uid, .gid = cred.cr_groups[0] };
}
