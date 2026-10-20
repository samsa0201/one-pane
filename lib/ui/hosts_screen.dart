import 'package:flutter/material.dart';

import '../quick_access.dart';
import '../ssh/connection.dart';
import 'glass.dart';
import 'minimap.dart' show accent;
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
  Future<void>? _session; // the running _open

  @override
  void initState() {
    super.initState();
    QuickAccess.listen(_launch);
    _load().then((_) async {
      final asked = await QuickAccess.initialHost(); // started from the home-screen widget
      if (asked != null) return _launch(asked);
      // The app went away while a pane was open: go back there.
      final open = await _store.openHost();
      final h = _hosts.where((h) => h.id == open).firstOrNull;
      if (h != null && mounted) _connect(h);
    });
  }

  /// Home-screen widget tap: [id] '' = host list, else connect there (leaving another host's pane).
  Future<void> _launch(String id) async {
    if (!mounted || _connecting == id) return;
    if (_connecting != null && ModalRoute.of(context)!.isCurrent) return; // still connecting elsewhere
    Navigator.popUntil(context, (r) => r.isFirst);
    await _session; // the left pane's cleanup is done
    if (id.isEmpty || !mounted) return;
    await _load();
    final h = _hosts.where((h) => h.id == id).firstOrNull;
    if (h != null && mounted) _connect(h);
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

  void _connect(HostConfig h) {
    if (_connecting == null) _session = _open(h);
  }

  Future<void> _open(HostConfig h) async {
    setState(() => _connecting = h.id);
    final messenger = ScaffoldMessenger.of(context);
    try {
      await _store.loadSecrets(h);
      final place = await _store.lastPlace(h.id); // where the user was last time
      final (ssh, tmux) = await connectTmux(h, session: place?.$1);
      if (!mounted) {
        ssh.close();
        return;
      }
      await _store.setOpenHost(h.id);
      if (!mounted) return;
      await Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => PaneScreen(
            ssh: ssh,
            client: tmux,
            session: place?.$1 ?? h.session,
            initialPane: place?.$2,
            onPlace: (s, p) => _store.setPlace(h.id, s, p),
            reconnect: () async => connectTmux(h, session: (await _store.lastPlace(h.id))?.$1),
          ),
        ),
      );
      await _store.setOpenHost(null); // left on purpose: start on the host list next time
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Connect failed: $e')));
    } finally {
      if (mounted) setState(() => _connecting = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('tmux pocket', style: TextStyle(fontWeight: FontWeight.w600)),
        actions: [
          ValueListenableBuilder<bool>(
            valueListenable: glassEffects,
            builder: (context, on, _) => IconButton(
              tooltip: on ? 'Glass effects on' : 'Glass effects off',
              icon: Icon(on ? Icons.blur_on : Icons.blur_off),
              onPressed: () => setGlassEffects(!on),
            ),
          ),
        ],
      ),
      floatingActionButton: Glass(
        radius: const BorderRadius.all(Radius.circular(28)),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: _edit,
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 22, vertical: 16),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.add),
                  SizedBox(width: 8),
                  Text('Host', style: TextStyle(fontWeight: FontWeight.w600)),
                ],
              ),
            ),
          ),
        ),
      ),
      body: _hosts.isEmpty
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.terminal, size: 56, color: scheme.primary),
                    const SizedBox(height: 16),
                    Text('No hosts yet', style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 8),
                    Text(
                      'Add an SSH host; tmux is attached in control mode, one pane at a time.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onSurfaceVariant),
                    ),
                  ],
                ),
              ),
            )
          : ListView(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 88),
              children: [
                for (final h in _hosts)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 5),
                    child: Glass(
                      radius: const BorderRadius.all(Radius.circular(22)),
                      child: Material(
                        type: MaterialType.transparency,
                        child: ListTile(
                          shape: const RoundedRectangleBorder(
                            borderRadius: BorderRadius.all(Radius.circular(22)),
                          ),
                          contentPadding: const EdgeInsets.only(left: 16, right: 4),
                          leading: CircleAvatar(
                            backgroundColor: accent.withValues(alpha: 0.22),
                            foregroundColor: accent,
                            child: _connecting == h.id
                                ? const SizedBox(
                                    width: 20,
                                    height: 20,
                                    child: CircularProgressIndicator(strokeWidth: 2),
                                  )
                                : Text(h.name.isEmpty ? '?' : h.name.characters.first.toUpperCase()),
                          ),
                          title: Text(h.name, maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text(
                            _connecting == h.id
                                ? 'Connecting…'
                                : '${h.user}@${h.host}:${h.port} · ${h.session}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                          onTap: () => _connect(h),
                          trailing: PopupMenuButton<String>(
                            onSelected: (v) => v == 'edit' ? _edit(h) : _delete(h),
                            itemBuilder: (_) => const [
                              PopupMenuItem(value: 'edit', child: Text('Edit')),
                              PopupMenuItem(value: 'delete', child: Text('Delete')),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
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
    Widget field(
      TextEditingController c,
      String label, {
      String? Function(String?)? validator,
      bool obscure = false,
      int maxLines = 1,
      TextInputType? type,
    }) => Padding(
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
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            field(_name, 'Name'),
            field(_host, 'Host', validator: _required, type: TextInputType.url),
            field(
              _port,
              'Port',
              type: TextInputType.number,
              validator: (v) => (int.tryParse(v ?? '') ?? 0) > 0 ? null : 'Port number',
            ),
            field(_user, 'User', validator: _required),
            field(_password, 'Password', obscure: true),
            field(_key, 'Private key (PEM)', maxLines: 6),
            field(_tmux, 'tmux command'),
            field(_session, 'Session'),
          ],
        ),
      ),
    );
  }
}
