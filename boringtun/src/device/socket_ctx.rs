use std::io::{self, IoSliceMut};
use std::os::unix::io::AsRawFd;

#[derive(Clone, Debug)]
pub enum SocketContext {
    V4(libc::in_pktinfo),
    V6(libc::in6_pktinfo),
}

impl SocketContext {
    pub fn ifindex(&self) -> u32 {
        match self {
            SocketContext::V4(info) => info.ipi_ifindex as u32,
            SocketContext::V6(info) => info.ipi6_ifindex as u32,
        }
    }
}

pub fn send_with_ctx(
    sock: &socket2::Socket,
    buf: &[u8],
    addr: &socket2::SockAddr,
    ctx: Option<&SocketContext>,
) -> io::Result<usize> {
    use nix::sys::socket::{self, ControlMessage, MsgFlags};
    use std::io::IoSlice;

    let iov = [IoSlice::new(buf)];

    let bytes_sent = match addr.as_socket() {
        Some(std::net::SocketAddr::V4(v4)) => {
            let dest = socket::SockaddrIn::from(v4);
            match ctx {
                Some(SocketContext::V4(info)) => socket::sendmsg(
                    sock.as_raw_fd(),
                    &iov,
                    &[ControlMessage::Ipv4PacketInfo(info)],
                    MsgFlags::empty(),
                    Some(&dest),
                ),
                _ => socket::sendmsg(sock.as_raw_fd(), &iov, &[], MsgFlags::empty(), Some(&dest)),
            }
        }
        Some(std::net::SocketAddr::V6(v6)) => {
            let dest = socket::SockaddrIn6::from(v6);
            match ctx {
                Some(SocketContext::V6(info)) => socket::sendmsg(
                    sock.as_raw_fd(),
                    &iov,
                    &[ControlMessage::Ipv6PacketInfo(info)],
                    MsgFlags::empty(),
                    Some(&dest),
                ),
                _ => socket::sendmsg(sock.as_raw_fd(), &iov, &[], MsgFlags::empty(), Some(&dest)),
            }
        }
        None => {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "Address must be a valid IPv4 or IPv6 address",
            ))
        }
    }?;

    Ok(bytes_sent)
}

pub fn recv_with_ctx(
    sock: &socket2::Socket,
    buf: &mut [u8],
) -> io::Result<(usize, socket2::SockAddr, Option<SocketContext>)> {
    use nix::sys::socket::{self, ControlMessageOwned, MsgFlags, SockaddrLike, SockaddrStorage};

    let mut iov = [IoSliceMut::new(buf)];
    let mut cmsg_buffer = nix::cmsg_space!(libc::in_pktinfo, libc::in6_pktinfo);

    let msg = socket::recvmsg::<SockaddrStorage>(
        sock.as_raw_fd(),
        &mut iov,
        Some(&mut cmsg_buffer),
        MsgFlags::empty(),
    )?;

    let ctx = msg.cmsgs()?.find_map(|cmsg| match cmsg {
        ControlMessageOwned::Ipv4PacketInfo(info) => Some(SocketContext::V4(info)),
        ControlMessageOwned::Ipv6PacketInfo(info) => Some(SocketContext::V6(info)),
        _ => None,
    });

    let storage = msg
        .address
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "No sender address received"))?;

    let addr = unsafe {
        socket2::SockAddr::new(
            *(storage.as_ptr() as *const libc::sockaddr_storage),
            storage.len(),
        )
    };

    Ok((msg.bytes, addr, ctx))
}
