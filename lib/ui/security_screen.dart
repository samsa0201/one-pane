import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../ssh/connection.dart';
import 'fonts.dart';
import 'parts.dart';
import 'theme.dart';

/// Settings › Keys on this phone: the private key of each host that signs in with one (kept in the
/// phone's secure storage); copy its public line, or replace it with a new key.
class KeysScreen extends StatefulWidget {
  const KeysScreen({super.key});
  @override
  State<KeysScreen> createState() => _KeysScreenState();
}

class _KeysScreenState extends State<KeysScreen> {
  final _store = HostStore();
  List<HostConfig>? _hosts;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final hosts = await _store.load();
    for (final h in hosts) {
      await _store.loadSecrets(h);
    }
    if (mounted) setState(() => _hosts = hosts.where((h) => (h.privateKeyPem ?? '').trim().isNotEmpty).toList());
  }

  Future<void> _replace(HostConfig h) async {
    if (!await confirmDanger(context,
        title: 'New key for ${h.name}?',
        body: 'The current key is deleted from this phone. Add the new public line to the server before you '
            'connect, or sign-in fails.',
        action: 'Make new key')) {
      return;
    }
    final (pem, _) = generateKey();
    h.privateKeyPem = pem;
    await _store.save(h);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final hosts = _hosts;
    return Scaffold(
      appBar: AppBar(toolbarHeight: 40),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
        const PageTitle('Keys on this phone'),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
          child: Text('Private keys stay in this phone’s secure storage and are never shown. Copy the public line '
              'into ~/.ssh/authorized_keys on the server.',
              style: TextStyle(fontSize: 14, height: 1.45, color: Tone.muted)),
        ),
        if (hosts == null)
          const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
        else if (hosts.isEmpty)
          Text('No host signs in with a key yet.', style: TextStyle(fontSize: 15, color: Tone.muted))
        else
          for (final h in hosts) ...[
            _keyCard(h),
            const SizedBox(height: 10),
          ],
      ]),
    );
  }

  Widget _keyCard(HostConfig h) {
    final pub = publicLineOf(h.privateKeyPem!);
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Tone.surface, borderRadius: BorderRadius.circular(14)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(Icons.key_rounded, size: 20, color: accent),
          const SizedBox(width: 10),
          Expanded(
              child: Text(h.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Tone.text))),
          if (pub != null)
            Text(pub.split(' ').first.replaceFirst('ssh-', ''),
                style: TextStyle(fontFamily: termFont.value, fontSize: 12, color: Tone.muted)),
        ]),
        const SizedBox(height: 10),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(color: Tone.ground, borderRadius: BorderRadius.circular(10)),
          child: Text(pub ?? 'This key can’t be read (it may need a passphrase).',
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: termFont.value, fontSize: 12, height: 1.5, color: Tone.muted)),
        ),
        const SizedBox(height: 12),
        Wrap(spacing: 8, runSpacing: 8, children: [
          if (pub != null)
            PillButton('Copy public key', icon: Icons.copy_rounded, primary: false, onPressed: () {
              Clipboard.setData(ClipboardData(text: pub));
              ScaffoldMessenger.of(context)
                  .showSnackBar(const SnackBar(content: Text('Public key copied'), duration: Duration(seconds: 2)));
            }),
          TextButton(
            style: TextButton.styleFrom(minimumSize: const Size(0, 52)),
            onPressed: () => _replace(h),
            child: Text('Make a new key', style: TextStyle(color: accent, fontWeight: FontWeight.w600)),
          ),
        ]),
      ]),
    );
  }
}

/// Settings › Known hosts: the server key trusted for each host on first connection.
class KnownHostsScreen extends StatefulWidget {
  const KnownHostsScreen({super.key});
  @override
  State<KnownHostsScreen> createState() => _KnownHostsScreenState();
}

class _KnownHostsScreenState extends State<KnownHostsScreen> {
  final _store = HostStore();
  List<(HostConfig, (String, String)?)>? _rows;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final rows = [for (final h in await _store.load()) (h, await _store.hostKey(h.id))];
    if (mounted) setState(() => _rows = rows);
  }

  Future<void> _forget(HostConfig h) async {
    if (!await confirmDanger(context,
        title: 'Forget the key of ${h.name}?',
        body: 'Next time you connect, One Pane shows the server’s fingerprint and asks again. Do this after the '
            'server’s key was changed on purpose (a reinstall, a new machine).',
        action: 'Forget')) {
      return;
    }
    await _store.forgetHostKey(h.id);
    _load();
  }

  @override
  Widget build(BuildContext context) {
    final rows = _rows;
    return Scaffold(
      appBar: AppBar(toolbarHeight: 40),
      body: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 32), children: [
        const PageTitle('Known hosts'),
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 0, 4, 14),
          child: Text('The server key trusted on first connection. If a server shows a different key later, '
              'One Pane refuses to connect.',
              style: TextStyle(fontSize: 14, height: 1.45, color: Tone.muted)),
        ),
        if (rows == null)
          const Center(child: Padding(padding: EdgeInsets.all(24), child: CircularProgressIndicator()))
        else if (rows.isEmpty)
          Text('No hosts yet.', style: TextStyle(fontSize: 15, color: Tone.muted))
        else
          Group(children: [
            for (final (h, key) in rows)
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
                child: Row(children: [
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(h.name, style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Tone.text)),
                      const SizedBox(height: 4),
                      Text(
                        key == null
                            ? 'Not trusted yet: asked on next connect'
                            : '${key.$1.replaceFirst('ssh-', '').toUpperCase()} · ${key.$2}',
                        style: TextStyle(fontFamily: key == null ? null : termFont.value, fontSize: 12, height: 1.45,
                            color: Tone.muted),
                      ),
                    ]),
                  ),
                  if (key != null)
                    TextButton(
                      style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                      onPressed: () => _forget(h),
                      child: Text('Forget', style: TextStyle(color: Tone.danger, fontWeight: FontWeight.w600)),
                    ),
                ]),
              ),
          ]),
      ]),
    );
  }
}
