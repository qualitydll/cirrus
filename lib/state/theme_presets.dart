import 'package:flutter/material.dart';

import '../brand.dart';

/// A ready-made Material You look for Cirrus.
///
/// Presets only change the seed color and dynamic-scheme variant; the user can
/// still override everything afterwards (that state is reported as `custom`).
class CirrusThemePreset {
  const CirrusThemePreset({
    required this.id,
    required this.name,
    required this.seed,
    required this.variant,
    required this.swatch,
  });

  final String id;
  final String name;
  final Color seed;
  final DynamicSchemeVariant variant;

  /// Representative accent used by the preset picker.
  final Color swatch;
}

const cirrusThemePresets = <CirrusThemePreset>[
  CirrusThemePreset(
    id: 'cirrus',
    name: 'Cirrus',
    seed: kCirrusBlue,
    variant: DynamicSchemeVariant.fidelity,
    swatch: kCirrusBlue,
  ),
  CirrusThemePreset(
    id: 'sky',
    name: 'Небо',
    seed: kCirrusSky,
    variant: DynamicSchemeVariant.content,
    swatch: kCirrusIce,
  ),
  CirrusThemePreset(
    id: 'aurora',
    name: 'Аврора',
    seed: kCirrusCyan,
    variant: DynamicSchemeVariant.rainbow,
    swatch: kCirrusCyan,
  ),
  CirrusThemePreset(
    id: 'midnight',
    name: 'Полночь',
    seed: kCirrusMidnight,
    variant: DynamicSchemeVariant.expressive,
    swatch: kCirrusViolet,
  ),
];

const customThemePresetId = 'custom';

CirrusThemePreset cirrusThemePresetById(String? id) {
  for (final preset in cirrusThemePresets) {
    if (preset.id == id) return preset;
  }
  return cirrusThemePresets.first;
}
