import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/vps_deploy.dart';
import '../../state/app_state.dart';

/// Shows the "deploy Aegis to my VPS" dialog. On success the subscription
/// URL can be imported into profiles with one tap.
Future<void> showAegisDeployDialog(BuildContext context) {
  return showGeneralDialog(
    context: context,
    barrierDismissible: true,
    barrierLabel: 'aegis-deploy',
    transitionDuration: const Duration(milliseconds: 420),
    pageBuilder: (context, _, _) => const _DeployDialog(),
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

class _DeployDialog extends StatefulWidget {
  const _DeployDialog();

  @override
  State<_DeployDialog> createState() => _DeployDialogState();
}

class _DeployDialogState extends State<_DeployDialog> {
  final _host = TextEditingController();
  final _sshPort = TextEditingController(text: '22');
  final _user = TextEditingController(text: 'root');
  final _password = TextEditingController();
  final _key = TextEditingController();
  final _keyPass = TextEditingController();
  bool _useKey = false;
  bool _busy = false;
  bool _done = false;
  String? _error;
  String _log = '';
  VpsDeployResult? _result;
  String _transport = 'tcp'; // 'tcp' or 'udp'
  bool _fec = false;

  Future<void> _deploy() async {
    final host = _host.text.trim();
    if (host.isEmpty) {
      setState(() => _error = 'Укажите адрес сервера');
      return;
    }
    if (!_useKey && _password.text.isEmpty) {
      setState(() => _error = 'Укажите пароль или выберите ключ');
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _log = '';
      _done = false;
      _result = null;
    });
    try {
      final result = await deployAegis(
        VpsCredentials(
          host: host,
          port: int.tryParse(_sshPort.text.trim()) ?? 22,
          username: _user.text.trim().isEmpty ? 'root' : _user.text.trim(),
          password: _useKey ? null : _password.text,
          privateKey: _useKey ? _key.text : null,
          keyPassphrase: _keyPass.text,
        ),
        transport: _transport,
        fec: _fec,
        onLog: (line) {
          if (!mounted) return;
          setState(() => _log = '$_log$line\n');
        },
      );
      if (!mounted) return;
      setState(() {
        _result = result;
        _done = true;
        _busy = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString().replaceFirst('Exception: ', '');
        _busy = false;
      });
    }
  }

  Future<void> _import() async {
    final result = _result;
    if (result == null) return;
    
    // Add AEGIS native profile instead of subscription URL
    await AppScope.read(context).addAegisProfile(
      name: 'Aegis ${_transport.toUpperCase()}${_fec ? ' + FEC' : ''} · ${_host.text.trim()}',
      server: result.server,
      port: result.port,
      secret: result.secret,
      listenPort: 1080,
      transport: _transport,
      fec: _fec,
    );
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      icon: Icon(
        _done ? Icons.verified_rounded : Icons.dns_rounded,
        color: scheme.primary,
        size: 32,
      ),
      title: Text(_done ? 'Aegis развёрнут' : 'Развернуть Aegis на VPS'),
      content: SizedBox(
        width: 520,
        child: _done ? _buildResult(scheme) : _buildForm(scheme),
      ),
      actions: _done
          ? [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Закрыть'),
              ),
              FilledButton.icon(
                onPressed: _import,
                icon: const Icon(Icons.download_rounded),
                label: const Text('Добавить подписку'),
              ),
            ]
          : [
              TextButton(
                onPressed: _busy ? null : () => Navigator.pop(context),
                child: const Text('Отмена'),
              ),
              FilledButton(
                onPressed: _busy ? null : _deploy,
                child: _busy
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('Развернуть'),
              ),
            ],
    );
  }

  Widget _buildForm(ColorScheme scheme) {
    return SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Приложение само залогинится по SSH и установит AEGIS демон '
            'на ваш сервер.',
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: scheme.onSurfaceVariant,
                ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _host,
            decoration: const InputDecoration(
              labelText: 'IP или домен сервера',
              hintText: '203.0.113.10',
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                flex: 2,
                child: TextField(
                  controller: _user,
                  decoration: const InputDecoration(labelText: 'SSH user'),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: TextField(
                  controller: _sshPort,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: 'SSH порт'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('Пароль')),
              ButtonSegment(value: true, label: Text('Ключ')),
            ],
            selected: {_useKey},
            onSelectionChanged: _busy
                ? null
                : (s) => setState(() => _useKey = s.first),
          ),
          const SizedBox(height: 10),
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
              ButtonSegment(value: 'udp', label: Text('UDP + FEC')),
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
          const SizedBox(height: 10),
          if (_useKey) ...[
            TextField(
              controller: _key,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: 'Приватный ключ (PEM)',
                hintText: '-----BEGIN OPENSSH PRIVATE KEY-----',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _keyPass,
              obscureText: true,
              decoration: const InputDecoration(
                labelText: 'Пароль ключа (если есть)',
              ),
            ),
          ] else
            TextField(
              controller: _password,
              obscureText: true,
              decoration: const InputDecoration(labelText: 'SSH пароль'),
            ),
          if (_log.isNotEmpty) ...[
            const SizedBox(height: 14),
            Container(
              width: double.infinity,
              constraints: const BoxConstraints(maxHeight: 140),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: scheme.surfaceContainerHighest
                    .withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(12),
              ),
              child: SingleChildScrollView(
                child: Text(
                  _log,
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: scheme.onSurfaceVariant,
                      ),
                ),
              ),
            ),
          ],
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(_error!, style: TextStyle(color: scheme.error)),
          ],
        ],
      ),
    );
  }

  Widget _buildResult(ColorScheme scheme) {
    final result = _result!;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'AEGIS сервер развёрнут. Данные для подключения:',
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: scheme.onSurfaceVariant,
              ),
        ),
        const SizedBox(height: 14),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: scheme.surfaceContainerHighest.withValues(alpha: 0.6),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('Сервер: ${result.server}:${result.port}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w600,
                      )),
              const SizedBox(height: 4),
              Text('Секрет: ${result.secret}',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                        fontFamily: 'monospace',
                        color: scheme.onSurfaceVariant,
                      )),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: () {
                  Clipboard.setData(
                    ClipboardData(text: '${result.server}:${result.port}'),
                  );
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Адрес скопирован')),
                  );
                },
                icon: const Icon(Icons.copy_rounded),
                label: const Text('Копировать адрес'),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: FilledButton.icon(
                onPressed: _import,
                icon: const Icon(Icons.add_rounded),
                label: const Text('Добавить профиль'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
