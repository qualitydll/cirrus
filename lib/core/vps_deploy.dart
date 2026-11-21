import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:http/http.dart' as http;

/// Credentials for deploying Aegis onto a remote VPS over SSH.
class VpsCredentials {
  const VpsCredentials({
    required this.host,
    this.port = 22,
    this.username = 'root',
    this.password,
    this.privateKey,
    this.keyPassphrase,
  });

  final String host;
  final int port;
  final String username;
  final String? password;
  final String? privateKey;
  final String? keyPassphrase;
}

class VpsDeployResult {
  const VpsDeployResult({
    required this.panelUrl,
    required this.subscriptionUrl,
    required this.log,
  });

  final String panelUrl;
  final String subscriptionUrl;
  final String log;
}

/// Uploads the bundled Aegis installer to [creds] over SSH/SFTP, runs it and
/// returns the panel + subscription URLs printed into /etc/aegis/state.json.
Future<VpsDeployResult> deployAegis(
  VpsCredentials creds, {
  void Function(String line)? onLog,
  Duration timeout = const Duration(minutes: 6),
}) async {
  void log(String s) => onLog?.call(s);
  final buf = StringBuffer();
  void both(String s) {
    buf.writeln(s);
    log(s);
  }

  SSHClient? client;
  final host = creds.host;
  try {
    both('→ connecting to ${creds.username}@$host:${creds.port} …');
    final socket = await SSHSocket.connect(creds.host, creds.port)
        .timeout(const Duration(seconds: 20));
    final identities = <SSHKeyPair>[];
    if (creds.privateKey != null && creds.privateKey!.trim().isNotEmpty) {
      try {
        identities.addAll(
          SSHKeyPair.fromPem(
            creds.privateKey!,
            (creds.keyPassphrase?.isNotEmpty ?? false)
                ? creds.keyPassphrase
                : null,
          ),
        );
      } catch (e) {
        throw Exception('Не удалось прочитать приватный ключ: $e');
      }
    }
    client = SSHClient(
      socket,
      username: creds.username,
      onPasswordRequest: () => creds.password,
      identities: identities.isEmpty ? null : identities,
      // First-connect UX: accept the host key like `ssh` does on first use.
      // TODO: replace with TOFU fingerprint storage for production hardening.
      disableHostkeyVerification: true,
    );

    both('→ uploading installer …');
    final sftp = await client.sftp();
    try {
      await sftp.mkdir('/tmp/aegis_deploy');
    } catch (_) {/* already exists */}
    for (final name in ['install.sh', 'aegis_panel.py']) {
      final bytes = await rootBundle.load('aegis/$name');
      final file = await sftp.open(
        '/tmp/aegis_deploy/$name',
        mode: SftpFileOpenMode.create |
            SftpFileOpenMode.truncate |
            SftpFileOpenMode.write,
      );
      final uploader = await file.write(
        Stream<Uint8List>.value(
          bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
        ),
      );
      await uploader.done;
      await file.close();
    }
    final chmod = await client.runWithResult(
      'chmod +x /tmp/aegis_deploy/install.sh',
    );
    if (chmod.exitCode != 0) {
      throw Exception('chmod failed: ${utf8.decode(chmod.stderr)}');
    }

    both('→ running installer (this can take a few minutes) …');
    final result = await client
        .runWithResult('bash /tmp/aegis_deploy/install.sh 2>&1')
        .timeout(timeout);
    final out = utf8.decode(result.stdout, allowMalformed: true);
    for (final line in out.split('\n')) {
      if (line.trim().isNotEmpty) both('  $line');
    }
    if (result.exitCode != 0) {
      throw Exception('Установка завершилась с ошибкой (код ${result.exitCode})');
    }

    both('→ reading panel credentials …');
    final stateRes = await client.runWithResult('cat /etc/aegis/state.json');
    if (stateRes.exitCode != 0) {
      throw Exception('state.json не найден — установка не завершилась');
    }
    final state = jsonDecode(utf8.decode(stateRes.stdout))
        as Map<String, dynamic>;
    final token = state['token'] as String? ?? '';
    final subToken = state['sub_token'] as String? ?? '';
    if (token.isEmpty || subToken.isEmpty) {
      throw Exception('Панель установлена, но токены не найдены');
    }

    final panelPort = 8901;
    final panelUrl = 'http://$host:$panelPort/?k=$token';
    final subscriptionUrl = 'http://$host:$panelPort/sub/$subToken';

    // If the user connected via a domain (not a raw IP), prefer it for node
    // links so they survive IP changes.
    final isIp = RegExp(r'^\d{1,3}(\.\d{1,3}){3}$').hasMatch(host);
    if (!isIp && token.isNotEmpty) {
      try {
        await http
            .post(
              Uri.parse('http://$host:$panelPort/api/host?k=$token'),
              headers: {'Content-Type': 'application/json'},
              body: jsonEncode({'host': host}),
            )
            .timeout(const Duration(seconds: 10));
      } catch (_) {/* non-fatal */}
    }
    return VpsDeployResult(
      panelUrl: panelUrl,
      subscriptionUrl: subscriptionUrl,
      log: buf.toString(),
    );
  } on TimeoutException {
    throw Exception('Таймаут — установка заняла слишком много времени');
  } catch (e) {
    if (e is Exception) rethrow;
    throw Exception('Ошибка подключения: $e');
  } finally {
    client?.close();
  }
}
