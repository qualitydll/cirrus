import 'package:flutter/services.dart';

/// A launchable Android app shown in the bypass picker.
class AndroidAppEntry {
  const AndroidAppEntry({required this.packageName, required this.label});

  /// Package name used by `VpnService.Builder.addDisallowedApplication`.
  final String packageName;

  /// User-facing app label.
  final String label;
}

/// Returns installed launchable apps via the Android MethodChannel.
/// Empty list on non-Android platforms or when the channel is unavailable.
Future<List<AndroidAppEntry>> listInstalledAndroidApps() async {
  try {
    final raw = await const MethodChannel(
      'dev.cirrus.app/vpn',
    ).invokeMethod('listApps');
    if (raw is! List) return const [];
    final apps = <AndroidAppEntry>[];
    for (final item in raw) {
      if (item is! Map) continue;
      final packageName = item['package']?.toString();
      if (packageName == null || packageName.isEmpty) continue;
      final label = item['label']?.toString() ?? packageName;
      apps.add(AndroidAppEntry(packageName: packageName, label: label));
    }
    apps.sort(
      (a, b) => a.label.toLowerCase().compareTo(b.label.toLowerCase()),
    );
    return apps;
  } catch (_) {
    return const [];
  }
}
