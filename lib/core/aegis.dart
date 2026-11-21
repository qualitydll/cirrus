/// Aegis profile presets.
///
/// Aegis is a branding/transport layer: each preset maps onto a concrete
/// Mihomo outbound so the app stays compatible with the stock core. The VPS
/// panel (aegis/install.sh) generates matching sing-box inbounds.
library;

/// One Aegis preset: stable id used in `aegis://` links plus the human label
/// shown in node names and badges.
class AegisPreset {
  const AegisPreset({
    required this.id,
    required this.label,
    required this.description,
    required this.tier,
  });

  /// Short id placed in `aegis://<id>.<auth>@host:port`.
  final String id;

  /// Label rendered into the node name, e.g. `UDP · FEC`.
  final String label;

  /// One-line description for docs/tooltips.
  final String description;

  /// `turbo` for high-throughput devices, `eco` for lightweight clients.
  final String tier;
}

const Map<String, AegisPreset> aegisPresets = {
  'turbo': AegisPreset(
    id: 'turbo',
    label: 'UDP · FEC',
    description: 'Hysteria2 over UDP with obfuscation and forward error correction',
    tier: 'turbo',
  ),
  'eco': AegisPreset(
    id: 'eco',
    label: 'TCP · TLS · REALITY',
    description: 'VLESS over TCP with REALITY camouflage',
    tier: 'eco',
  ),
  'cfws': AegisPreset(
    id: 'cfws',
    label: 'WS · CF',
    description: 'VLESS over WebSocket behind Cloudflare',
    tier: 'eco',
  ),
  'cfgrpc': AegisPreset(
    id: 'cfgrpc',
    label: 'gRPC · CF',
    description: 'VLESS over gRPC behind Cloudflare',
    tier: 'eco',
  ),
};

/// Builds the display name stored on the parsed proxy so badges and the
/// server list can recognize Aegis nodes without extra config fields.
String aegisNodeName(String presetId, String fragment, String host) {
  final preset = aegisPresets[presetId];
  final label = preset?.label ?? presetId.toUpperCase();
  final suffix = fragment.isNotEmpty ? fragment : host;
  return 'AEGIS · $label — $suffix';
}
