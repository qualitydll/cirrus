import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter/services.dart' show rootBundle;

/// Credentials for deploying AEGIS onto a remote VPS over SSH.
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
    required this.server,
    required this.port,
    required this.secret,
    required this.log,
  });

  final String server;
  final int port;
  final String secret;
  final String log;
}

/// Uploads the AEGIS installer to [creds] over SSH/SFTP, runs it and
/// returns the server connection details.
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
      disableHostkeyVerification: true,
    );

    both('→ uploading installer …');
    final sftp = await client.sftp();
    try {
      await sftp.mkdir('/tmp/aegis_deploy');
    } catch (_) {/* already exists */}
    
    // Upload new installer
    final bytes = await rootBundle.load('aegis-install.sh');
    final file = await sftp.open(
      '/tmp/aegis_deploy/aegis-install.sh',
      mode: SftpFileOpenMode.create |
          SftpFileOpenMode.truncate |
          SftpFileOpenMode.write,
    );
    await file.writeBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    await file.close();
    
    final chmod = await client.runWithResult(
      'chmod +x /tmp/aegis_deploy/aegis-install.sh',
    );
    if ((chmod.exitCode ?? -1) != 0) {
      throw Exception('chmod failed: ${utf8.decode(chmod.stderr)}');
    }

    both('→ running installer (this can take a few minutes) …');
    final result = await client
        .runWithResult('bash /tmp/aegis_deploy/aegis-install.sh 2>&1')
        .timeout(timeout);
    final out = utf8.decode(result.stdout, allowMalformed: true);
    for (final line in out.split('\n')) {
      if (line.trim().isNotEmpty) both('  $line');
    }
    if ((result.exitCode ?? -1) != 0) {
      throw Exception('Установка завершилась с ошибкой (код ${result.exitCode})');
    }

    // Extract connection details from output
    final serverMatch = RegExp(r'Server:\s*(\S+):(\d+)').firstMatch(out);
    final secretMatch = RegExp(r'Secret:\s*(\S+)').firstMatch(out);
    
    if (serverMatch == null || secretMatch == null) {
      throw Exception('Не удалось извлечь данные подключения из вывода установщика');
    }
    
    final server = serverMatch.group(1)!;
    final port = int.tryParse(serverMatch.group(2)!) ?? 8443;
    final secret = secretMatch.group(1)!;

    return VpsDeployResult(
      server: server,
      port: port,
      secret: secret,
      log: buf.toString(),
    );
  } on TimeoutException {
    throw Exception('Таймаут — установка заняла слишком много времени');
  } on SSHAuthFailError {
    throw Exception(
      'SSH: сервер отклонил логин/пароль. Проверь credentials или '
      'используй приватный ключ (на сервере может быть выключен '
      'PasswordAuthentication).',
    );
  } catch (e) {
    if (e is Exception) rethrow;
    throw Exception('Ошибка подключения: $e');
  } finally {
    client?.close();
  }
}
