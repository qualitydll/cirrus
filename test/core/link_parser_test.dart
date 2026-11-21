import 'package:cirrus/core/link_parser.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes provider-only Mihomo YAML without inline proxies', () {
    const yaml = '''
mixed-port: 7890
proxy-providers:
  locations:
    type: http
    url: https://example.org/locations.yaml
    path: ./providers/locations.yaml
    interval: 3600
proxy-groups:
  - name: PROXY
    type: select
    use:
      - locations
rules:
  - MATCH,PROXY
''';

    final parsed = parseSubscription(yaml);

    expect(parsed.clashConfig, isNotNull);
    expect(parsed.clashConfig!['proxy-providers'], isA<Map>());
    expect(parsed.clashConfig!['proxy-groups'], isA<List>());
    expect(parsed.clashConfig!['rules'], ['MATCH,PROXY']);
    expect(parsed.proxyCount, 0);
  });

  group('aegis:// links', () {
    test('turbo preset maps to hysteria2 with obfs params', () {
      final p = parseLink(
        'aegis://turbo.s3cret-pw@vpn.example.com:443'
        '?sni=www.bing.com&obfs=salamander&obfs-password=obfs1#de-fra-01',
      );
      expect(p, isNotNull);
      expect(p!['type'], 'hysteria2');
      expect(p['server'], 'vpn.example.com');
      expect(p['port'], 443);
      expect(p['password'], 's3cret-pw');
      expect(p['sni'], 'www.bing.com');
      expect(p['obfs'], 'salamander');
      expect(p['obfs-password'], 'obfs1');
      expect(p['name'], 'AEGIS · UDP · FEC — de-fra-01');
    });

    test('eco preset maps to vless reality', () {
      final p = parseLink(
        'aegis://eco.9f1c2a@203.0.113.10:8443'
        '?sni=dl.google.com&pbk=PUBLICKEY&sid=abcd&fp=chrome#home',
      );
      expect(p, isNotNull);
      expect(p!['type'], 'vless');
      expect(p['uuid'], '9f1c2a');
      expect(p['tls'], true);
      expect(p['servername'], 'dl.google.com');
      expect(p['reality-opts'], isA<Map>());
      expect((p['reality-opts'] as Map)['public-key'], 'PUBLICKEY');
      expect(p['name'], 'AEGIS · TCP · TLS · REALITY — home');
    });

    test('cfws preset maps to vless ws tls', () {
      final p = parseLink(
        'aegis://cfws.uuid-here@vpn.example.com:443'
        '?sni=example.com&path=%2Frand&host=example.com#cf-node',
      );
      expect(p, isNotNull);
      expect(p!['type'], 'vless');
      expect(p['network'], 'ws');
      expect(p['tls'], true);
      expect((p['ws-opts'] as Map)['path'], '/rand');
      expect(p['name'], 'AEGIS · WS · CF — cf-node');
    });

    test('cfgrpc preset maps to vless grpc tls with service name', () {
      final p = parseLink(
        'aegis://cfgrpc.uuid-here@vpn.example.com:443'
        '?sni=example.com&serviceName=aegis-svc#grpc-node',
      );
      expect(p, isNotNull);
      expect(p!['type'], 'vless');
      expect(p['network'], 'grpc');
      expect((p['grpc-opts'] as Map)['grpc-service-name'], 'aegis-svc');
      expect(p['name'], 'AEGIS · gRPC · CF — grpc-node');
    });

    test('unknown preset returns null', () {
      expect(parseLink('aegis://nope.auth@host:443#x'), isNull);
    });

    test('missing auth returns null', () {
      expect(parseLink('aegis://turbo@host:443#x'), isNull);
    });
  });
}
