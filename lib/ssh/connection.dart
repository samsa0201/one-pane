import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dartssh2/dartssh2.dart';
import 'package:pinenacl/ed25519.dart' show SigningKey, ByteListExtension;
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../quick_access.dart';
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
    final prefs = await SharedPreferences.getInstance();
    prefs.remove('hostkey:$id');
    prefs.remove('place:$id');
  }

  Future<void> _write(List<HostConfig> hosts) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode([for (final h in hosts) h.toJson()]));
    QuickAccess.refresh();
  }

  /// Where the user was on host [id]: (session, pane id).
  Future<(String, int)?> lastPlace(String id) async {
    final v = (await SharedPreferences.getInstance()).getString('place:$id')?.split('\t');
    if (v case [final s, final p] when int.tryParse(p) != null) return (s, int.parse(p));
    return null;
  }

  Future<void> setPlace(String id, String session, int pane) async {
    await (await SharedPreferences.getInstance()).setString('place:$id', '$session\t$pane');
    QuickAccess.refresh();
  }

  /// Host whose pane screen was open when the app last went away (reopened on start); null after the
  /// user left it.
  Future<String?> openHost() async => (await SharedPreferences.getInstance()).getString('openHost');

  Future<void> setOpenHost(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    id == null ? await prefs.remove('openHost') : await prefs.setString('openHost', id);
    if (id != null) await prefs.setString('lastHost', id);
  }

  /// The host key trusted for host [id]: (type, `SHA256:…` fingerprint), or null if none yet.
  Future<(String, String)?> hostKey(String id) async {
    final v = (await SharedPreferences.getInstance()).getString('hostkey:$id')?.split(' ');
    if (v == null || v.length != 2) return null;
    try {
      return (v[0], utf8.decode(base64.decode(v[1])));
    } catch (_) {
      return (v[0], v[1]);
    }
  }

  /// Forget the trusted host key: the next connection shows the fingerprint and asks again.
  Future<void> forgetHostKey(String id) async => (await SharedPreferences.getInstance()).remove('hostkey:$id');

  /// The host opened most recently (the "Continue" card).
  Future<String?> lastHost() async => (await SharedPreferences.getInstance()).getString('lastHost');

  Future<void> _writeSecret(String key, String? value) => value == null || value.isEmpty
      ? _secure.delete(key: key)
      : _secure.write(key: key, value: value);
}

/// The server's key was refused (not trusted, or changed): retrying will not help.
class HostKeyError implements Exception {
  final String message;
  HostKeyError(this.message);
  @override
  String toString() => message;
}

String shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// Connects over SSH and attaches tmux in control mode (no PTY): to [session] if it still exists
/// (where the user was), else the host's own session (created if missing).
/// Host key: trust on first use, stored per host id; a changed key is rejected.
/// [trust]: asked about a host key seen for the first time (type, SHA256 fingerprint); null: refused.
Future<(SSHClient, TmuxClient)> connectTmux(HostConfig h,
    {String? session, Future<bool> Function(String type, String fingerprint)? trust}) async {
  final prefs = await SharedPreferences.getInstance();
  final socket = await SSHSocket.connect(h.host, h.port, timeout: const Duration(seconds: 10));
  final pem = h.privateKeyPem;
  String? keyError;
  final ssh = SSHClient(
    socket,
    username: h.user,
    onPasswordRequest: () => h.password,
    identities: pem == null || pem.trim().isEmpty ? null : SSHKeyPair.fromPem(pem),
    onVerifyHostKey: (type, fingerprint) async {
      final fp = '$type ${base64.encode(fingerprint)}';
      final known = prefs.getString('hostkey:${h.id}');
      if (known == null) {
        final ok = trust != null && await trust(type, utf8.decode(fingerprint, allowMalformed: true));
        if (ok) await prefs.setString('hostkey:${h.id}', fp);
        if (!ok) keyError = 'Host key not trusted';
        return ok;
      }
      if (known != fp) keyError = 'Host key changed for ${h.host} (expected $known, got $fp)';
      return known == fp;
    },
  );
  try {
    await ssh.authenticated;
    final home = '${h.tmuxCmd} -C new-session -A -s ${shellQuote(h.session)}';
    final exec = await ssh.execute(session == null || session == h.session
        ? home
        : 'if ${h.tmuxCmd} has-session -t ${shellQuote('=$session')} 2>/dev/null; '
            'then exec ${h.tmuxCmd} -C attach-session -t ${shellQuote('=$session')}; else exec $home; fi');
    final stderr = StringBuffer();
    exec.stderr.listen((b) => stderr.write(utf8.decode(b, allowMalformed: true)));
    final tmux = TmuxClient(exec.stdout, (data) => exec.stdin.add(utf8.encode(data)));
    // If tmux exits before answering (e.g. "tmux: command not found"), surface its stderr.
    final exited = exec.done.then<List<String>>((_) async {
      await Future<void>.delayed(const Duration(milliseconds: 100)); // let stderr drain
      throw Exception('tmux exited (code ${exec.exitCode}): ${stderr.toString().trim()}');
    });
    // Probe only; the client size policy (ignore-size or -C) is the pane screen's (phone/desk mode).
    await Future.any([tmux.cmd("display -p '#{version}'"), exited])
        .timeout(const Duration(seconds: 15));
    return (ssh, tmux);
  } catch (e) {
    ssh.close();
    if (keyError != null) throw HostKeyError(keyError!);
    rethrow;
  }
}

/// A new Ed25519 key made on this phone: (private key PEM, public `authorized_keys` line).
(String, String) generateKey() {
  final sk = SigningKey.generate();
  final kp = OpenSSHEd25519KeyPair(
      Uint8List.fromList(sk.verifyKey.asTypedList), Uint8List.fromList(sk.asTypedList), 'onepane');
  return (kp.toPem(), publicLine(kp));
}

/// The `authorized_keys` line for [kp].
String publicLine(SSHKeyPair kp) => '${kp.type} ${base64.encode(kp.toPublicKey().encode())} onepane';

/// Public line of a private key PEM, or null if it does not parse (or needs a passphrase).
String? publicLineOf(String pem) {
  try {
    return publicLine(SSHKeyPair.fromPem(pem).first);
  } catch (_) {
    return null;
  }
}
