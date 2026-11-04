import NetworkExtension

/// Пробный туннель: поднимает VPN-интерфейс с маршрутом только на служебную подсеть,
/// поэтому реальный трафик не перехватывается. Нужен, чтобы проверить, что подпись
/// приложения позволяет запускать Network Extension. Ядро Xray подключим следующим шагом.
final class PacketTunnelProvider: NEPacketTunnelProvider {
    override func startTunnel(options: [String: NSObject]?, completionHandler: @escaping (Error?) -> Void) {
        let settings = NEPacketTunnelNetworkSettings(tunnelRemoteAddress: "10.255.0.1")
        let ipv4 = NEIPv4Settings(addresses: ["10.255.0.2"], subnetMasks: ["255.255.255.0"])
        ipv4.includedRoutes = [NEIPv4Route(destinationAddress: "10.255.0.0", subnetMask: "255.255.255.0")]
        settings.ipv4Settings = ipv4
        settings.mtu = 1400
        setTunnelNetworkSettings(settings) { error in
            completionHandler(error)
        }
    }

    override func stopTunnel(with reason: NEProviderStopReason, completionHandler: @escaping () -> Void) {
        completionHandler()
    }

    override func handleAppMessage(_ messageData: Data, completionHandler: ((Data?) -> Void)?) {
        let text = String(data: messageData, encoding: .utf8) ?? ""
        completionHandler?(Data((text == "ping" ? "pong" : "unknown").utf8))
    }
}
