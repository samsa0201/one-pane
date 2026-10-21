import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../quick_access.dart';
import '../ssh/connection.dart';
import 'fonts.dart';
import 'glass.dart';
import 'parts.dart';
import 'settings_screen.dart' show openSettings;
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
    await _load();
    if (h == null) _connect(saved); // "Save and connect"
  }

  Future<void> _delete(HostConfig h) async {
    if (!await confirmDanger(context,
        title: 'Delete ${h.name}?',
        body: 'Its address, key and saved place go. The server and its tmux sessions are not touched.',
        action: 'Delete')) {
      return;
    }
    await _store.delete(h.id);
    _load();
  }

  /// First connection to a host: show its key fingerprint and ask (trust on first use, visibly).
  Future<bool> _trust(HostConfig h, String type, String fingerprint) async {
    if (!mounted) return false;
    final fp = fingerprint.replaceFirst('SHA256:', '').replaceAll('=', '');
    final groups = [for (var i = 0; i < fp.length; i += 10) fp.substring(i, i + 10 > fp.length ? fp.length : i + 10)];
    final alg = type.replaceFirst('ssh-', '').toUpperCase();
    return await showGlassSheet<bool>(
          context: context,
          builder: (ctx) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Align(
                  alignment: Alignment.centerLeft,
                  child: Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(color: accent.withValues(alpha: 0.12), borderRadius: BorderRadius.circular(14)),
                    child: Icon(Icons.verified_user_outlined, color: accent),
                  ),
                ),
                const SizedBox(height: 16),
                Text.rich(
                  TextSpan(text: 'First time on ', children: [
                    TextSpan(text: h.host, style: TextStyle(fontFamily: termFont.value, fontSize: 19)),
                  ]),
                  style: TextStyle(fontSize: 22, fontWeight: FontWeight.w600, color: Tone.text),
                ),
                const SizedBox(height: 8),
                Text('Check that this fingerprint is the server’s before you trust it. One Pane remembers it and '
                    'refuses to connect if it ever changes.',
                    style: TextStyle(fontSize: 15, height: 1.45, color: Tone.muted)),
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(14),
                  decoration: BoxDecoration(color: Tone.ground, borderRadius: BorderRadius.circular(12)),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text('$alg · SHA256', style: TextStyle(fontSize: 12, color: Tone.muted)),
                    const SizedBox(height: 6),
                    SelectableText(groups.join(' '),
                        style: TextStyle(fontFamily: termFont.value, fontSize: 15, height: 1.6, color: Tone.text)),
                  ]),
                ),
                const SizedBox(height: 12),
                Text.rich(
                  TextSpan(text: 'On the server: ', children: [
                    TextSpan(
                        text: 'ssh-keygen -lf /etc/ssh/ssh_host_${type.replaceFirst('ssh-', '')}_key.pub',
                        style: TextStyle(fontFamily: termFont.value, color: Tone.text)),
                  ]),
                  style: TextStyle(fontSize: 13, height: 1.45, color: Tone.muted),
                ),
                const SizedBox(height: 20),
                PillButton('Trust and connect', onPressed: () => Navigator.pop(ctx, true)),
                const SizedBox(height: 8),
                TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(0, 48)),
                  onPressed: () => Navigator.pop(ctx, false),
                  child: Text('Cancel', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Tone.text)),
                ),
              ]),
            ),
          ),
        ) ??
        false;
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
      final (ssh, tmux) =
          await connectTmux(h, session: place?.$1, trust: (type, fp) => _trust(h, type, fp));
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
            title: h.name,
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
      _load();
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Connect failed: $e')));
    } finally {
      if (mounted) setState(() => _connecting = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_hosts.isEmpty) return _welcome();
    return Scaffold(
      body: SafeArea(
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 16), children: [
              Row(children: [
                const Padding(padding: EdgeInsets.only(left: 4), child: Wordmark()),
                const Spacer(),
                IconButton(
                  tooltip: 'Settings',
                  iconSize: 22,
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  icon: Icon(Icons.tune_rounded, color: Tone.muted),
                  onPressed: () => openSettings(context),
                ),
              ]),
              const SizedBox(height: 16),
              FutureBuilder<(HostConfig, (String, int)?)?>(
                future: () async {
                  final id = await _store.lastHost();
                  final h = _hosts.where((h) => h.id == id).firstOrNull;
                  return h == null ? null : (h, await _store.lastPlace(h.id));
                }(),
                builder: (context, snap) {
                  final d = snap.data;
                  return d == null ? const SizedBox.shrink() : _continueCard(d.$1, d.$2);
                },
              ),
              const SectionLabel('Hosts'),
              Group(children: [for (final h in _hosts) _hostRow(h)]),
            ]),
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: PillButton('New host', icon: Icons.add_rounded, onPressed: _edit),
          ),
        ]),
      ),
    );
  }

  Widget _continueCard(HostConfig h, (String, int)? place) => Material(
        color: Tone.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(18),
          side: BorderSide(color: accent.withValues(alpha: 0.35)),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: () => _connect(h),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('CONTINUE',
                  style: TextStyle(fontSize: 12, letterSpacing: 1.2, fontWeight: FontWeight.w600, color: accent)),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(h.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Tone.text)),
                    const SizedBox(height: 4),
                    Text(place == null ? h.session : '${place.$1} › pane %${place.$2}',
                        style: TextStyle(fontFamily: termFont.value, fontSize: 13, color: Tone.muted)),
                  ]),
                ),
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(color: accent, shape: BoxShape.circle),
                  child: _connecting == h.id
                      ? Padding(
                          padding: const EdgeInsets.all(12),
                          child: CircularProgressIndicator(strokeWidth: 2, color: Tone.onAccent))
                      : Icon(Icons.arrow_forward_rounded, color: Tone.onAccent, semanticLabel: 'Continue'),
                ),
              ]),
            ]),
          ),
        ),
      );

  Widget _hostRow(HostConfig h) {
    final colors = [accent, Tone.info, Tone.warn, termPalette.value.ansi[13], termPalette.value.ansi[14]];
    final c = colors[h.id.hashCode.abs() % colors.length];
    return InkWell(
      onTap: () => _connect(h),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 72),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 10, 4, 10),
          child: Row(children: [
            Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: c.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(10)),
              child: _connecting == h.id
                  ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: c))
                  : Text(h.name.isEmpty ? '?' : h.name.characters.first.toUpperCase(),
                      style: TextStyle(fontFamily: termFont.value, fontSize: 17, fontWeight: FontWeight.w700, color: c)),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(h.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: Tone.text)),
                const SizedBox(height: 3),
                Text(
                  _connecting == h.id
                      ? 'Connecting…'
                      : '${h.user}@${h.host}${h.port == 22 ? '' : ':${h.port}'}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontFamily: termFont.value, fontSize: 12, color: Tone.muted),
                ),
              ]),
            ),
            PopupMenuButton<String>(
              tooltip: 'More for ${h.name}',
              icon: Icon(Icons.more_vert_rounded, color: Tone.muted),
              onSelected: (v) => v == 'edit' ? _edit(h) : _delete(h),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'edit', child: Text('Edit')),
                PopupMenuItem(value: 'delete', child: Text('Delete', style: TextStyle(color: Tone.danger))),
              ],
            ),
          ]),
        ),
      ),
    );
  }

  /// No hosts yet: what the app is, one action.
  Widget _welcome() => Scaffold(
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
            child: Column(children: [
              Align(
                alignment: Alignment.topRight,
                child: IconButton(
                  tooltip: 'Settings',
                  constraints: const BoxConstraints(minWidth: 48, minHeight: 48),
                  icon: Icon(Icons.tune_rounded, color: Tone.muted),
                  onPressed: () => openSettings(context),
                ),
              ),
              Expanded(
                child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                  Container(
                    width: 150,
                    height: 210,
                    padding: const EdgeInsets.all(9),
                    decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(26), border: Border.all(color: Tone.raised, width: 2)),
                    child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      Expanded(
                        child: Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                              color: Tone.surface,
                              borderRadius: BorderRadius.circular(13),
                              border: Border.all(color: accent, width: 1.5)),
                          child: Text.rich(TextSpan(children: [
                            TextSpan(text: '❯ ', style: TextStyle(color: accent)),
                            TextSpan(text: '_', style: TextStyle(color: Tone.muted)),
                          ]), style: TextStyle(fontFamily: termFont.value, fontSize: 11)),
                        ),
                      ),
                      const SizedBox(width: 5),
                      Expanded(
                        child: Column(children: [
                          for (var i = 0; i < 2; i++) ...[
                            if (i > 0) const SizedBox(height: 5),
                            Expanded(
                              child: Container(
                                decoration: BoxDecoration(
                                    color: Tone.surface,
                                    borderRadius: BorderRadius.circular(13),
                                    border: Border.all(color: Tone.raised)),
                              ),
                            ),
                          ],
                        ]),
                      ),
                    ]),
                  ),
                  const SizedBox(height: 40),
                  const Wordmark(size: 30),
                  const SizedBox(height: 14),
                  Text('Your tmux sessions over SSH, one pane at a time, sized for the phone in your hand.',
                      textAlign: TextAlign.center, style: TextStyle(fontSize: 16, height: 1.5, color: Tone.muted)),
                ]),
              ),
              SizedBox(
                width: double.infinity,
                child: PillButton('Add your first host', icon: Icons.add_rounded, onPressed: _edit),
              ),
              const SizedBox(height: 12),
              Text('Needs SSH access and tmux on the server.', style: TextStyle(fontSize: 13, color: Tone.muted)),
            ]),
          ),
        ),
      );
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
  late bool _useKey = h == null || (h!.privateKeyPem ?? '').isNotEmpty || (h!.password ?? '').isEmpty;
  late bool _pasteKey = false; // editing the private key text instead of the summary card
  bool _more = false;

  String? _required(String? v) => v == null || v.trim().isEmpty ? 'Required' : null;

  void _save() {
    if (!_form.currentState!.validate()) return;
    String? opt(TextEditingController c) => c.text.trim().isEmpty ? null : c.text;
    Navigator.pop(
      context,
      HostConfig(
        id: h?.id ?? DateTime.now().microsecondsSinceEpoch.toString(),
        name: _name.text.trim().isEmpty ? _host.text.trim() : _name.text.trim(),
        host: _host.text.trim(),
        port: int.parse(_port.text.trim()),
        user: _user.text.trim(),
        password: _useKey ? null : opt(_password),
        privateKeyPem: _useKey ? opt(_key) : null,
        tmuxCmd: _tmux.text.trim().isEmpty ? 'tmux' : _tmux.text.trim(),
        session: _session.text.trim().isEmpty ? 'main' : _session.text.trim(),
      ),
    );
  }

  void _generate() {
    final (pem, _) = generateKey();
    setState(() {
      _key.text = pem;
      _pasteKey = false;
    });
  }

  Widget _field(TextEditingController c, String label,
          {String? Function(String?)? validator, bool obscure = false, int maxLines = 1, TextInputType? type, bool mono = true}) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextFormField(
          controller: c,
          validator: validator,
          obscureText: obscure,
          maxLines: maxLines,
          keyboardType: type,
          autocorrect: false,
          enableSuggestions: false,
          style: TextStyle(fontFamily: mono ? termFont.value : null, fontSize: 15, color: Tone.text),
          decoration: InputDecoration(labelText: label),
        ),
      );

  Widget _keyCard() {
    final pub = publicLineOf(_key.text);
    if (_pasteKey || (_key.text.trim().isNotEmpty && pub == null)) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        _field(_key, 'Private key (OpenSSH or PEM)', maxLines: 6,
            validator: (v) => v == null || v.trim().isEmpty || publicLineOf(v) != null
                ? null
                : 'Not a key this app can read (passphrase keys are not supported yet)'),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: _generate,
            child: Text('Make a new key on this phone instead', style: TextStyle(color: accent)),
          ),
        ),
      ]);
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(color: Tone.surface, borderRadius: BorderRadius.circular(14)),
      child: pub == null
          ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('No key yet', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Tone.text)),
              const SizedBox(height: 6),
              Text('Make one here (the private half never leaves this phone), or paste one you already use.',
                  style: TextStyle(fontSize: 13, height: 1.45, color: Tone.muted)),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                PillButton('Make a key', icon: Icons.key_rounded, onPressed: _generate),
                PillButton('Paste a key', primary: false, onPressed: () => setState(() => _pasteKey = true)),
              ]),
            ])
          : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(Icons.key_rounded, size: 20, color: accent),
                const SizedBox(width: 10),
                Expanded(
                    child: Text('Key on this phone',
                        style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600, color: Tone.text))),
                Text(pub.split(' ').first.replaceFirst('ssh-', ''),
                    style: TextStyle(fontFamily: termFont.value, fontSize: 12, color: Tone.muted)),
              ]),
              const SizedBox(height: 12),
              Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(color: Tone.ground, borderRadius: BorderRadius.circular(10)),
                child: Text(pub,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontFamily: termFont.value, fontSize: 12, height: 1.5, color: Tone.muted)),
              ),
              const SizedBox(height: 10),
              Text.rich(
                TextSpan(text: 'Add this line to ', children: [
                  TextSpan(text: '~/.ssh/authorized_keys', style: TextStyle(fontFamily: termFont.value, color: Tone.text)),
                  const TextSpan(text: ' on the server.'),
                ]),
                style: TextStyle(fontSize: 13, height: 1.45, color: Tone.muted),
              ),
              const SizedBox(height: 12),
              Wrap(spacing: 8, runSpacing: 8, children: [
                PillButton('Copy', icon: Icons.copy_rounded, primary: false, onPressed: () {
                  Clipboard.setData(ClipboardData(text: pub));
                  ScaffoldMessenger.of(context)
                      .showSnackBar(const SnackBar(content: Text('Public key copied'), duration: Duration(seconds: 2)));
                }),
                TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(0, 52)),
                  onPressed: () => setState(() => _pasteKey = true),
                  child: Text('Use another key', style: TextStyle(color: accent, fontWeight: FontWeight.w600)),
                ),
              ]),
            ]),
    );
  }

  @override
  Widget build(BuildContext context) {
    Widget segment(String label, bool on, VoidCallback tap) => Expanded(
          child: GestureDetector(
            onTap: tap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 150),
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(color: on ? Tone.text : Colors.transparent, borderRadius: BorderRadius.circular(9)),
              child: Text(label,
                  style: TextStyle(
                      fontSize: 14, fontWeight: on ? FontWeight.w600 : FontWeight.w500, color: on ? Tone.ground : Tone.muted)),
            ),
          ),
        );
    return Scaffold(
      appBar: AppBar(toolbarHeight: 40),
      body: Form(
        key: _form,
        child: Column(children: [
          Expanded(
            child: ListView(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
              PageTitle(h == null ? 'New host' : 'Edit host'),
              const SizedBox(height: 12),
              _field(_host, 'Host', validator: _required, type: TextInputType.url),
              Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Expanded(child: _field(_user, 'User', validator: _required)),
                const SizedBox(width: 10),
                SizedBox(
                  width: 96,
                  child: _field(_port, 'Port',
                      type: TextInputType.number,
                      validator: (v) {
                        final n = int.tryParse(v?.trim() ?? '') ?? 0;
                        return n > 0 && n < 65536 ? null : '1–65535';
                      }),
                ),
              ]),
              Padding(
                padding: const EdgeInsets.fromLTRB(4, 4, 4, 8),
                child: Text('Sign in with', style: TextStyle(fontSize: 13, color: Tone.muted)),
              ),
              Container(
                padding: const EdgeInsets.all(4),
                decoration: BoxDecoration(color: Tone.raised, borderRadius: BorderRadius.circular(12)),
                child: Row(children: [
                  segment('SSH key', _useKey, () => setState(() => _useKey = true)),
                  const SizedBox(width: 4),
                  segment('Password', !_useKey, () => setState(() => _useKey = false)),
                ]),
              ),
              const SizedBox(height: 14),
              if (_useKey) _keyCard() else _field(_password, 'Password', obscure: true, mono: false),
              const SizedBox(height: 4),
              InkWell(
                onTap: () => setState(() => _more = !_more),
                child: SizedBox(
                  height: 48,
                  child: Row(children: [
                    const SizedBox(width: 4),
                    Text('Name, tmux command, start session', style: TextStyle(fontSize: 14, color: Tone.muted)),
                    Icon(_more ? Icons.expand_less_rounded : Icons.expand_more_rounded, size: 18, color: Tone.muted),
                  ]),
                ),
              ),
              if (_more) ...[
                _field(_name, 'Name (defaults to the host)', mono: false),
                _field(_tmux, 'tmux command'),
                _field(_session, 'Start session'),
              ],
            ]),
          ),
          SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
              child: SizedBox(
                  width: double.infinity, child: PillButton(h == null ? 'Save and connect' : 'Save', onPressed: _save)),
            ),
          ),
        ]),
      ),
    );
  }
}
