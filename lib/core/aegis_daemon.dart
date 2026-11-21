import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;

/// Manages the AEGIS Go daemon process.
/// The daemon runs as a local SOCKS5 proxy that mihomo uses as upstream.
class AegisDaemon {
  Process? _process;
  String? _binaryPath;
  String? _logPath;
  void Function(String line)? onLine;

  bool get isRunning => _process != null;

  /// Returns the path to the AEGIS binary, downloading if necessary.
  /// For now, we expect the binary to be bundled or manually placed.
  /// TODO: Implement auto-download from GitHub releases.
  static Future<String?> locate({required String dataDir}) async {
    final binaryName = Platform.isWindows ? 'aegis.exe' : 'aegis';
    final candidates = <String>[
      // Check data directory first
      p.join(dataDir, 'aegis', binaryName),
      // Check bundled location
      p.join(p.dirname(Platform.resolvedExecutable), 'aegis', binaryName),
      // Check PATH
      binaryName,
    ];

    for (final c in candidates) {
      if (await File(c).exists()) return c;
    }

    // Try which/where
    try {
      final res = await Process.run(Platform.isWindows ? 'where' : 'which', [
        'aegis',
      ]);
      if (res.exitCode == 0) {
        final first = (res.stdout as String)
            .split(RegExp(r'[\r\n]+'))
            .first
            .trim();
        if (first.isNotEmpty) return first;
      }
    } catch (_) {}

    return null;
  }

  /// Starts the AEGIS daemon.
  /// Returns true if started successfully.
  Future<bool> start({
    required String binaryPath,
    required String serverAddr,
    required String secret,
    int listenPort = 1080,
    String transport = 'tcp',
    bool fec = false,
    required String dataDir,
  }) async {
    await stop();

    _binaryPath = binaryPath;
    _logPath = p.join(dataDir, 'aegis.log');

    try {
      final logFile = File(_logPath!);
      final sink = logFile.openWrite(mode: FileMode.write);

      // Build command arguments
      final args = <String>[
        'client',
        '-server', serverAddr,
        '-secret', secret,
        '-listen', '127.0.0.1:$listenPort',
        '-transport', transport,
      ];
      if (fec && transport == 'udp') {
        args.add('-fec');
      }

      final proc = await Process.start(binaryPath, args, workingDirectory: dataDir);

      _process = proc;

      proc.stdout
          .transform(LineSplitter())
          .listen((line) {
            sink.writeln(line);
            onLine?.call(line);
          });

      proc.stderr
          .transform(LineSplitter())
          .listen((line) {
            sink.writeln('ERROR: $line');
            onLine?.call('ERROR: $line');
          });

      proc.exitCode.then((code) {
        sink.close();
        if (_process == proc) {
          _process = null;
          onLine?.call('AEGIS daemon exited with code $code');
        }
      });

      // Wait a bit for the daemon to start listening
      await Future.delayed(const Duration(milliseconds: 500));

      // Check if process is still running
      if (_process == null) {
        return false;
      }

      return true;
    } catch (e) {
      onLine?.call('Failed to start AEGIS daemon: $e');
      return false;
    }
  }

  /// Stops the AEGIS daemon.
  Future<void> stop() async {
    final proc = _process;
    if (proc == null) return;

    try {
      proc.kill();
      await proc.exitCode.timeout(const Duration(seconds: 3));
    } catch (_) {
      // Force kill if timeout
      try {
        proc.kill(ProcessSignal.sigkill);
      } catch (_) {}
    }

    _process = null;
  }
}
