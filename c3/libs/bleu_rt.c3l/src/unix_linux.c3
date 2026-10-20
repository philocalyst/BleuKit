<*
 Linux layouts and constants for the Unix socket layer.

 Sources (two independent ones for each value):
 - struct msghdr { void *msg_name; socklen_t msg_namelen; struct iovec *msg_iov;
 size_t msg_iovlen; void *msg_control; size_t msg_controllen; int msg_flags; }:
 glibc bits/socket.h as mirrored in libc 0.2.170 src/unix/linux_like/linux/gnu/mod.rs:63-71
 (https://static.crates.io/crates/libc/libc-0.2.170.crate), and the kernel's sendmsg(2) ABI
 (https://man7.org/linux/man-pages/man2/sendmsg.2.html, "struct msghdr")
 - struct cmsghdr { size_t cmsg_len; int cmsg_level; int cmsg_type; }, CMSG_ALIGN(len)
 = (len + sizeof(size_t) - 1) & ~(sizeof(size_t) - 1), CMSG_LEN(n) = CMSG_ALIGN(16) + n:
 libc 0.2.170 src/unix/linux_like/mod.rs:1627-1650; cmsg(3), https://man7.org/linux/man-pages/man3/cmsg.3.html
 - struct sockaddr_un { sa_family_t sun_family; char sun_path[108]; }:
 include/uapi/linux/un.h (https://raw.githubusercontent.com/torvalds/linux/master/include/uapi/linux/un.h),
 unix(7) for abstract names (leading NUL byte)
 - SOL_SOCKET 1, SO_PEERCRED 17, SCM_RIGHTS 1: include/uapi/asm-generic/socket.h line 30 (SO_PEERCRED 17),
 include/linux/socket.h line 192, libc 0.2.170 src/unix/linux_like/linux/arch/generic/mod.rs:40
 - struct ucred { __u32 pid, uid, gid; }: include/linux/socket.h line 197
 - MSG_CTRUNC 0x08, MSG_TRUNC 0x20, MSG_NOSIGNAL 0x4000, MSG_CMSG_CLOEXEC 0x40000000:
 libc 0.2.170 src/unix/linux_like/mod.rs:834-848
 - F_GETFL 3, F_SETFL 4: include/uapi/asm-generic/fcntl.h; F_DUPFD_CLOEXEC 1030: libc 0.2.170 linux_like/mod.rs:509
 - O_CLOEXEC 0x80000 and O_NONBLOCK 0o4000: asm-generic/fcntl.h lines 42 and 66; libc 0.2.170 linux gnu b64 mod.rs:432,
 592
*>
module bleu::rt::unix @feat(LINUX);
import libc, bleu::error;

const CInt F_GETFL         = 3;
const CInt F_SETFL         = 4;
const CInt F_DUPFD_CLOEXEC = 1030;
const CInt O_NONBLOCK_FLAG = 0o4000;

// SOCK_CLOEXEC has the value of O_CLOEXEC: close-on-exec from creation, atomically.
const CInt SOCKET_CLOEXEC = 0o2000000;

const CInt SOL_SOCKET      = 1;
const CInt SO_PEERCRED     = 17;
const CInt SCM_RIGHTS_TYPE = 1;

const CInt MSG_CTRUNC_FLAG       = 0x08;
const CInt MSG_TRUNC_FLAG        = 0x20;
const CInt MSG_NOSIGNAL_FLAG     = 0x4000;
const CInt MSG_CMSG_CLOEXEC_FLAG = 0x40000000;

// Per send: a write to a closed peer must not raise SIGPIPE and kill the process.
const CInt SEND_FLAGS = MSG_NOSIGNAL_FLAG;

// sizeof(size_t) - 1: the alignment of cmsghdr data on LP64 Linux.
const usz CMSG_ALIGN_MASK = 7;

// struct sockaddr_un, the Linux layout (unix(7)).
struct SockAddrUn
{
	CUShort sun_family;
	char[108] sun_path;
}

// struct msghdr, the glibc layout.
struct MsgHdr
{
	void* msg_name;
	SockLen msg_namelen;
	IoVec* msg_iov;
	usz msg_iovlen;
	void* msg_control;
	usz msg_controllen;
	CInt msg_flags;
}

// struct cmsghdr, the glibc layout.
struct CmsgHdr
{
	usz cmsg_len;
	CInt cmsg_level;
	CInt cmsg_type;
}

// sizeof(struct cmsghdr) before alignment.
const usz CMSG_HEADER_SIZE = CmsgHdr::size;

// struct ucred, as SO_PEERCRED returns it.
struct Ucred
{
	CUInt pid;
	CUInt uid;
	CUInt gid;
}

extern fn CInt sys_accept4(CInt fd, void* addr, SockLen* len, CInt flags) @cname("accept4");

// Attach the buffers of a message. `control` is the ancillary-data buffer.
fn void MsgHdr.attach(&self, IoVec* iov, usz iov_count, void* control, usz control_len)
{
	self.msg_iov = iov;
	self.msg_iovlen = iov_count;
	self.msg_control = control;
	self.msg_controllen = control_len;
}

<* Bytes of ancillary data the kernel wrote into the control buffer. *>
fn usz MsgHdr.received_control_len(self) => self.msg_controllen;

<* MSG_* flags the kernel set on the received message. *>
fn CInt MsgHdr.received_flags(self) => self.msg_flags;

// Write a cmsghdr carrying `data_len` bytes of SCM_RIGHTS descriptors.
fn void CmsgHdr.set_rights(&self, usz data_len)
{
	self.cmsg_len = cmsg_align(CMSG_HEADER_SIZE) + data_len;
	self.cmsg_level = SOL_SOCKET;
	self.cmsg_type = SCM_RIGHTS_TYPE;
}

<* The cmsg_len field: header plus data, unaligned. *>
fn usz CmsgHdr.length(self) => self.cmsg_len;

<* True for an SCM_RIGHTS header. *>
fn bool CmsgHdr.is_rights(self) => self.cmsg_level == SOL_SOCKET && self.cmsg_type == SCM_RIGHTS_TYPE;

// Fill `addr` for a filesystem path, or for an abstract name when the path begins
// with '@' or a NUL byte. The abstract form puts a NUL first in sun_path.
fn SockLen? socket_address(SockAddrUn* addr, String path)
{
	if (path.len == 0) return error::raise(error::INVALID_ARGUMENT, error::Domain.INTERNAL, 0, "socket path is empty")~;
	usz capacity = addr.sun_path.len;
	addr.sun_family = (CUShort)AF_UNIX_FAMILY;
	bool is_abstract = path[0] == '@' || path[0] == 0;
	if (is_abstract)
	{
		String name = path[1..];
		if (name.len >= capacity) return error::raise(
			error::INVALID_ARGUMENT,
			error::Domain.INTERNAL,
			0,
			"abstract name is %d bytes, at most %d",
			name.len,
			capacity - 1
		)~;
		addr.sun_path[0] = 0;
		mem::copy(&addr.sun_path[1], name.ptr, name.len);
		return (SockLen)(SUN_PATH_OFFSET + 1 + name.len);
	}
	// One byte is reserved for the terminating NUL.
	if (path.len >= capacity) return error::raise(
		error::INVALID_ARGUMENT,
		error::Domain.INTERNAL,
		0,
		"socket path is %d bytes, at most %d",
		path.len,
		capacity - 1
	)~;
	mem::copy(&addr.sun_path, path.ptr, path.len);
	addr.sun_path[path.len] = 0;
	return (SockLen)(SUN_PATH_OFFSET + path.len + 1);
}

// accept4(2) with SOCK_CLOEXEC: the new descriptor is close-on-exec atomically.
fn CInt accept_raw(CInt listener) => sys_accept4(listener, null, null, SOCKET_CLOEXEC);

// Nothing to configure: the descriptor is created close-on-exec (SOCK_CLOEXEC)
// and sends use MSG_NOSIGNAL. Darwin needs both set per socket.
fn void? configure_socket(Fd* fd) @private
{
	return;
}

// Nothing to configure: recvmsg(2) sets close-on-exec on received descriptors (MSG_CMSG_CLOEXEC).
fn void? configure_received_fd(Fd* fd) @private
{
	return;
}

// SO_PEERCRED: the pid, uid and gid of the process that called connect(2).
fn PeerCredentials? read_peer_credentials(CInt fd)
{
	Ucred cred;
	SockLen len = (SockLen)Ucred::size;
	if (sys_getsockopt(fd, SOL_SOCKET, SO_PEERCRED, &cred, &len) != 0)
	{
		return errno_fault("getsockopt(SO_PEERCRED)", libc::errno())~;
	}
	return { .pid = (int)cred.pid, .uid = cred.uid, .gid = cred.gid };
}