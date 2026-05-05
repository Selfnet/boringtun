{ pkgs, lib, ... }:

let
  keys = {
    server = {
      priv = "0D3W3CFITKsFMSLI2HMSaRWbbKZc29ZOkXoh6cjpn2g=";
      pub = "+NjoL7JmcwHJ0xElP/+NkeVO2tYEQ4mERprJCp+w6VQ=";
    };
    clientA = {
      priv = "uA4efIBD3VlXYiK0PL/4td6jca5+R1nnwTgH28ka3V0=";
      pub = "aM/q9eNAtPquxeAcwyIjV9ExqiXSqLCrDT8JhM775Bo=";
    };
    clientB = {
      priv = "2JAGAqZhUL7OR68xMdA+8F4iiZn4lpYBAbpIjAeonnU=";
      pub = "0VqNvsM314XX+scvIt5oktBYhToXObM0q3bOm1+k6Sc=";
    };
  };

  routerConfig = id: { pkgs, ... }: {
    virtualisation.vlans = [ id (id + 1) ];

    networking.firewall.enable = false;
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    boot.kernel.sysctl."net.ipv6.conf.all.forwarding" = 1;
    boot.kernel.sysctl."net.ipv6.conf.all.accept_ra" = 0;

    networking.useDHCP = false;
    networking.useNetworkd = true;

    systemd.network.networks."40-eth1" = lib.mkForce {
      matchConfig.Name = "eth1";
      networkConfig = {
        Address = [ "192.168.${builtins.toString id}.1/24" "fd00:192:168:${builtins.toString id}::1/64" ];
        DHCP = "no";
      };
    };

    systemd.network.networks."40-eth2" = lib.mkForce {
      matchConfig.Name = "eth2";
      networkConfig = {
        Address = [ "192.168.${builtins.toString (id + 1)}.1/24" "fd00:192:168:${builtins.toString (id + 1)}::1/64" ];
        DHCP = "no";
      };
    };

    environment.systemPackages = [ pkgs.tcpdump ];
  };

  clientConfig = vlanId: gwIp: gwIp6: endpoint: wgIp: wgIp6: privKey: { pkgs, ... }: {
    virtualisation.vlans = [ vlanId ];

    networking.firewall.enable = false;
    boot.kernel.sysctl."net.ipv6.conf.all.accept_ra" = 0;

    networking.useDHCP = false;
    networking.useNetworkd = true;

    systemd.network.networks."40-eth1" = lib.mkForce {
      matchConfig.Name = "eth1";
      networkConfig = {
        Address = [ "192.168.${builtins.toString vlanId}.2/24" "fd00:192:168:${builtins.toString vlanId}::2/64" ];
        Gateway = [ gwIp gwIp6 ];
        DHCP = "no";
      };
    };

    systemd.network.netdevs."90-wg0" = {
      netdevConfig = {
        Name = "wg0";
        Kind = "wireguard";
      };
      wireguardConfig = {
        PrivateKeyFile = pkgs.writeText "wg0-privkey" privKey;
      };
      wireguardPeers = [
        {
          PublicKey = keys.server.pub;
          AllowedIPs = [ "10.0.0.1/32" "fd00::1/128" ];
          Endpoint = endpoint;
        }
      ];
    };

    systemd.network.networks."90-wg0" = {
      matchConfig.Name = "wg0";
      networkConfig = {
        Address = [ "${wgIp}/24" "${wgIp6}/64" ];
      };
    };

    environment.systemPackages = [ pkgs.wireguard-tools pkgs.tcpdump ];
  };

in
{
  name = "boringtun-vrf";

  nodes.gwA = routerConfig 1;
  nodes.gwB = routerConfig 3;
  nodes.gwC = routerConfig 5;

  nodes.clientA = lib.mkMerge [
    (clientConfig 2 "192.168.2.1" "fd00:192:168:2::1" "192.168.1.2:51820" "10.0.0.2" "fd00::2" keys.clientA.priv)
    ({ pkgs, ... }: {
      virtualisation.vlans = lib.mkForce [ 2 6 ];
      systemd.network.networks."40-eth2" = lib.mkForce {
        matchConfig.Name = "eth2";
        networkConfig = {
          Address = [ "192.168.6.2/24" "fd00:192:168:6::2/64" ];
          DHCP = "no";
        };
        routes = [
          { Destination = "192.168.5.2/32"; Gateway = "192.168.6.1"; }
          { Destination = "fd00:192:168:5::2/128"; Gateway = "fd00:192:168:6::1"; }
        ];
      };
    })
  ];

  nodes.clientB = clientConfig 4 "192.168.4.1" "fd00:192:168:4::1" "[fd00:192:168:3::2]:51820" "10.0.0.3" "fd00::3" keys.clientB.priv;

  nodes.server = { pkgs, ... }: {
    virtualisation.vlans = [ 1 3 5 ];

    networking.firewall.enable = false;
    networking.useDHCP = false;
    networking.useNetworkd = true;

    boot.kernel.sysctl = {
      "net.ipv6.conf.all.accept_ra" = 0;
      "net.ipv4.udp_l3mdev_accept" = 1;
      "net.ipv4.conf.all.rp_filter" = 0;
      "net.ipv4.conf.default.rp_filter" = 0;
    };

    environment.systemPackages = [ pkgs.wireguard-tools pkgs.boringtun pkgs.tcpdump ];

    environment.etc."wireguard/wg0.conf".text = ''
      [Interface]
      ListenPort = 51820
      PrivateKey = ${keys.server.priv}

      [Peer]
      PublicKey = ${keys.clientA.pub}
      AllowedIPs = 10.0.0.2/32, fd00::2/128

      [Peer]
      PublicKey = ${keys.clientB.pub}
      AllowedIPs = 10.0.0.3/32, fd00::3/128
    '';

    systemd.network.netdevs = {
      "vrf-a" = { netdevConfig = { Name = "vrf-a"; Kind = "vrf"; }; vrfConfig = { Table = 1; }; };
      "vrf-b" = { netdevConfig = { Name = "vrf-b"; Kind = "vrf"; }; vrfConfig = { Table = 3; }; };
      "vrf-c" = { netdevConfig = { Name = "vrf-c"; Kind = "vrf"; }; vrfConfig = { Table = 5; }; };
    };

    systemd.network.networks = {
      "01-lo-default" = {
        matchConfig.Name = "lo";
        routes = [{ Destination = "0.0.0.0/0"; Type = "blackhole"; }];
      };

      "10-vrf-a" = {
        matchConfig.Name = "vrf-a";
        networkConfig.Address = [ "127.0.0.1/8" "::1/128" ];
        routingPolicyRules = [{ FirewallMark = 1; Table = 1; }];
      };
      "10-vrf-b" = {
        matchConfig.Name = "vrf-b";
        networkConfig.Address = [ "127.0.0.1/8" "::1/128" ];
        routingPolicyRules = [{ FirewallMark = 3; Table = 3; }];
      };
      "10-vrf-c" = {
        matchConfig.Name = "vrf-c";
        networkConfig.Address = [ "127.0.0.1/8" "::1/128" ];
        routingPolicyRules = [{ FirewallMark = 5; Table = 5; }];
      };

      "40-eth1" = lib.mkForce {
        matchConfig.Name = "eth1";
        networkConfig = { Address = [ "192.168.1.2/24" "fd00:192:168:1::2/64" ]; Gateway = [ "192.168.1.1" "fd00:192:168:1::1" ]; DHCP = "no"; VRF = "vrf-a"; };
      };

      "40-eth2" = lib.mkForce {
        matchConfig.Name = "eth2";
        networkConfig = { Address = [ "192.168.3.2/24" "fd00:192:168:3::2/64" ]; Gateway = [ "192.168.3.1" "fd00:192:168:3::1" ]; DHCP = "no"; VRF = "vrf-b"; };
      };

      "40-eth3" = lib.mkForce {
        matchConfig.Name = "eth3";
        networkConfig = { Address = [ "192.168.5.2/24" "fd00:192:168:5::2/64" ]; Gateway = [ "192.168.5.1" "fd00:192:168:5::1" ]; DHCP = "no"; VRF = "vrf-c"; };
      };
    };
  };

  testScript = ''
    start_all()

    for node in [gwA, gwB, gwC, server, clientA, clientB]:
        node.wait_for_unit("default.target")
        node.wait_for_unit("systemd-networkd.service")

    # Wait for the client WireGuard interfaces to be configured by systemd-networkd
    clientA.wait_until_succeeds("ip link show wg0 | grep -q UP")
    clientB.wait_until_succeeds("ip link show wg0 | grep -q UP")

    # Verify base reachability from clients to the server's outer IPs
    clientA.wait_until_succeeds("ping -W 10 -c 1 192.168.1.2")
    clientA.wait_until_succeeds("ping -6 -W 10 -c 1 fd00:192:168:1::2")
    clientA.wait_until_succeeds("ping -W 10 -c 1 192.168.5.2")
    clientA.wait_until_succeeds("ping -6 -W 10 -c 1 fd00:192:168:5::2")
    clientB.wait_until_succeeds("ping -W 10 -c 1 192.168.3.2")
    clientB.wait_until_succeeds("ping -6 -W 10 -c 1 fd00:192:168:3::2")

    for disable_connected_udp in [True, False]:
        print(f"Testing with disable_connected_udp={disable_connected_udp}")

        args = "--disable-connected-udp " if disable_connected_udp else ""

        # Start boringtun userspace endpoint on the server
        server.succeed(f"boringtun-cli --disable-drop-privileges {args}--log /root/wg0-log --verbosity trace wg0")
        server.succeed("wg setconf wg0 /etc/wireguard/wg0.conf")
        server.succeed("ip addr add 10.0.0.1/24 dev wg0")
        server.succeed("ip -6 addr add fd00::1/64 dev wg0")
        server.succeed("ip link set up dev wg0")

        # Test normal pings from clients
        clientA.wait_until_succeeds("ping -W 10 -i 0.2 -c 3 10.0.0.1")
        clientB.wait_until_succeeds("ping -W 10 -i 0.2 -c 3 10.0.0.1")
        clientA.wait_until_succeeds("ping -6 -W 10 -i 0.2 -c 3 fd00::1")
        clientB.wait_until_succeeds("ping -6 -W 10 -i 0.2 -c 3 fd00::1")

        # Test large packets to verify fragmentation over VRFs
        clientA.wait_until_succeeds("ping -W 10 -i 0.2 -s 1400 -c 3 10.0.0.1")
        clientB.wait_until_succeeds("ping -W 10 -i 0.2 -s 1400 -c 3 10.0.0.1")
        clientA.wait_until_succeeds("ping -6 -W 10 -i 0.2 -s 1400 -c 3 fd00::1")
        clientB.wait_until_succeeds("ping -6 -W 10 -i 0.2 -s 1400 -c 3 fd00::1")

        # Test Client Port Roaming
        print("Testing Client Port Roaming...")
        clientA.succeed("wg set wg0 listen-port 51821")
        clientB.succeed("wg set wg0 listen-port 51821")

        clientA.wait_until_succeeds("ping -W 10 -i 0.2 -c 3 10.0.0.1")
        clientB.wait_until_succeeds("ping -W 10 -i 0.2 -c 3 10.0.0.1")
        clientA.wait_until_succeeds("ping -6 -W 10 -i 0.2 -c 3 fd00::1")
        clientB.wait_until_succeeds("ping -6 -W 10 -i 0.2 -c 3 fd00::1")

        # Test Client VRF Roaming
        print("Testing Client VRF Roaming...")
        clientA.succeed("wg set wg0 peer ${keys.server.pub} endpoint 192.168.5.2:51820")
        clientA.wait_until_succeeds("ping -W 10 -i 0.2 -c 3 10.0.0.1")
        clientA.wait_until_succeeds("ping -6 -W 10 -i 0.2 -c 3 fd00::1")
        server.succeed("wg show wg0 endpoints | grep -q 192.168.6.2")

        clientA.succeed("wg set wg0 peer ${keys.server.pub} endpoint 192.168.1.2:51820")
        clientA.wait_until_succeeds("ping -W 10 -i 0.2 -c 3 10.0.0.1")
        clientA.wait_until_succeeds("ping -6 -W 10 -i 0.2 -c 3 fd00::1")
        server.succeed("wg show wg0 endpoints | grep -q 192.168.2.2")

        # Test Simultaneous Load
        print("Testing Simultaneous Load...")
        clientA.succeed("systemd-run --unit=ping-load-v4 --no-block ping -W 10 -i 0.01 -c 200 10.0.0.1")
        clientB.succeed("systemd-run --unit=ping-load-v4 --no-block ping -W 10 -i 0.01 -c 200 10.0.0.1")
        clientA.succeed("systemd-run --unit=ping-load-v6 --no-block ping -W 10 -i 0.01 -c 200 fd00::1")
        clientB.succeed("systemd-run --unit=ping-load-v6 --no-block ping -W 10 -i 0.01 -c 200 fd00::1")

        for client in [clientA, clientB]:
            for unit in ["ping-load-v4.service", "ping-load-v6.service"]:
                client.wait_until_succeeds(f"! systemctl is-active -q {unit}")
                client.succeed(f"! systemctl is-failed -q {unit}")

        # Tear down for next iteration
        server.succeed("ip link del wg0")
        # Ensure boringtun-cli is dead before next iteration
        server.succeed("pkill boringtun-cli || true")
  '';
}
