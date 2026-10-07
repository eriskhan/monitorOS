import Darwin
import Dispatch
import Foundation
import dnssd
import MonitorOSCapture

struct MonitorOSSinkDiscoverySnapshot: Sendable {
    let target: String?
    let serviceCount: Int
    let error: String?
    let generation: UInt64
}

private struct MonitorOSDiscoveredService: Hashable {
    let name: String
    let type: String
    let domain: String
    let interfaceIndex: UInt32

    var diagnosticName: String {
        "\(name)@ifindex=\(interfaceIndex)"
    }
}

final class MonitorOSSinkDiscovery: @unchecked Sendable {
    static let serviceType = "_monitoros._tcp"
    static let monitorLinkInterfaceName = "bridge0"

    private let queue = DispatchQueue(
        label: "org.monitoros.helper.discovery"
    )
    private let condition = NSCondition()
    private let onChange: (@Sendable () -> Void)?

    private var browseRef: DNSServiceRef?
    private var resolveRef: DNSServiceRef?
    private var addressRef: DNSServiceRef?
    private var services = Set<MonitorOSDiscoveredService>()
    private var activeService: MonitorOSDiscoveredService?
    private var resolvedPort: UInt16?

    private var target: String?
    private var serviceCount = 0
    private var error: String?
    private var generation: UInt64 = 0

    init(onChange: (@Sendable () -> Void)? = nil) throws {
        self.onChange = onChange

        var reference: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let result = Self.serviceType.withCString { serviceType in
            DNSServiceBrowse(
                &reference,
                0,
                UInt32(kDNSServiceInterfaceIndexAny),
                serviceType,
                nil,
                monitorOSBrowseReply,
                context
            )
        }

        guard result == kDNSServiceErr_NoError,
              let reference else {
            throw MonitorOSCaptureError(
                "Bonjour browse start failed: \(result)"
            )
        }

        let scheduleResult = DNSServiceSetDispatchQueue(reference, queue)
        guard scheduleResult == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(reference)
            throw MonitorOSCaptureError(
                "Bonjour browse scheduling failed: \(scheduleResult)"
            )
        }

        browseRef = reference
    }

    deinit {
        if let addressRef {
            DNSServiceRefDeallocate(addressRef)
        }
        if let resolveRef {
            DNSServiceRefDeallocate(resolveRef)
        }
        if let browseRef {
            DNSServiceRefDeallocate(browseRef)
        }
    }

    func snapshot() -> MonitorOSSinkDiscoverySnapshot {
        condition.lock()
        defer { condition.unlock() }
        return MonitorOSSinkDiscoverySnapshot(
            target: target,
            serviceCount: serviceCount,
            error: error,
            generation: generation
        )
    }

    func waitForChange(
        after observedGeneration: UInt64,
        timeout: TimeInterval
    ) -> MonitorOSSinkDiscoverySnapshot {
        let deadline = Date(timeIntervalSinceNow: timeout)

        condition.lock()
        while generation == observedGeneration {
            if !condition.wait(until: deadline) {
                break
            }
        }
        let snapshot = MonitorOSSinkDiscoverySnapshot(
            target: target,
            serviceCount: serviceCount,
            error: error,
            generation: generation
        )
        condition.unlock()
        return snapshot
    }

    func retryResolution() {
        queue.async { [weak self] in
            self?.retryResolutionOnQueue()
        }
    }

    fileprivate func handleBrowse(
        flags: DNSServiceFlags,
        interfaceIndex: UInt32,
        errorCode: DNSServiceErrorType,
        serviceName: UnsafePointer<CChar>?,
        regtype: UnsafePointer<CChar>?,
        domain: UnsafePointer<CChar>?
    ) {
        guard errorCode == kDNSServiceErr_NoError else {
            publish(
                target: nil,
                serviceCount: services.count,
                error: "Bonjour browse failed: \(errorCode)"
            )
            return
        }

        guard let serviceName,
              let regtype,
              let domain else {
            return
        }

        guard let interfaceName = Self.interfaceName(
            for: interfaceIndex
        ),
        Self.isMonitorLinkInterfaceName(interfaceName) else {
            return
        }

        let service = MonitorOSDiscoveredService(
            name: String(cString: serviceName),
            type: String(cString: regtype),
            domain: String(cString: domain),
            interfaceIndex: interfaceIndex
        )
        let added = flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0
        if added {
            services.insert(service)
        } else {
            services.remove(service)
        }
        reconcile()
    }

    fileprivate func handleResolve(
        interfaceIndex: UInt32,
        errorCode: DNSServiceErrorType,
        hostTarget: UnsafePointer<CChar>?,
        port: UInt16
    ) {
        clearResolveRef()

        guard errorCode == kDNSServiceErr_NoError else {
            publish(
                target: nil,
                serviceCount: services.count,
                error: "Bonjour resolve failed: \(errorCode)"
            )
            return
        }

        guard let activeService,
              activeService.interfaceIndex == interfaceIndex,
              services.contains(activeService),
              let hostTarget else {
            reconcile()
            return
        }

        let resolvedPort = UInt16(bigEndian: port)
        self.resolvedPort = resolvedPort
        startAddressLookup(
            host: String(cString: hostTarget),
            interfaceIndex: interfaceIndex
        )
    }

    fileprivate func handleAddress(
        flags: DNSServiceFlags,
        interfaceIndex: UInt32,
        errorCode: DNSServiceErrorType,
        address: UnsafePointer<sockaddr>?
    ) {
        guard errorCode == kDNSServiceErr_NoError else {
            clearAddressRef()
            publish(
                target: nil,
                serviceCount: services.count,
                error: "Bonjour address lookup failed: \(errorCode)"
            )
            return
        }

        if let activeService,
           activeService.interfaceIndex == interfaceIndex,
           services.contains(activeService),
           let address,
           let resolvedPort,
           let target = Self.scopedIPv6Target(
                address: address,
                interfaceIndex: interfaceIndex,
                port: resolvedPort
           ) {
            clearAddressRef()
            publish(
                target: target,
                serviceCount: services.count,
                error: nil
            )
            return
        }

        let moreComing =
            flags & DNSServiceFlags(kDNSServiceFlagsMoreComing) != 0
        if !moreComing {
            clearAddressRef()
            publish(
                target: nil,
                serviceCount: services.count,
                error: "monitorOS service has no IPv6 link-local address"
            )
        }
    }

    static func interfaceName(for index: UInt32) -> String? {
        var buffer = [CChar](
            repeating: 0,
            count: Int(IF_NAMESIZE)
        )
        let result = buffer.withUnsafeMutableBufferPointer { bytes in
            if_indextoname(index, bytes.baseAddress)
        }
        guard result != nil else {
            return nil
        }
        return String(cString: buffer)
    }

    static func isMonitorLinkInterfaceName(_ name: String) -> Bool {
        name == monitorLinkInterfaceName
    }

    static func scopedIPv6Target(
        address: UnsafePointer<sockaddr>,
        interfaceIndex: UInt32,
        port: UInt16
    ) -> String? {
        guard address.pointee.sa_family == sa_family_t(AF_INET6) else {
            return nil
        }

        var scoped = address.withMemoryRebound(
            to: sockaddr_in6.self,
            capacity: 1
        ) { $0.pointee }
        scoped.sin6_scope_id = interfaceIndex

        var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let result = host.withUnsafeMutableBufferPointer { buffer in
            withUnsafePointer(to: &scoped) { pointer in
                pointer.withMemoryRebound(
                    to: sockaddr.self,
                    capacity: 1
                ) { socketAddress in
                    getnameinfo(
                        socketAddress,
                        socklen_t(MemoryLayout<sockaddr_in6>.size),
                        buffer.baseAddress,
                        socklen_t(buffer.count),
                        nil,
                        0,
                        NI_NUMERICHOST
                    )
                }
            }
        }
        guard result == 0 else {
            return nil
        }

        let numericHost = String(cString: host)
        guard numericHost.lowercased().hasPrefix("fe80:") else {
            return nil
        }
        return "[\(numericHost)]:\(port)"
    }

    private func reconcile() {
        let count = services.count
        guard count == 1,
              let service = services.first else {
            cancelResolution()
            activeService = nil
            resolvedPort = nil
            publish(
                target: nil,
                serviceCount: count,
                error: count > 1
                    ? "multiple monitorOS sink advertisements discovered: " +
                        services
                            .sorted {
                                if $0.name != $1.name {
                                    return $0.name < $1.name
                                }
                                return $0.interfaceIndex < $1.interfaceIndex
                            }
                            .map(\.diagnosticName)
                            .joined(separator: ", ") +
                        "; refusing to choose"
                    : nil
            )
            return
        }

        if activeService == service,
           resolveRef != nil || addressRef != nil || snapshot().target != nil {
            publish(
                target: snapshot().target,
                serviceCount: count,
                error: nil
            )
            return
        }

        cancelResolution()
        activeService = service
        resolvedPort = nil
        publish(target: nil, serviceCount: count, error: nil)
        startResolve(service)
    }

    private func startResolve(_ service: MonitorOSDiscoveredService) {
        var reference: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()

        let result = service.name.withCString { name in
            service.type.withCString { type in
                service.domain.withCString { domain in
                    DNSServiceResolve(
                        &reference,
                        0,
                        service.interfaceIndex,
                        name,
                        type,
                        domain,
                        monitorOSResolveReply,
                        context
                    )
                }
            }
        }
        guard result == kDNSServiceErr_NoError,
              let reference else {
            publish(
                target: nil,
                serviceCount: services.count,
                error: "Bonjour resolve start failed: \(result)"
            )
            return
        }

        let scheduleResult = DNSServiceSetDispatchQueue(reference, queue)
        guard scheduleResult == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(reference)
            publish(
                target: nil,
                serviceCount: services.count,
                error: "Bonjour resolve scheduling failed: \(scheduleResult)"
            )
            return
        }

        resolveRef = reference
    }

    private func startAddressLookup(
        host: String,
        interfaceIndex: UInt32
    ) {
        clearAddressRef()

        var reference: DNSServiceRef?
        let context = Unmanaged.passUnretained(self).toOpaque()
        let protocols = DNSServiceProtocol(kDNSServiceProtocol_IPv6)
        let result = host.withCString { hostname in
            DNSServiceGetAddrInfo(
                &reference,
                0,
                interfaceIndex,
                protocols,
                hostname,
                monitorOSAddressReply,
                context
            )
        }
        guard result == kDNSServiceErr_NoError,
              let reference else {
            publish(
                target: nil,
                serviceCount: services.count,
                error: "Bonjour address lookup start failed: \(result)"
            )
            return
        }

        let scheduleResult = DNSServiceSetDispatchQueue(reference, queue)
        guard scheduleResult == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(reference)
            publish(
                target: nil,
                serviceCount: services.count,
                error: "Bonjour address scheduling failed: \(scheduleResult)"
            )
            return
        }

        addressRef = reference
    }

    private func retryResolutionOnQueue() {
        guard snapshot().target == nil,
              services.count == 1,
              let service = services.first else {
            return
        }

        cancelResolution()
        activeService = service
        resolvedPort = nil
        publish(
            target: nil,
            serviceCount: services.count,
            error: nil
        )
        startResolve(service)
    }

    private func cancelResolution() {
        clearAddressRef()
        clearResolveRef()
    }

    private func clearResolveRef() {
        if let resolveRef {
            DNSServiceRefDeallocate(resolveRef)
            self.resolveRef = nil
        }
    }

    private func clearAddressRef() {
        if let addressRef {
            DNSServiceRefDeallocate(addressRef)
            self.addressRef = nil
        }
    }

    private func publish(
        target newTarget: String?,
        serviceCount newServiceCount: Int,
        error newError: String?
    ) {
        condition.lock()
        guard target != newTarget
                || serviceCount != newServiceCount
                || error != newError else {
            condition.unlock()
            return
        }

        target = newTarget
        serviceCount = newServiceCount
        error = newError
        generation &+= 1
        condition.broadcast()
        condition.unlock()

        onChange?()
    }
}

private let monitorOSBrowseReply: DNSServiceBrowseReply = {
    _,
    flags,
    interfaceIndex,
    errorCode,
    serviceName,
    regtype,
    domain,
    context in
    guard let context else {
        return
    }
    Unmanaged<MonitorOSSinkDiscovery>
        .fromOpaque(context)
        .takeUnretainedValue()
        .handleBrowse(
            flags: flags,
            interfaceIndex: interfaceIndex,
            errorCode: errorCode,
            serviceName: serviceName,
            regtype: regtype,
            domain: domain
        )
}

private let monitorOSResolveReply: DNSServiceResolveReply = {
    _,
    _,
    interfaceIndex,
    errorCode,
    _,
    hostTarget,
    port,
    _,
    _,
    context in
    guard let context else {
        return
    }
    Unmanaged<MonitorOSSinkDiscovery>
        .fromOpaque(context)
        .takeUnretainedValue()
        .handleResolve(
            interfaceIndex: interfaceIndex,
            errorCode: errorCode,
            hostTarget: hostTarget,
            port: port
        )
}

private let monitorOSAddressReply: DNSServiceGetAddrInfoReply = {
    _,
    flags,
    interfaceIndex,
    errorCode,
    _,
    address,
    _,
    context in
    guard let context else {
        return
    }
    Unmanaged<MonitorOSSinkDiscovery>
        .fromOpaque(context)
        .takeUnretainedValue()
        .handleAddress(
            flags: flags,
            interfaceIndex: interfaceIndex,
            errorCode: errorCode,
            address: address
        )
}
