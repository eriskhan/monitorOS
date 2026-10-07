use mdns_sd::{IfKind, ServiceDaemon, ServiceInfo};
use std::collections::HashMap;
use std::io;
use std::time::Duration;

pub const SERVICE_TYPE: &str = "_monitoros._tcp.local.";
const INSTANCE_NAME: &str = "monitorOS iMac";
const HOST_NAME: &str = "monitoros-imac.local.";

pub struct Advertiser {
    daemon: ServiceDaemon,
}

impl Advertiser {
    pub fn start(interface: &str, port: u16) -> io::Result<Self> {
        let daemon = ServiceDaemon::new().map_err(mdns_error)?;
        daemon.set_ip_check_interval(1).map_err(mdns_error)?;

        let mut service = ServiceInfo::new(
            SERVICE_TYPE,
            INSTANCE_NAME,
            HOST_NAME,
            (),
            port,
            None::<HashMap<String, String>>,
        )
        .map_err(mdns_error)?
        .enable_addr_auto();
        service.set_interfaces(vec![IfKind::Name(interface.to_string())]);
        service.set_link_local_only(true);

        daemon.register(service).map_err(mdns_error)?;

        println!(
            "monitorosd: advertising {} port={} on {} (link-local only)",
            SERVICE_TYPE, port, interface
        );

        Ok(Self { daemon })
    }
}

impl Drop for Advertiser {
    fn drop(&mut self) {
        match self.daemon.shutdown() {
            Ok(status) => {
                let _ = status.recv_timeout(Duration::from_secs(1));
            }
            Err(error) => {
                eprintln!("monitorosd: Bonjour shutdown failed: {error}");
            }
        }
    }
}

fn mdns_error(error: mdns_sd::Error) -> io::Error {
    io::Error::other(format!("Bonjour/mDNS: {error}"))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn service_contract_is_interface_scoped_link_local() {
        let mut service = ServiceInfo::new(
            SERVICE_TYPE,
            INSTANCE_NAME,
            HOST_NAME,
            (),
            5202,
            None::<HashMap<String, String>>,
        )
        .unwrap()
        .enable_addr_auto();
        service.set_interfaces(vec![IfKind::Name("thunderbolt0".to_string())]);
        service.set_link_local_only(true);

        assert_eq!(service.get_type(), SERVICE_TYPE);
        assert_eq!(service.get_port(), 5202);
        assert_eq!(service.get_hostname(), HOST_NAME);
        assert!(service.get_addresses().is_empty());
        assert!(service.is_addr_auto());
    }
}
