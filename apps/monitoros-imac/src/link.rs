//! RTMGRP_LINK subscription with an initial RTM_GETLINK query on the same socket.
//! Parsing uses checked byte slices rather than casting possibly unaligned data.

use crate::lifecycle::Link;
use std::io;
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};

const HEADER: usize = 16; // struct nlmsghdr
const LINK_INFO: usize = 16; // struct ifinfomsg
const INITIAL_QUERY: u32 = 1;

pub struct LinkMonitor {
    fd: OwnedFd,
    interface: String,
    index: Option<i32>,
    pub initialized: bool,
}

impl LinkMonitor {
    pub fn new(interface: &str) -> io::Result<Self> {
        // SAFETY: socket returns a new descriptor, uniquely owned below.
        let raw = unsafe {
            libc::socket(
                libc::AF_NETLINK,
                libc::SOCK_RAW | libc::SOCK_CLOEXEC | libc::SOCK_NONBLOCK,
                libc::NETLINK_ROUTE,
            )
        };
        if raw < 0 {
            return Err(io::Error::last_os_error());
        }
        let fd = unsafe { OwnedFd::from_raw_fd(raw) };
        // SAFETY: zero initializes the sockaddr padding and kernel-selected PID.
        let mut address: libc::sockaddr_nl = unsafe { std::mem::zeroed() };
        address.nl_family = libc::AF_NETLINK as u16;
        address.nl_groups = libc::RTMGRP_LINK as u32;
        let size = std::mem::size_of_val(&address) as libc::socklen_t;
        // SAFETY: address and length describe a valid sockaddr_nl.
        if unsafe {
            libc::bind(
                fd.as_raw_fd(),
                (&address as *const libc::sockaddr_nl).cast(),
                size,
            )
        } < 0
        {
            return Err(io::Error::last_os_error());
        }

        // Subscribe BEFORE querying. No process-start/readiness race, and no
        // gap between a sysfs snapshot and starting to listen for events.
        address.nl_groups = 0;
        let query = initial_query(interface);
        let sent = unsafe {
            libc::sendto(
                fd.as_raw_fd(),
                query.as_ptr().cast(),
                query.len(),
                0,
                (&address as *const libc::sockaddr_nl).cast(),
                size,
            )
        };
        if sent < 0 {
            return Err(io::Error::last_os_error());
        }
        if sent as usize != query.len() {
            return Err(invalid("short RTM_GETLINK send"));
        }
        Ok(Self {
            fd,
            interface: interface.to_string(),
            index: None,
            initialized: false,
        })
    }

    pub fn fd(&self) -> RawFd {
        self.fd.as_raw_fd()
    }

    pub fn drain(&mut self) -> io::Result<Vec<Option<Link>>> {
        let mut events = Vec::new();
        let mut buffer = [0_u8; 65536];
        // Bound each batch so link churn cannot starve shutdown/child signals.
        for _ in 0..64 {
            // SAFETY: recvfrom is given valid writable buffers and their sizes.
            let mut source: libc::sockaddr_nl = unsafe { std::mem::zeroed() };
            let mut size = std::mem::size_of_val(&source) as libc::socklen_t;
            let count = unsafe {
                libc::recvfrom(
                    self.fd(),
                    buffer.as_mut_ptr().cast(),
                    buffer.len(),
                    libc::MSG_TRUNC,
                    (&mut source as *mut libc::sockaddr_nl).cast(),
                    &mut size,
                )
            };
            if count < 0 {
                let error = io::Error::last_os_error();
                if error.kind() == io::ErrorKind::WouldBlock {
                    return Ok(events);
                }
                if error.kind() == io::ErrorKind::Interrupted {
                    continue;
                }
                // ENOBUFS means an event may have been lost. The caller shuts
                // down/reaps its worker and fails so systemd can resubscribe.
                return Err(error);
            }
            if count == 0 || count as usize > buffer.len() {
                return Err(invalid("empty or truncated rtnetlink notification"));
            }
            if size as usize != std::mem::size_of_val(&source) || source.nl_pid != 0 {
                return Err(invalid("rtnetlink notification is not from the kernel"));
            }
            for (sequence, message) in parse(&buffer[..count as usize])? {
                if sequence == INITIAL_QUERY {
                    self.initialized = true;
                }
                match message {
                    Message::Missing => {
                        self.index = None;
                        events.push(None);
                    }
                    Message::Link {
                        name,
                        index,
                        up,
                        deleted,
                    } => {
                        if name == self.interface {
                            self.index = if deleted { None } else { Some(index) };
                            events.push(if deleted {
                                None
                            } else {
                                Some(Link { index, up })
                            });
                        } else if self.index == Some(index) {
                            // The watched interface was renamed away.
                            self.index = None;
                            events.push(None);
                        }
                    }
                }
            }
        }
        Ok(events)
    }
}

#[derive(Debug, Eq, PartialEq)]
enum Message {
    Missing,
    Link {
        name: String,
        index: i32,
        up: bool,
        deleted: bool,
    },
}

fn align(length: usize) -> usize {
    (length + 3) & !3
}
fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidData, message)
}

fn initial_query(interface: &str) -> Vec<u8> {
    let attr_len = 4 + interface.len() + 1;
    let length = HEADER + LINK_INFO + align(attr_len);
    let mut bytes = vec![0; length];
    bytes[0..4].copy_from_slice(&(length as u32).to_ne_bytes());
    bytes[4..6].copy_from_slice(&libc::RTM_GETLINK.to_ne_bytes());
    bytes[6..8].copy_from_slice(&(libc::NLM_F_REQUEST as u16).to_ne_bytes());
    bytes[8..12].copy_from_slice(&INITIAL_QUERY.to_ne_bytes());
    bytes[32..34].copy_from_slice(&(attr_len as u16).to_ne_bytes());
    bytes[34..36].copy_from_slice(&libc::IFLA_IFNAME.to_ne_bytes());
    bytes[36..36 + interface.len()].copy_from_slice(interface.as_bytes());
    bytes
}

fn parse(mut bytes: &[u8]) -> io::Result<Vec<(u32, Message)>> {
    let mut messages = Vec::new();
    while !bytes.is_empty() {
        if bytes.len() < HEADER {
            return Err(invalid("short netlink header"));
        }
        let length = u32::from_ne_bytes(bytes[0..4].try_into().unwrap()) as usize;
        if length < HEADER || length > bytes.len() {
            return Err(invalid("invalid netlink length"));
        }
        let kind = u16::from_ne_bytes(bytes[4..6].try_into().unwrap());
        let sequence = u32::from_ne_bytes(bytes[8..12].try_into().unwrap());
        let body = &bytes[HEADER..length];
        match kind as i32 {
            libc::NLMSG_ERROR => {
                if body.len() < 4 {
                    return Err(invalid("short netlink error"));
                }
                let code = i32::from_ne_bytes(body[..4].try_into().unwrap());
                if sequence == INITIAL_QUERY && code == -libc::ENODEV {
                    messages.push((sequence, Message::Missing));
                } else if code != 0 {
                    return Err(io::Error::from_raw_os_error(
                        code.checked_neg()
                            .ok_or_else(|| invalid("invalid netlink error code"))?,
                    ));
                }
            }
            libc::NLMSG_OVERRUN => return Err(invalid("rtnetlink notification overrun")),
            _ if kind == libc::RTM_NEWLINK || kind == libc::RTM_DELLINK => {
                if body.len() < LINK_INFO {
                    return Err(invalid("short ifinfomsg"));
                }
                let index = i32::from_ne_bytes(body[4..8].try_into().unwrap());
                let flags = u32::from_ne_bytes(body[8..12].try_into().unwrap());
                let mut attrs = &body[LINK_INFO..];
                let mut name = None;
                while !attrs.is_empty() {
                    if attrs.len() < 4 {
                        return Err(invalid("short link attribute"));
                    }
                    let length = u16::from_ne_bytes(attrs[..2].try_into().unwrap()) as usize;
                    let kind = u16::from_ne_bytes(attrs[2..4].try_into().unwrap()) & 0x3fff;
                    if length < 4 || length > attrs.len() {
                        return Err(invalid("invalid link attribute length"));
                    }
                    if kind == libc::IFLA_IFNAME {
                        let value = &attrs[4..length];
                        let end = value
                            .iter()
                            .position(|byte| *byte == 0)
                            .ok_or_else(|| invalid("unterminated interface name"))?;
                        name = Some(String::from_utf8_lossy(&value[..end]).into_owned());
                    }
                    attrs = &attrs[align(length).min(attrs.len())..];
                }
                let required = (libc::IFF_UP | libc::IFF_LOWER_UP) as u32;
                messages.push((
                    sequence,
                    Message::Link {
                        name: name
                            .ok_or_else(|| invalid("link notification lacks interface name"))?,
                        index,
                        up: flags & required == required,
                        deleted: kind == libc::RTM_DELLINK,
                    },
                ));
            }
            _ => {}
        }
        bytes = &bytes[align(length).min(bytes.len())..];
    }
    Ok(messages)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn notification(kind: u16, flags: i32) -> Vec<u8> {
        let mut bytes = initial_query("thunderbolt0");
        bytes[4..6].copy_from_slice(&kind.to_ne_bytes());
        bytes[8..12].copy_from_slice(&0_u32.to_ne_bytes());
        bytes[20..24].copy_from_slice(&7_i32.to_ne_bytes());
        bytes[24..28].copy_from_slice(&(flags as u32).to_ne_bytes());
        bytes
    }

    #[test]
    fn parses_carrier_admin_down_and_delete_without_losing_event_order() {
        let up = libc::IFF_UP | libc::IFF_LOWER_UP;
        let mut bytes = Vec::new();
        for (kind, flags) in [
            (libc::RTM_NEWLINK, up),
            (libc::RTM_NEWLINK, libc::IFF_UP),
            (libc::RTM_NEWLINK, libc::IFF_LOWER_UP),
            (libc::RTM_DELLINK, up),
        ] {
            bytes.extend(notification(kind, flags));
        }
        let events = parse(&bytes).unwrap();
        for (event, (up, deleted)) in
            events
                .iter()
                .zip([(true, false), (false, false), (false, false), (true, true)])
        {
            assert_eq!(
                event,
                &(
                    0,
                    Message::Link {
                        name: "thunderbolt0".into(),
                        index: 7,
                        up,
                        deleted
                    }
                )
            );
        }
        assert_eq!(events.len(), 4);
    }

    #[test]
    fn missing_initial_interface_is_a_normal_result() {
        let mut bytes = vec![0; HEADER + 4];
        bytes[..4].copy_from_slice(&20_u32.to_ne_bytes());
        bytes[4..6].copy_from_slice(&(libc::NLMSG_ERROR as u16).to_ne_bytes());
        bytes[8..12].copy_from_slice(&INITIAL_QUERY.to_ne_bytes());
        bytes[16..20].copy_from_slice(&(-libc::ENODEV).to_ne_bytes());
        assert_eq!(
            parse(&bytes).unwrap(),
            vec![(INITIAL_QUERY, Message::Missing)]
        );
        bytes[16..20].copy_from_slice(&(-libc::ENOBUFS).to_ne_bytes());
        assert_eq!(
            parse(&bytes).unwrap_err().raw_os_error(),
            Some(libc::ENOBUFS)
        );
    }

    #[test]
    fn malformed_notifications_fail_instead_of_silently_losing_disconnects() {
        let bytes = notification(libc::RTM_NEWLINK, libc::IFF_UP);
        for length in 1..bytes.len() {
            assert!(parse(&bytes[..length]).is_err());
        }
        let mut corrupt = bytes;
        corrupt[32..34].copy_from_slice(&3_u16.to_ne_bytes());
        assert!(parse(&corrupt).is_err());
    }
}
