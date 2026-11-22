import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/aegis.dart';
import '../../state/app_state.dart';
import '../../state/models.dart';
import '../widgets/common.dart';
import 'aegis_deploy_dialog.dart';
import 'qr_scan_page.dart';

class ProfilesPage extends StatelessWidget {
  const ProfilesPage({super.key});

  @override
  Widget build(BuildContext context) {
    final state = AppScope.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        PageHeader(
          title: 'Подписки',
          subtitle: 'Ссылки на подписку, Clash YAML или ключи aegis / vless / vmess / trojan / ss / hy2 / tuic',
          actions: [
            if (state.profiles.any((p) => p.isRemote))
              FilledButton.tonalIcon(
                onPressed: state.busyProfile
                    ? null
                    : () async {
                        final message = await state.updateAllProfiles();
                        if (context.mounted) showSnack(context, message);
                      },
                icon: const Icon(Icons.sync_rounded),
                label: const Text('Обновить все'),
              ),
            FilledButton.icon(
              onPressed: () => showAddProfileDialog(context),
              icon: const Icon(Icons.add_rounded),
              label: const Text('Добавить'),
            ),
          ],
        ),
        Expanded(
          child: state.profiles.isEmpty
              ? const _Empty()
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(32, 4, 32, 32),
                  itemCount: state.profiles.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 12),
                  itemBuilder: (context, i) => StaggeredEntrance(
                    key: ValueKey(state.profiles[i].id),
                    index: i,
                    child: _ProfileTile(
                      profile: state.profiles[i],
                      active: state.profiles[i].id == state.activeProfile?.id,
                    ),
                  ),
                ),
        ),
      ],
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: StaggeredEntrance(
        index: 0,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 104,
              height: 104,
              decoration: ShapeDecoration(
                gradient: LinearGradient(
                  colors: [scheme.primaryContainer, scheme.tertiaryContainer],
                ),
                shape: const StarBorder(
                  points: 10,
                  innerRadiusRatio: 0.84,
                  pointRounding: 0.6,
                  valleyRounding: 0.4,
                ),
              ),
              child: Icon(
                Icons.layers_rounded,
                size: 44,
                color: scheme.onPrimaryContainer,
              ),
            ),
            const SizedBox(height: 20),
            Text('Пока пусто', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 6),
            Text(
              'Вставьте ссылку от вашего VPN-провайдера',
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () => showAddProfileDialog(context),
              icon: const Icon(Icons.content_paste_rounded),
              label: const Text('Добавить подписку'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileTile extends StatefulWidget {
  const _ProfileTile({required this.profile, required this.active});
  final Profile profile;
  final bool active;

  @override
  State<_ProfileTile> createState() => _ProfileTileState();
}

/// Masks sensitive host information for privacy.
String _maskHost(String host) {
  if (host.isEmpty || host == 'Локальный список') return host;
  
  // Mask IP addresses: 192.168.***.***
  if (RegExp(r'^\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3}').hasMatch(host)) {
    final parts = host.split('.');
    if (parts.length >= 4) {
      return '${parts[0]}.${parts[1]}.***.***';
    }
  }
  
  // Mask domains: keep first part, mask rest
  if (host.contains('.')) {
    final parts = host.split('.');
    if (parts.length >= 2) {
      return '${parts[0]}.***.${parts.last}';
    }
  }
  
  // Mask long strings
  if (host.length > 8) {
    return '${host.substring(0, 4)}***${host.substring(host.length - 4)}';
  }
  
  return '***';
}

class _ProfileTileState extends State<_ProfileTile> {
  bool _showSensitive = false;

  @override
  Widget build(BuildContext context) {
    final state = AppScope.read(context);
    final scheme = Theme.of(context).colorScheme;
    final t = Theme.of(context).textTheme;
    final pr = widget.profile;
    final active = widget.active;
    final host = pr.isAegisNative
        ? '${pr.aegisConfig?['server']}:${pr.aegisConfig?['port']}'
        : pr.url == null
            ? 'Локальный список'
            : Uri.tryParse(pr.url!)?.host ?? pr.url!;
    final displayHost = _showSensitive ? host : _maskHost(host);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 450),
      curve: Curves.easeOutCubic,
      decoration: BoxDecoration(
        color: active
            ? scheme.secondaryContainer.withValues(alpha: 0.9)
            : scheme.surfaceContainerLow.withValues(alpha: 0.75),
        borderRadius: BorderRadius.circular(active ? 32 : 24),
        border: Border.all(
          color: active
              ? scheme.secondary
              : scheme.outlineVariant.withValues(alpha: 0.4),
          width: active ? 2 : 1,
        ),
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(active ? 32 : 24),
          onTap: () => state.setActiveProfile(pr),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 16),
            child: Row(
              children: [
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 300),
                  transitionBuilder: (c, a) =>
                      ScaleTransition(scale: a, child: c),
                  child: Icon(
                    active
                        ? Icons.radio_button_checked_rounded
                        : Icons.radio_button_off_rounded,
                    key: ValueKey(active),
                    color: active ? scheme.secondary : scheme.outline,
                  ),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        pr.name,
                        style: t.titleMedium?.copyWith(
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        pr.isAegisNative
                            ? '$displayHost · AEGIS Native · ${timeAgo(pr.updatedAt)}'
                            : '$displayHost · ${pr.proxyCount} серверов · ${timeAgo(pr.updatedAt)}',
                        style: t.bodySmall?.copyWith(
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      if (pr.usage != null) ...[
                        const SizedBox(height: 10),
                        Row(
                          children: [
                            Expanded(
                              child: LinearProgressIndicator(
                                value: pr.usage,
                                minHeight: 6,
                                borderRadius: BorderRadius.circular(6),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Text(
                              '${formatBytes(pr.used)} / ${formatBytes(pr.total)}',
                              style: t.labelSmall,
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
                if (pr.isRemote)
                  IconButton(
                    tooltip: 'Обновить',
                    onPressed: () async {
                      try {
                        await state.updateProfile(pr);
                        if (context.mounted) {
                          showSnack(context, 'Подписка обновлена');
                        }
                      } catch (e) {
                        if (context.mounted) showSnack(context, 'Ошибка: $e');
                      }
                    },
                    icon: const Icon(Icons.refresh_rounded),
                  ),
                IconButton(
                  tooltip: _showSensitive ? 'Скрыть данные' : 'Показать данные',
                  onPressed: () => setState(() => _showSensitive = !_showSensitive),
                  icon: Icon(
                    _showSensitive ? Icons.visibility_off_rounded : Icons.visibility_rounded,
                    size: 20,
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (v) async {
                    if (v == 'rename') {
                      final name = await _prompt(context, 'Название', pr.name);
                      if (name != null && name.trim().isNotEmpty) {
                        await state.renameProfile(pr, name.trim());
                      }
                    } else if (v == 'copy' && pr.url != null) {
                      await Clipboard.setData(ClipboardData(text: pr.url!));
                      if (context.mounted) {
                        showSnack(context, 'Ссылка скопирована');
                      }
                    } else if (v == 'delete') {
                      await state.deleteProfile(pr);
                    }
                  },
                  itemBuilder: (_) => [
                    const PopupMenuItem(
                      value: 'rename',
                      child: Text('Переименовать'),
                    ),
                    if (pr.url != null)
                      const PopupMenuItem(
                        value: 'copy',
                        child: Text('Скопировать ссылку'),
                      ),
                    const PopupMenuItem(
                      value: 'delete',
                      child: Text('Удалить'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Future<String?> _prompt(BuildContext context, String title, String initial) {
  final c = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: TextField(
        controller: c,
        autofocus: true,
        onSubmitted: (v) => Navigator.pop(context, v),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(context, c.text),
          child: const Text('Сохранить'),
        ),
      ],
    ),
  );
}

/// Entry point for the "Добавить" button: QR scan (Android), paste a
/// link/key, or deploy Aegis onto your own VPS over SSH.
Future<void> showAddProfileDialog(BuildContext context) async {
  final method = await showModalBottomSheet<_AddMethod>(
    context: context,
    showDragHandle: true,
    builder: (context) => _AddMethodSheet(showQr: Platform.isAndroid),
  );
  if (method == null || !context.mounted) return;

  if (method == _AddMethod.vps) {
    await showAegisDeployDialog(context);
    return;
  }
  if (method == _AddMethod.aegisNative) {
    await _showAegisNativeDialog(context);
    return;
  }
  if (method == _AddMethod.qr) {
    final scanned = await Navigator.of(
      context,
    ).push<String>(MaterialPageRoute(builder: (_) => const QrScanPage()));
    if (scanned == null || !context.mounted) return;
    await _showAddDialog(context, initialInput: scanned);
    return;
  }
  await _showAddDialog(context);
}

Future<void> _showAddDialog(BuildContext context, {String? initialInput}) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'add',
    transitionDuration: const Duration(milliseconds: 420),
    pageBuilder: (context, _, _) => _AddDialog(initialInput: initialInput),
    transitionBuilder: (context, anim, _, child) {
      final curve = CurvedAnimation(
        parent: anim,
        curve: Curves.easeOutBack,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween(begin: 0.85, end: 1.0).animate(curve),
          child: child,
        ),
      );
    },
  );
}

enum _AddMethod { qr, link, vps, aegisNative }

class _AddMethodSheet extends StatelessWidget {
  const _AddMethodSheet({required this.showQr});

  /// QR scanning is only wired up on Android (mobile_scanner).
  final bool showQr;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
            child: Text(
              'Как добавить подписку?',
              style: Theme.of(context).textTheme.titleMedium,
            ),
          ),
          if (showQr)
            ListTile(
              leading: CircleAvatar(
                backgroundColor: scheme.primaryContainer,
                foregroundColor: scheme.onPrimaryContainer,
                child: const Icon(Icons.qr_code_scanner_rounded),
              ),
              title: const Text('Сканировать QR-код'),
              subtitle: const Text('Камерой — код от вашего VPN-провайдера'),
              onTap: () => Navigator.pop(context, _AddMethod.qr),
            ),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: scheme.secondaryContainer,
              foregroundColor: scheme.onSecondaryContainer,
              child: const Icon(Icons.link_rounded),
            ),
            title: const Text('Вставить ссылку или ключ'),
            subtitle: const Text(
              'Подписка, aegis / vless / vmess / trojan / ss / hy2 / tuic',
            ),
            onTap: () => Navigator.pop(context, _AddMethod.link),
          ),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: const Color(0xFF0C4A6E),
              foregroundColor: const Color(0xFF7DD3FC),
              child: const Icon(Icons.dns_rounded),
            ),
            title: const Text('Развернуть Aegis на VPS'),
            subtitle: const Text(
              'SSH-доступ к серверу — приложение всё установит само',
            ),
            onTap: () => Navigator.pop(context, _AddMethod.vps),
          ),
          ListTile(
            leading: CircleAvatar(
              backgroundColor: const Color(0xFF1F4E79),
              foregroundColor: const Color(0xFF93C5FD),
              child: const Icon(Icons.bolt_rounded),
            ),
            title: const Text('AEGIS Native'),
            subtitle: const Text(
              'Свой протокол — укажите сервер и секрет',
            ),
            onTap: () => Navigator.pop(context, _AddMethod.aegisNative),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }
}

class _AddDialog extends StatefulWidget {
  const _AddDialog({this.initialInput});

  /// Text scanned from a QR code, pre-filled so the user can review it
  /// before adding the subscription.
  final String? initialInput;

  @override
  State<_AddDialog> createState() => _AddDialogState();
}

class _AddDialogState extends State<_AddDialog> {
  late final _input = TextEditingController(text: widget.initialInput ?? '');
  final _name = TextEditingController();
  final _host = TextEditingController();
  final _port = TextEditingController(text: '443');
  final _auth = TextEditingController();
  final _params = TextEditingController();
  String? _error;
  bool _busy = false;
  bool _aegisOpen = false;

  String _preset = 'turbo';
  bool _cdn = false;

  /// Presets that can traverse a CDN (Cloudflare only proxies HTTP-family
  /// transports — UDP and REALITY camouflage cannot pass through it).
  static const _cdnPresets = {'cfws', 'cfgrpc'};
  static const _presetPorts = {
    'turbo': '443',
    'eco': '8443',
    'cfws': '443',
    'cfgrpc': '443',
  };

  @override
  void initState() {
    super.initState();
    _detectPresetFromInput();
    _input.addListener(_detectPresetFromInput);
  }

  @override
  void dispose() {
    _input.dispose();
    _name.dispose();
    _host.dispose();
    _port.dispose();
    _auth.dispose();
    _params.dispose();
    super.dispose();
  }

  /// If the pasted text is an `aegis://` link, preselect its preset and the
  /// CDN flag so the advanced section reflects what the link actually is.
  void _detectPresetFromInput() {
    final m = RegExp(r'aegis://([a-z0-9]+)\.').firstMatch(_input.text.trim());
    if (m == null) return;
    final id = m.group(1)!;
    if (!aegisPresets.containsKey(id)) return;
    final cdn = _cdnPresets.contains(id);
    if (id == _preset && cdn == _cdn) return;
    setState(() {
      _preset = id;
      _cdn = cdn;
      _port.text = _presetPorts[id] ?? '443';
    });
  }

  void _selectPreset(String id) {
    setState(() {
      _preset = id;
      _port.text = _presetPorts[id] ?? '443';
    });
  }

  void _toggleCdn(bool value) {
    setState(() {
      _cdn = value;
      if (_cdn && !_cdnPresets.contains(_preset)) _preset = 'cfws';
    });
  }

  /// Builds the `aegis://` share link from the manual-node fields.
  String? _buildAegisLink() {
    final host = _host.text.trim();
    final auth = _auth.text.trim();
    if (host.isEmpty || auth.isEmpty) return null;
    final port = int.tryParse(_port.text.trim()) ?? 443;
    final q = _params.text.trim();
    final query = q.isEmpty ? '' : '?$q';
    final frag = Uri.encodeComponent(_name.text.trim().isEmpty
        ? aegisPresets[_preset]?.label ?? _preset
        : _name.text.trim());
    return 'aegis://$_preset.${Uri.encodeComponent(auth)}'
        '@$host:$port$query#$frag';
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null) setState(() => _input.text = data!.text!.trim());
  }

  Future<void> _submit() async {
    String input = _input.text;
    if (_aegisOpen && (_host.text.trim().isNotEmpty || _auth.text.trim().isNotEmpty)) {
      final link = _buildAegisLink();
      if (link == null) {
        setState(() => _error = 'Укажите хост и ключ/пароль ноды');
        return;
      }
      input = link;
    }
    if (input.trim().isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await AppScope.read(context).addProfile(
        input,
        name: _name.text.trim().isEmpty ? null : _name.text.trim(),
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _showPresetHelp() {
    showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Типы подключения'),
        content: const SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _HelpItem(
                title: 'AEGIS · TCP',
                body: 'Надёжный TCP-транспорт с шифрованием ChaCha20-Poly1305. '
                    'Хороший баланс скорости и стабильности. Работает напрямую '
                    'на сервер, без CDN. Подходит для большинства задач.',
              ),
              _HelpItem(
                title: 'AEGIS · UDP',
                body: 'Быстрый UDP-транспорт для максимальной скорости. '
                    'Идеален для стриминга, игр и больших файлов. '
                    'Работает напрямую на сервер, без CDN.',
              ),
              _HelpItem(
                title: 'FEC (Forward Error Correction)',
                body: 'Защита от потери пакетов в UDP. Добавляет лишние '
                    '«паритетные» пакеты — если один потерялся, данные '
                    'восстанавливаются без повторной отправки. Увеличивает '
                    'трафик на ~20%, но повышает стабильность на плохих '
                    'сетях. Рекомендуется для мобильного интернета.',
              ),
              _HelpItem(
                title: 'AEGIS · WebSocket (WS)',
                body: 'Транспорт через WebSocket — работает через Cloudflare '
                    'CDN и другие прокси. Медленнее TCP/UDP, но пробивается '
                    'там, где прямые протоколы заблокированы. Требует домен '
                    'за Cloudflare (оранжевое облако).',
              ),
              _HelpItem(
                title: 'AEGIS · gRPC',
                body: 'Транспорт через gRPC — альтернатива WebSocket для '
                    'Cloudflare. Чуть стабильнее на нестабильных сетях. '
                    'Также требует домен за Cloudflare.',
              ),
              SizedBox(height: 8),
              Text(
                '💡 Совет: для большинства пользователей TCP — оптимальный '
                'выбор. UDP + FEC — для максимальной скорости. WebSocket/gRPC '
                '— только если TCP/UDP заблокированы провайдером.',
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
              ),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Понятно'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.add_link_rounded, color: scheme.primary, size: 32),
      title: const Text('Новая подписка'),
      content: SizedBox(
        width: 520,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: _input,
                autofocus: true,
                minLines: 3,
                maxLines: 6,
                decoration: InputDecoration(
                  hintText:
                      'https://… или aegis://…, по одной ссылке на строку',
                  suffixIcon: IconButton(
                    tooltip: 'Вставить',
                    onPressed: _paste,
                    icon: const Icon(Icons.content_paste_rounded),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Theme(
                data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
                child: ExpansionTile(
                  initiallyExpanded: _aegisOpen,
                  onExpansionChanged: (v) => setState(() => _aegisOpen = v),
                  tilePadding: EdgeInsets.zero,
                  childrenPadding: const EdgeInsets.only(bottom: 8),
                  leading: Icon(
                    Icons.bolt_rounded,
                    color: scheme.primary,
                    size: 20,
                  ),
                  title: const Text(
                    'Aegis-нода вручную',
                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
                  ),
                  subtitle: const Text(
                    'Для энтузиастов — необязательно для обычных нужд',
                    style: TextStyle(fontSize: 12),
                  ),
                  children: [
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Wrap(
                        spacing: 8,
                        runSpacing: 4,
                        children: [
                          for (final e in aegisPresets.entries)
                            Tooltip(
                              message: _cdn && !_cdnPresets.contains(e.key)
                                  ? 'Недоступен через CDN — Cloudflare '
                                      'не пропускает этот транспорт'
                                  : e.value.description,
                              child: ChoiceChip(
                                label: Text(e.value.label),
                                selected: _preset == e.key,
                                onSelected: _cdn &&
                                        !_cdnPresets.contains(e.key)
                                    ? null
                                    : (_) => _selectPreset(e.key),
                              ),
                            ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: 'Что означают типы?',
                      onPressed: _showPresetHelp,
                      icon: const Icon(Icons.help_outline_rounded),
                    ),
                    const SizedBox(height: 4),
                    CheckboxListTile(
                  value: _cdn,
                  onChanged: _busy ? null : (v) => _toggleCdn(v ?? false),
                  title: const Text('Через CDN (Cloudflare)'),
                  subtitle: const Text(
                    'Оставляет только WS·CF и gRPC·CF',
                    style: TextStyle(fontSize: 12),
                  ),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Expanded(
                      flex: 3,
                      child: TextField(
                        controller: _host,
                        decoration: const InputDecoration(
                          labelText: 'Хост',
                          hintText: 'vpn.example.com или IP',
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextField(
                        controller: _port,
                        keyboardType: TextInputType.number,
                        decoration: const InputDecoration(labelText: 'Порт'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _auth,
                  decoration: InputDecoration(
                    labelText: _preset == 'turbo'
                        ? 'Пароль ноды'
                        : 'UUID ноды',
                    hintText: _preset == 'turbo'
                        ? 'пароль из панели Aegis'
                        : 'uuid из панели Aegis',
                  ),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: _params,
                  decoration: const InputDecoration(
                    labelText: 'Доп. параметры (необязательно)',
                    hintText: 'sni=…&path=…&pbk=…&sid=…',
                  ),
                ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Название подписки',
                  hintText: 'Например: Aegis · Germany Turbo',
                ),
              ),
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                child: _error == null
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          _error!,
                          style: TextStyle(color: scheme.error),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Добавить'),
          ),
        ),
      ],
    );
  }
}

class _HelpItem extends StatelessWidget {
  const _HelpItem({required this.title, required this.body});

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: Theme.of(context).textTheme.titleSmall?.copyWith(
                  color: scheme.primary,
                  fontWeight: FontWeight.w700,
                ),
          ),
          const SizedBox(height: 2),
          Text(body, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}

/// Dialog for adding AEGIS native profile (custom protocol).
Future<void> _showAegisNativeDialog(BuildContext context) async {
  await showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'aegis-native',
    transitionDuration: const Duration(milliseconds: 420),
    pageBuilder: (context, _, _) => const _AegisNativeDialog(),
    transitionBuilder: (context, anim, _, child) {
      final curve = CurvedAnimation(
        parent: anim,
        curve: Curves.easeOutBack,
        reverseCurve: Curves.easeInCubic,
      );
      return FadeTransition(
        opacity: anim,
        child: ScaleTransition(
          scale: Tween(begin: 0.85, end: 1.0).animate(curve),
          child: child,
        ),
      );
    },
  );
}

class _AegisNativeDialog extends StatefulWidget {
  const _AegisNativeDialog();

  @override
  State<_AegisNativeDialog> createState() => _AegisNativeDialogState();
}

class _AegisNativeDialogState extends State<_AegisNativeDialog> {
  final _name = TextEditingController();
  final _server = TextEditingController();
  final _port = TextEditingController(text: '8443');
  final _secret = TextEditingController();
  final _listenPort = TextEditingController(text: '1080');
  String? _error;
  bool _busy = false;
  String _transport = 'tcp';
  bool _fec = false;

  @override
  void dispose() {
    _name.dispose();
    _server.dispose();
    _port.dispose();
    _secret.dispose();
    _listenPort.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final server = _server.text.trim();
    final secret = _secret.text.trim();
    final port = int.tryParse(_port.text.trim()) ?? 8443;
    final listenPort = int.tryParse(_listenPort.text.trim()) ?? 1080;
    final name = _name.text.trim().isEmpty ? 'AEGIS Native' : _name.text.trim();

    if (server.isEmpty || secret.isEmpty) {
      setState(() => _error = 'Укажите сервер и секрет');
      return;
    }

    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      await AppScope.read(context).addAegisProfile(
        name: name,
        server: server,
        port: port,
        secret: secret,
        listenPort: listenPort,
        transport: _transport,
        fec: _fec,
      );
      if (mounted) Navigator.pop(context);
    } catch (e) {
      setState(() => _error = e.toString().replaceFirst('Exception: ', ''));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(Icons.bolt_rounded, color: scheme.primary, size: 32),
      title: const Text('AEGIS Native'),
      content: SizedBox(
        width: 480,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Свой протокол AEGIS — зашифрованный туннель с обфускацией. '
                'Требуется AEGIS-сервер (демон на VPS).',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: _name,
                decoration: const InputDecoration(
                  labelText: 'Название',
                  hintText: 'Мой AEGIS сервер',
                ),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    flex: 3,
                    child: TextField(
                      controller: _server,
                      decoration: const InputDecoration(
                        labelText: 'Сервер',
                        hintText: '1.2.3.4 или vpn.example.com',
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: TextField(
                      controller: _port,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Порт'),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _secret,
                obscureText: true,
                decoration: const InputDecoration(
                  labelText: 'Секрет',
                  hintText: 'Пароль/ключ от AEGIS-сервера',
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _listenPort,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(
                  labelText: 'Локальный порт',
                  hintText: '1080 (SOCKS5 для mihomo)',
                ),
              ),
              const SizedBox(height: 12),
              // Transport selection
              Text(
                'Транспорт:',
                style: Theme.of(context).textTheme.labelMedium?.copyWith(
                      color: scheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 6),
              SegmentedButton<String>(
                segments: const [
                  ButtonSegment(value: 'tcp', label: Text('TCP')),
                  ButtonSegment(value: 'udp', label: Text('UDP')),
                  ButtonSegment(value: 'ws', label: Text('WS')),
                ],
                selected: {_transport},
                onSelectionChanged: _busy
                    ? null
                    : (s) => setState(() => _transport = s.first),
              ),
              if (_transport == 'udp') ...[
                const SizedBox(height: 6),
                CheckboxListTile(
                  title: const Text('FEC (Forward Error Correction)'),
                  subtitle: const Text('Защита от потери пакетов'),
                  value: _fec,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _fec = v ?? false),
                  controlAffinity: ListTileControlAffinity.leading,
                  contentPadding: EdgeInsets.zero,
                ),
              ],
              AnimatedSize(
                duration: const Duration(milliseconds: 250),
                child: _error == null
                    ? const SizedBox(width: double.infinity)
                    : Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Text(
                          _error!,
                          style: TextStyle(color: scheme.error),
                        ),
                      ),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Отмена'),
        ),
        FilledButton(
          onPressed: _busy ? null : _submit,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            child: _busy
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Добавить'),
          ),
        ),
      ],
    );
  }
}
