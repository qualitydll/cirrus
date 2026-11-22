import 'dart:io';

import 'package:flutter/material.dart';

import '../../core/android_apps.dart';
import '../../core/windows_apps.dart';
import '../../state/app_state.dart';
import '../widgets/common.dart';

class BypassPage extends StatelessWidget {
  const BypassPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    final isAndroid = Platform.isAndroid;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const PageHeader(
          title: 'Обход VPN',
          subtitle:
              'Прямой доступ без VPN. Windows: нужен режим TUN; Android: приложения исключаются на уровне VPN.',
        ),
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(32, 0, 32, 32),
            children: [
              if (isAndroid) _AndroidBypassSection(state: state),
              if (!isAndroid) _WindowsBypassSection(state: state),
            ],
          ),
        ),
      ],
    );
  }
}

class _AndroidBypassSection extends StatefulWidget {
  const _AndroidBypassSection({required this.state});
  final AppState state;

  @override
  State<_AndroidBypassSection> createState() => _AndroidBypassSectionState();
}

class _AndroidBypassSectionState extends State<_AndroidBypassSection> {
  final List<String> _selectedApps = [];
  List<AndroidAppEntry> _apps = const [];
  final Map<String, String> _appLabels = {};
  bool _isLoading = false;

  @override
  void initState() {
    super.initState();
    _selectedApps.addAll(widget.state.settings.androidBypassApps);
    _refreshApps();
  }

  Future<void> _refreshApps() async {
    final apps = await listInstalledAndroidApps();
    if (!mounted) return;
    setState(() {
      _apps = apps;
      _appLabels
        ..clear()
        ..addEntries(apps.map((app) => MapEntry(app.packageName, app.label)));
    });
  }

  Future<void> _loadApps() async {
    setState(() => _isLoading = true);
    if (_apps.isEmpty) await _refreshApps();
    if (!mounted) return;
    setState(() => _isLoading = false);
    _showAppSelector();
  }

  void _showAppSelector() {
    final known = _apps.map((app) => app.packageName).toSet();
    final choices = <AndroidAppEntry>[
      ..._apps,
      for (final packageName in _selectedApps)
        if (!known.contains(packageName))
          AndroidAppEntry(packageName: packageName, label: packageName),
    ];
    var query = '';

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final q = query.trim().toLowerCase();
          final filtered = q.isEmpty
              ? choices
              : choices.where((app) {
                  return app.label.toLowerCase().contains(q) ||
                      app.packageName.toLowerCase().contains(q);
                }).toList();
          return AlertDialog(
            title: const Text('Выберите приложения'),
            content: SizedBox(
              width: 560,
              height: 480,
              child: Column(
                children: [
                  TextField(
                    decoration: const InputDecoration(
                      prefixIcon: Icon(Icons.search_rounded),
                      hintText: 'Поиск приложений',
                      isDense: true,
                    ),
                    onChanged: (value) => setDialogState(() => query = value),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: filtered.isEmpty
                        ? const Center(child: Text('Ничего не найдено'))
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final app = filtered[index];
                              final isSelected = _selectedApps.contains(app.packageName);
                              return CheckboxListTile(
                                title: Text(app.label),
                                subtitle: Text(
                                  app.packageName,
                                  style: const TextStyle(fontSize: 11),
                                ),
                                value: isSelected,
                                onChanged: (value) {
                                  setState(() {
                                    if (value == true) {
                                      _selectedApps.add(app.packageName);
                                    } else {
                                      _selectedApps.remove(app.packageName);
                                    }
                                  });
                                  setDialogState(() {});
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () {
                  widget.state.setAndroidBypassApps(_selectedApps);
                  Navigator.pop(dialogContext);
                },
                child: const Text('Сохранить'),
              ),
            ],
          );
        },
      ),
    );
  }

  String _getAppName(String packageName) {
    final known = _appLabels[packageName];
    if (known != null) return known;
    final nameMap = {
      'com.android.chrome': 'Chrome',
      'com.whatsapp': 'WhatsApp',
      'com.instagram.android': 'Instagram',
      'com.facebook.katana': 'Facebook',
      'com.twitter.android': 'Twitter',
      'com.discord': 'Discord',
      'com.tencent.mm': 'WeChat',
      'com.spotify.music': 'Spotify',
      'com.netflix.mediaclient': 'Netflix',
      'com.youtube': 'YouTube',
      'com.google.android.youtube': 'YouTube',
      'com.vkontakte.android': 'VK',
      'com.google.android.gm': 'Gmail',
      'com.slack': 'Slack',
      'com.microsoft.teams': 'Microsoft Teams',
      'com.skype.raider': 'Skype',
      'com.zoom.us': 'Zoom',
      'ru.yandex.mail': 'Yandex Mail',
      'ru.yandex.disk': 'Yandex Disk',
      'ru.yandex.taxi': 'Yandex Taxi',
      'ru.yandex.metro': 'Yandex Metro',
      'ru.yandex.music': 'Yandex Music',
      'ru.yandex.browser': 'Yandex Browser',
      'com.sberbankmobile': 'СберБанк',
      'ru.tinkoff.mobile': 'Тинькофф',
      'ru.tcsbank.mb': 'Т-Банк',
      'com.vkontakte.bdev': 'VK Клипы',
      'ru.ozon.app.android': 'Ozon',
      'com.wildberries.ru': 'Wildberries',
      'com.avito.android': 'Авито',
    };
    return nameMap[packageName] ?? packageName;
  }

  @override
  Widget build(BuildContext context) {
    final bypassApps = widget.state.settings.androidBypassApps;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.android_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Приложения Android',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              FilledButton.icon(
                onPressed: _isLoading ? null : _loadApps,
                icon: _isLoading
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.add_rounded),
                label: const Text('Добавить'),
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (bypassApps.isEmpty)
            const Text('Нет приложений для обхода')
          else
            Column(
              children: [
                for (final app in bypassApps)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.apps_rounded),
                    title: Text(_getAppName(app)),
                    subtitle: Text(app, style: const TextStyle(fontSize: 11)),
                    trailing: IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => _removeApp(widget.state, app),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  void _removeApp(AppState state, String app) {
    final apps = state.settings.androidBypassApps.where((a) => a != app).toList();
    state.setAndroidBypassApps(apps);
  }
}

class _WindowsBypassSection extends StatelessWidget {
  const _WindowsBypassSection({required this.state});
  final AppState state;

  @override
  Widget build(BuildContext context) {
    final bypassProcesses = state.settings.windowsBypassProcesses;
    return GlassCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.computer_rounded),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'Процессы Windows',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
              ),
              IconButton(
                icon: const Icon(Icons.add_rounded),
                onPressed: () => _showProcessSelector(context, state),
                tooltip: 'Добавить процесс',
              ),
            ],
          ),
          const SizedBox(height: 16),
          if (bypassProcesses.isEmpty)
            const Text('Нет процессов для обхода')
          else
            Column(
              children: [
                for (final process in bypassProcesses)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.terminal_rounded),
                    title: Text(process),
                    trailing: IconButton(
                      icon: const Icon(Icons.close_rounded),
                      onPressed: () => _removeProcess(state, process),
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }

  Future<void> _showProcessSelector(BuildContext context, AppState state) async {
    final running = await listRunningWindowsApps();
    if (!context.mounted) return;

    final selected = <String>{...state.settings.windowsBypassProcesses};
    final fallback = [
      'chrome.exe',
      'firefox.exe',
      'msedge.exe',
      'opera.exe',
      'discord.exe',
      'spotify.exe',
      'telegram.exe',
      'WhatsApp.exe',
      'Skype.exe',
      'Teams.exe',
      'Zoom.exe',
      'Steam.exe',
      'EpicGamesLauncher.exe',
      'Origin.exe',
      'Uplay.exe',
      'Battle.net.exe',
      'vlc.exe',
      'notepad++.exe',
      'code.exe',
      'explorer.exe',
    ];
    final base = running.isNotEmpty
        ? running
        : fallback
            .map((process) => WindowsAppEntry(processName: process, title: process))
            .toList();
    final known = base.map((app) => app.processName.toLowerCase()).toSet();
    final choices = <WindowsAppEntry>[
      ...base,
      for (final process in selected)
        if (!known.contains(process.toLowerCase()))
          WindowsAppEntry(processName: process, title: process),
    ];
    var query = '';

    showDialog(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final q = query.trim().toLowerCase();
          final filtered = q.isEmpty
              ? choices
              : choices.where((app) {
                  return app.title.toLowerCase().contains(q) ||
                      app.processName.toLowerCase().contains(q);
                }).toList();
          return AlertDialog(
            title: const Text('Выберите процесс'),
            content: SizedBox(
              width: 560,
              height: 480,
              child: Column(
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: TextField(
                          decoration: const InputDecoration(
                            prefixIcon: Icon(Icons.search_rounded),
                            hintText: 'Поиск процессов',
                            isDense: true,
                          ),
                          onChanged: (value) => setDialogState(() => query = value),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.folder_open_rounded),
                        tooltip: 'Выбрать .exe',
                        onPressed: () async {
                          final exe = await pickWindowsExecutableName();
                          if (exe != null && dialogContext.mounted) {
                            setDialogState(() => selected.add(exe));
                          }
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: filtered.isEmpty
                        ? const Center(child: Text('Ничего не найдено'))
                        : ListView.builder(
                            itemCount: filtered.length,
                            itemBuilder: (context, index) {
                              final app = filtered[index];
                              final isSelected = selected.contains(app.processName);
                              return CheckboxListTile(
                                dense: true,
                                title: Text(app.title),
                                subtitle: Text(
                                  app.processName,
                                  style: const TextStyle(fontSize: 11),
                                ),
                                value: isSelected,
                                onChanged: (value) {
                                  setDialogState(() {
                                    if (value == true) {
                                      selected.add(app.processName);
                                    } else {
                                      selected.remove(app.processName);
                                    }
                                  });
                                },
                              );
                            },
                          ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: () {
                  final processes = selected.toList()..sort();
                  state.setWindowsBypassProcesses(processes);
                  Navigator.pop(dialogContext);
                },
                child: const Text('Сохранить'),
              ),
            ],
          );
        },
      ),
    );
  }

  void _removeProcess(AppState state, String process) {
    final processes = state.settings.windowsBypassProcesses.where((p) => p != process).toList();
    state.setWindowsBypassProcesses(processes);
  }
}
