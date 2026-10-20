import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// A Nerd Font "Mono" variant (icons one cell wide). Hack ships with the app; the others are
/// downloaded from the nerd-fonts release on first use and kept in the app's support directory.
class TermFont {
  final String family, name;

  /// Paths under nerd-fonts' patched-fonts/ (regular, bold); null: bundled.
  final String? regular, bold;
  const TermFont(this.family, this.name, [this.regular, this.bold]);
  bool get bundled => regular == null;
}

const _base = 'https://raw.githubusercontent.com/ryanoasis/nerd-fonts/v3.4.0/patched-fonts';

const termFonts = [
  TermFont('HackNerdFontMono', 'Hack'),
  TermFont('JetBrainsMonoNerdFontMono', 'JetBrains Mono', 'JetBrainsMono/Ligatures/Regular/JetBrainsMonoNerdFontMono-Regular.ttf',
      'JetBrainsMono/Ligatures/Bold/JetBrainsMonoNerdFontMono-Bold.ttf'),
  TermFont('FiraCodeNerdFontMono', 'Fira Code', 'FiraCode/Regular/FiraCodeNerdFontMono-Regular.ttf',
      'FiraCode/Bold/FiraCodeNerdFontMono-Bold.ttf'),
  TermFont('MesloLGSNerdFontMono', 'Meslo LGS', 'Meslo/S/Regular/MesloLGSNerdFontMono-Regular.ttf',
      'Meslo/S/Bold/MesloLGSNerdFontMono-Bold.ttf'),
  TermFont('CaskaydiaCoveNerdFontMono', 'Caskaydia Cove (Cascadia)', 'CascadiaCode/CaskaydiaCoveNerdFontMono-Regular.ttf',
      'CascadiaCode/CaskaydiaCoveNerdFontMono-Bold.ttf'),
  TermFont('SauceCodeProNerdFontMono', 'Sauce Code Pro (Source Code Pro)',
      'SourceCodePro/SauceCodeProNerdFontMono-Regular.ttf', 'SourceCodePro/SauceCodeProNerdFontMono-Bold.ttf'),
  TermFont('UbuntuMonoNerdFontMono', 'Ubuntu Mono', 'UbuntuMono/Regular/UbuntuMonoNerdFontMono-Regular.ttf',
      'UbuntuMono/Bold/UbuntuMonoNerdFontMono-Bold.ttf'),
  TermFont('IosevkaNerdFontMono', 'Iosevka', 'Iosevka/IosevkaNerdFontMono-Regular.ttf',
      'Iosevka/IosevkaNerdFontMono-Bold.ttf'),
];

/// Family the terminal uses now.
final termFont = ValueNotifier<String>(termFonts.first.family);
const _pref = 'termFont';
final _loaded = <String>{termFonts.first.family};

Future<Directory> _dir() async => Directory('${(await getApplicationSupportDirectory()).path}/fonts');

/// Downloaded already (or bundled).
Future<bool> fontReady(TermFont f) async =>
    f.bundled || await File('${(await _dir()).path}/${f.regular!.split('/').last}').exists();

/// The saved choice, if its files are here (no download at start-up).
Future<void> loadFontPref() async {
  try {
    final family = (await SharedPreferences.getInstance()).getString(_pref);
    final f = termFonts.where((f) => f.family == family).firstOrNull;
    if (f != null && await fontReady(f)) await _register(f);
    if (f != null && _loaded.contains(f.family)) termFont.value = f.family;
  } catch (_) {}
}

/// Downloads [f] if needed, registers it and makes it the terminal font. [onProgress]: 0..1.
Future<void> useFont(TermFont f, {void Function(double)? onProgress}) async {
  await _register(f, onProgress: onProgress);
  termFont.value = f.family;
  (await SharedPreferences.getInstance()).setString(_pref, f.family);
}

Future<void> _register(TermFont f, {void Function(double)? onProgress}) async {
  if (_loaded.contains(f.family)) return;
  final dir = await _dir();
  await dir.create(recursive: true);
  final loader = FontLoader(f.family);
  final paths = [f.regular!, f.bold!];
  for (var i = 0; i < paths.length; i++) {
    final file = File('${dir.path}/${paths[i].split('/').last}');
    if (!await file.exists()) {
      await _download('$_base/${paths[i]}', file, (p) => onProgress?.call((i + p) / paths.length));
    }
    loader.addFont(file.readAsBytes().then(ByteData.sublistView));
  }
  await loader.load();
  _loaded.add(f.family);
}

/// To a temp file, renamed into place once complete and checked to be a font.
Future<void> _download(String url, File to, void Function(double) onProgress) async {
  final client = HttpClient()..connectionTimeout = const Duration(seconds: 15);
  try {
    final res = await (await client.getUrl(Uri.parse(url))).close();
    if (res.statusCode != 200) throw HttpException('HTTP ${res.statusCode}', uri: Uri.parse(url));
    final part = File('${to.path}.part');
    final sink = part.openWrite();
    var got = 0;
    await for (final chunk in res) {
      sink.add(chunk);
      got += chunk.length;
      if (res.contentLength > 0) onProgress(got / res.contentLength);
    }
    await sink.close();
    if (!isFontFile(await part.openRead(0, 4).first)) {
      await part.delete();
      throw const FormatException('not a font file');
    }
    await part.rename(to.path);
  } finally {
    client.close();
  }
}

/// TrueType / OpenType signature.
@visibleForTesting
bool isFontFile(List<int> head) =>
    head.length >= 4 &&
    ((head[0] == 0 && head[1] == 1 && head[2] == 0 && head[3] == 0) ||
        String.fromCharCodes(head.take(4)) == 'OTTO' ||
        String.fromCharCodes(head.take(4)) == 'true');
