import 'dart:async';
import 'dart:convert';

import 'package:dartssh2/dartssh2.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../tmux/control.dart';

class HostConfig {
  String id, name, host;
  int port;
  String user;
  String? password; // secret: never in toJson
  String? privateKeyPem; // secret: never in toJson
  String tmuxCmd;
  String session;

  HostConfig({
    required this.id,
    required this.name,
    required this.host,
    this.port = 22,
    required this.user,
    this.password,
    this.privateKeyPem,
    this.tmuxCmd = 'tmux',
    this.session = 'main',
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'host': host,
        'port': port,
        'user': user,
        'tmuxCmd': tmuxCmd,
        'session': session,
      };

  factory HostConfig.fromJson(Map<String, dynamic> j) => HostConfig(
        id: j['id'] as String,
        name: j['name'] as String,
        host: j['host'] as String,
        port: j['port'] as int? ?? 22,
        user: j['user'] as String,
        tmuxCmd: j['tmuxCmd'] as String? ?? 'tmux',
        session: j['session'] as String? ?? 'main',
      );
}

/// Host configs in shared_preferences, secrets in flutter_secure_storage keyed by host id.
class HostStore {
  static const _key = 'hosts';
  final _secure = const FlutterSecureStorage();

  Future<List<HostConfig>> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    return [for (final j in jsonDecode(raw) as List) HostConfig.fromJson(j as Map<String, dynamic>)];
  }

  /// Fills password / privateKeyPem from secure storage.
  Future<void> loadSecrets(HostConfig h) async {
    h.password = await _secure.read(key: 'pw:${h.id}');
    h.privateKeyPem = await _secure.read(key: 'key:${h.id}');
  }

  Future<void> save(HostConfig h) async {
    final hosts = await load();
    final i = hosts.indexWhere((x) => x.id == h.id);
    if (i >= 0) {
      hosts[i] = h;
    } else {
      hosts.add(h);
    }
    await _write(hosts);
    await _writeSecret('pw:${h.id}', h.password);
    await _writeSecret('key:${h.id}', h.privateKeyPem);
  }

  Future<void> delete(String id) async {
    await _write((await load()).where((h) => h.id != id).toList());
    await _secure.delete(key: 'pw:$id');
    await _secure.delete(key: 'key:$id');
    (await SharedPreferences.getInstance()).remove('hostkey:$id');
  }

  Future<void> _write(List<HostConfig> hosts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode([for (final h in hosts) h.toJson()]));
  }

  Future<void> _writeSecret(String key, String? value) => value == null || value.isEmpty
      ? _secure.delete(key: key)
      : _secure.write(key: key, value: value);
}

String shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// Connects over SSH and attaches tmux in control mode (no PTY).
/// Host key: trust on first use, stored per host id; a changed key is rejected.
Future<(SSHClient, TmuxClient)> connectTmux(HostConfig h) async {
  final prefs = await SharedPreferences.getInstance();
  final socket = await SSHSocket.connect(h.host, h.port, timeout: const Duration(seconds: 10));
  final pem = h.privateKeyPem;
  String? keyError;
  final ssh = SSHClient(
    socket,
    username: h.user,
    onPasswordRequest: () => h.password,
    identities: pem == null || pem.trim().isEmpty ? null : SSHKeyPair.fromPem(pem),
    onVerifyHostKey: (type, fingerprint) {
      final fp = '$type ${base64.encode(fingerprint)}';
      final known = prefs.getString('hostkey:${h.id}');
      if (known == null) {
        prefs.setString('hostkey:${h.id}', fp);
        return true;
      }
      if (known != fp) keyError = 'Host key changed for ${h.host} (expected $known, got $fp)';
      return known == fp;
    },
  );
  try {
    await ssh.authenticated;
    final session = await ssh.execute('${h.tmuxCmd} -C new-session -A -s ${shellQuote(h.session)}');
    final stderr = StringBuffer();
    session.stderr.listen((b) => stderr.write(utf8.decode(b, allowMalformed: true)));
    final tmux = TmuxClient(session.stdout, (data) => session.stdin.add(utf8.encode(data)));
    // If tmux exits before answering (e.g. "tmux: command not found"), surface its stderr.
    final exited = session.done.then<List<String>>((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 100)); // let stderr drain
      throw Exception('tmux exited (code ${session.exitCode}): ${stderr.toString().trim()}');
    });
    await Future.any([tmux.cmd('refresh-client -f ignore-size'), exited])
        .timeout(const Duration(seconds: 15));
    return (ssh, tmux);
  } catch (e) {
    ssh.close();
    if (keyError != null) throw Exception(keyError);
    rethrow;
  }
}
