import 'package:flutter/material.dart';

import '../ssh/connection.dart';
import 'pane_screen.dart';

class HostsScreen extends StatefulWidget {
  const HostsScreen({super.key});
  @override
  State<HostsScreen> createState() => _HostsScreenState();
}

class _HostsScreenState extends State<HostsScreen> {
  final _store = HostStore();
  List<HostConfig> _hosts = [];
  String? _connecting; // host id

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final hosts = await _store.load();
    if (mounted) setState(() => _hosts = hosts);
  }

  Future<void> _edit([HostConfig? h]) async {
    if (h != null) await _store.loadSecrets(h);
    if (!mounted) return;
    final saved = await Navigator.push<HostConfig>(
      context,
      MaterialPageRoute(builder: (_) => HostForm(host: h)),
    );
    if (saved == null) return;
    await _store.save(saved);
    _load();
  }

  Future<void> _delete(HostConfig h) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete ${h.name}?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Delete')),
        ],
      ),
    );
    if (ok != true) return;
    await _store.delete(h.id);
    _load();
  }

  Future<void> _connect(HostConfig h) async {
    if (_connecting != null) return;
    setState(() => _connecting = h.id);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _store.loadSecrets(h);
      final (ssh, tmux) = await connectTmux(h);
      if (!mounted) {
        ssh.close();
        return;
      }
      await Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => PaneScreen(ssh: ssh, client: tmux, session: h.session)),
      );
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Connect failed: $e')));
    } finally {
      if (mounted) setState(() => _connecting = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('tmux pocket')),
      floatingActionButton: FloatingActionButton(onPressed: _edit, child: const Icon(Icons.add)),
      body: _hosts.isEmpty
          ? const Center(child: Text('No hosts yet. Tap + to add one.'))
          : ListView(children: [
              for (final h in _hosts)
                ListTile(
                  leading: _connecting == h.id
                      ? const SizedBox(width: 24, height: 24, child: CircularProgressIndicator(strokeWidth: 2))
                      : const Icon(Icons.terminal),
                  title: Text(h.name),
                  subtitle: Text('${h.user}@${h.host}:${h.port} · ${h.session}'),
                  onTap: () => _connect(h),
                  trailing: PopupMenuButton<String>(
                    onSelected: (v) => v == 'edit' ? _edit(h) : _delete(h),
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'edit', child: Text('Edit')),
                      PopupMenuItem(value: 'delete', child: Text('Delete')),
                    ],
                  ),
                ),
            ]),
    );
  }
}

class HostForm extends StatefulWidget {
  final HostConfig? host;
  const HostForm({super.key, this.host});
  @override
  State<HostForm> createState() => _HostFormState();
}

class _HostFormState extends State<HostForm> {
  final _form = GlobalKey<FormState>();
  late final HostConfig? h = widget.host;
  late final _name = TextEditingController(text: h?.name);
  late final _host = TextEditingController(text: h?.host);
  late final _port = TextEditingController(text: '${h?.port ?? 22}');
  late final _user = TextEditingController(text: h?.user);
  late final _password = TextEditingController(text: h?.password);
  late final _key = TextEditingController(text: h?.privateKeyPem);
  late final _tmux = TextEditingController(text: h?.tmuxCmd ?? 'tmux');
  late final _session = TextEditingController(text: h?.session ?? 'main');

  String? _required(String? v) => v == null || v.trim().isEmpty ? 'Required' : null;

  void _save() {
    if (!_form.currentState!.validate()) return;
    String? opt(TextEditingController c) => c.text.isEmpty ? null : c.text;
    Navigator.pop(
      context,
      HostConfig(
        id: h?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        name: _name.text.trim().isEmpty ? _host.text.trim() : _name.text.trim(),
        host: _host.text.trim(),
        port: int.parse(_port.text.trim()),
        user: _user.text.trim(),
        password: opt(_password),
        privateKeyPem: opt(_key),
        tmuxCmd: _tmux.text.trim().isEmpty ? 'tmux' : _tmux.text.trim(),
        session: _session.text.trim().isEmpty ? 'main' : _session.text.trim(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget field(TextEditingController c, String label,
            {String? Function(String?)? validator, bool obscure = false, int maxLines = 1, TextInputType? type}) =>
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: TextFormField(
            controller: c,
            validator: validator,
            obscureText: obscure,
            maxLines: maxLines,
            keyboardType: type,
            autocorrect: false,
            decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
          ),
        );
    return Scaffold(
      appBar: AppBar(
        title: Text(h == null ? 'Add host' : 'Edit host'),
        actions: [IconButton(onPressed: _save, icon: const Icon(Icons.check))],
      ),
      body: Form(
        key: _form,
        child: ListView(padding: const EdgeInsets.all(16), children: [
          field(_name, 'Name'),
          field(_host, 'Host', validator: _required, type: TextInputType.url),
          field(_port, 'Port',
              type: TextInputType.number,
              validator: (v) => (int.tryParse(v ?? '') ?? 0) > 0 ? null : 'Port number'),
          field(_user, 'User', validator: _required),
          field(_password, 'Password', obscure: true),
          field(_key, 'Private key (PEM)', maxLines: 6),
          field(_tmux, 'tmux command'),
          field(_session, 'Session'),
        ]),
      ),
    );
  }
}
