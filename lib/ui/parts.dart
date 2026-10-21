import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'fonts.dart';
import 'theme.dart';

/// Inset group: rows on a rounded card one step above the ground, hairlines between rows.
class Group extends StatelessWidget {
  final List<Widget> children;
  final Color? color;
  const Group({super.key, required this.children, this.color});
  @override
  Widget build(BuildContext context) => Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(color: color ?? Tone.surface, borderRadius: BorderRadius.circular(14)),
        child: Material(
          type: MaterialType.transparency,
          child: Column(children: [
            for (var i = 0; i < children.length; i++) ...[
              if (i > 0) Divider(height: 0.5, thickness: 0.5, color: Tone.line),
              children[i],
            ],
          ]),
        ),
      );
}

/// Overline above a group.
class SectionLabel extends StatelessWidget {
  final String text;
  const SectionLabel(this.text, {super.key});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 18, 4, 8),
        child: Text(text.toUpperCase(),
            style: TextStyle(fontSize: 12, letterSpacing: 1.2, color: Tone.muted, fontWeight: FontWeight.w600)),
      );
}

/// Row with a title, optional subtitle and a switch.
class SwitchRow extends StatelessWidget {
  final String title;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool> onChanged;
  const SwitchRow({super.key, required this.title, this.subtitle, required this.value, required this.onChanged});
  @override
  Widget build(BuildContext context) => SwitchListTile(
        contentPadding: const EdgeInsets.symmetric(horizontal: 16),
        title: Text(title, style: TextStyle(fontSize: 15, color: Tone.text)),
        subtitle: subtitle == null ? null : Text(subtitle!, style: TextStyle(fontSize: 13, color: Tone.muted)),
        value: value,
        onChanged: (v) {
          HapticFeedback.selectionClick();
          onChanged(v);
        },
      );
}

/// Row that opens something: title, a value on the right, chevron.
class NavRow extends StatelessWidget {
  final String title;
  final Widget? value;
  final IconData? icon;
  final Color? color;
  final VoidCallback onTap;
  const NavRow({super.key, required this.title, this.value, this.icon, this.color, required this.onTap});
  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 52),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(children: [
              if (icon != null) ...[Icon(icon, size: 20, color: color ?? accent), const SizedBox(width: 14)],
              Expanded(child: Text(title, style: TextStyle(fontSize: 15, color: color ?? Tone.text))),
              if (value != null) ...[value!, const SizedBox(width: 6)],
              if (color == null) Icon(Icons.chevron_right_rounded, size: 20, color: Tone.muted),
            ]),
          ),
        ),
      );
}

/// Large page title (screens without an app bar title; system back navigates).
class PageTitle extends StatelessWidget {
  final String text;
  final String? overline;
  const PageTitle(this.text, {super.key, this.overline});
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 8, 4, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          if (overline != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(overline!, style: TextStyle(fontFamily: termFont.value, fontSize: 13, color: Tone.muted)),
            ),
          Text(text, style: TextStyle(fontSize: 28, fontWeight: FontWeight.w700, letterSpacing: -0.4, color: Tone.text)),
        ]),
      );
}

/// Pill button, 52 high: primary (accent fill) or secondary (raised fill).
class PillButton extends StatelessWidget {
  final String label;
  final IconData? icon;
  final bool primary, danger;
  final VoidCallback? onPressed;
  const PillButton(this.label, {super.key, this.icon, this.primary = true, this.danger = false, this.onPressed});
  @override
  Widget build(BuildContext context) {
    final bg = danger ? Tone.danger.withValues(alpha: 0.16) : (primary ? accent : Tone.raised);
    final fg = danger ? Tone.danger : (primary ? Tone.onAccent : Tone.text);
    return FilledButton(
      style: FilledButton.styleFrom(
        backgroundColor: bg,
        foregroundColor: fg,
        minimumSize: const Size(0, 52),
        padding: const EdgeInsets.symmetric(horizontal: 24),
        shape: const StadiumBorder(),
        textStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
      ),
      onPressed: onPressed == null
          ? null
          : () {
              HapticFeedback.selectionClick();
              onPressed!();
            },
      child: Row(mainAxisSize: MainAxisSize.min, children: [
        if (icon != null) ...[Icon(icon, size: 20), const SizedBox(width: 8)],
        Text(label),
      ]),
    );
  }
}

/// The app's wordmark: "one pane" in the terminal font with a block cursor.
class Wordmark extends StatelessWidget {
  final double size;
  const Wordmark({super.key, this.size = 24});
  @override
  Widget build(BuildContext context) => Row(mainAxisSize: MainAxisSize.min, children: [
        Text('one pane',
            style: TextStyle(
                wordSpacing: -size * 0.3,
                fontFamily: termFont.value,
                fontSize: size,
                fontWeight: FontWeight.w700,
                letterSpacing: -size / 30,
                color: Tone.text)),
        const SizedBox(width: 3),
        Container(width: size * 0.46, height: size * 1.05, color: accent),
      ]);
}

/// Confirm dialog for a destructive action. True when confirmed.
Future<bool> confirmDanger(BuildContext context, {required String title, required String body, required String action}) async =>
    await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: Tone.raised,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(22)),
        title: Text(title, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600, color: Tone.text)),
        content: Text(body, style: TextStyle(fontSize: 14, height: 1.5, color: Tone.muted)),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text('Cancel', style: TextStyle(color: Tone.text))),
          TextButton(
            style: TextButton.styleFrom(backgroundColor: Tone.danger.withValues(alpha: 0.16)),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action, style: TextStyle(color: Tone.danger, fontWeight: FontWeight.w600)),
          ),
        ],
      ),
    ) ??
    false;
