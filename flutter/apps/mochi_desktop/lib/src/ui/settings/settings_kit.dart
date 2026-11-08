// The Settings window's building blocks, after the Mac's grouped forms: icon tiles, the pane header, groups of rows on
// a soft card, switch rows, status rows, "Not on Windows yet" rows, choices, menus and confirmations. Every row reads as
// one thing to a screen reader, and every control works from the keyboard with Mochi's focus ring.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mochi_art/pose_tracks.dart';
import 'package:mochi_ui/mochi_ui.dart';

import '../../desktop.dart';
import '../pet/companion_director.dart';
import '../pet/taskbar_stroll.dart';
import '../stage/mischief_stage.dart';
import 'settings_tabs.dart';

/// What every pane gets: the app, where you are in Settings, and the ways out (pairing, Mochi's window).
class SettingsHost {
  const SettingsHost({
    required this.desktop,
    required this.navigation,
    required this.onPair,
    required this.onHome,
    this.stroll,
    this.patch,
    this.library,
    this.clock,
    this.onInstall,
    this.onRestartToUpdate,
    this.onGames,
    this.onRecap,
    this.onDecorate,
    this.mischief,
  });

  final MochiDesktop desktop;

  /// Opens the Games window (Settings › Fun › Games › Play…).
  final VoidCallback? onGames;

  /// Opens today's recap (Settings › Fun › Daily recap › Open Recap…).
  final VoidCallback? onRecap;

  /// Decorates the room in Mochi's window (Settings › Fun › Room › Decorate…).
  final VoidCallback? onDecorate;

  /// The Windows extras on the native stage, for Settings › Mischief's "Try it".
  final MischiefStage? mischief;

  /// "Install Mochi": the app copies itself into place and hands over to the installed copy.
  final VoidCallback? onInstall;

  /// "Restart to Update": the helper installs the waiting update and starts Mochi again.
  final VoidCallback? onRestartToUpdate;
  final SettingsNavigation navigation;

  /// Opens the pairing page (with a fresh code).
  final VoidCallback onPair;

  /// Opens Mochi's own window (Ask Mochi, the sessions).
  final VoidCallback onHome;

  /// The pet's stroll along the taskbar: why it isn't roaming, if it isn't.
  final TaskbarStroll? stroll;

  /// The companion himself: whether he's around, and on the taskbar ([companion] is his name).
  final CompanionDirector? patch;

  /// The recorded animations, for the previews' poses (null while they load).
  final PoseLibrary? library;
  final DateTime Function()? clock;

  DateTime get now => (clock ?? () => desktop.sessions.now)();
  String get pet => desktop.settings.petName;
  String get companion => desktop.settings.companionName;

  void open(SettingsTab tab) => navigation.tab = tab;
}

/// A tile with a white glyph on the pane's colour, lit from the top (the Mac's SettingsIcon). Decorative: the title
/// beside it says the same.
class SettingsIcon extends StatelessWidget {
  const SettingsIcon({super.key, required this.icon, required this.tint, this.size = 24});

  SettingsIcon.of(SettingsTab tab, {Key? key, double size = 24}) : this(key: key, icon: tab.icon, tint: tab.tint, size: size);

  final IconData icon;
  final Color tint;
  final double size;

  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(size * 0.27),
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Color.lerp(tint, Colors.white, 0.22)!, tint, Color.lerp(tint, Colors.black, 0.10)!],
        ),
        border: Border.all(color: Colors.white.withValues(alpha: 0.35), width: size / 44 < 0.5 ? 0.5 : size / 44),
      ),
      child: Icon(icon, size: size * 0.56, color: Colors.white),
    ),
  );
}

/// A group of rows on a soft card, with an optional title above and a note below (a Mac Form section).
class SettingsGroup extends StatelessWidget {
  const SettingsGroup({super.key, this.title, required this.children, this.footer});

  final String? title;
  final List<Widget> children;
  final String? footer;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final rows = <Widget>[];
    for (final (index, child) in children.indexed) {
      if (index > 0) rows.add(Divider(height: 1, indent: Space.m + 2, color: p.stroke.withValues(alpha: 0.8)));
      rows.add(child);
    }
    return Padding(
      padding: const EdgeInsets.only(bottom: Space.l),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.xs, 0, Space.xs, Space.s - 2),
              child: Semantics(
                header: true,
                child: Text(title!, style: context.type.footnote.copyWith(fontWeight: FontWeight.w700)),
              ),
            ),
          DecoratedBox(
            decoration: BoxDecoration(
              color: p.isDark ? Colors.white.withValues(alpha: 0.05) : Colors.white.withValues(alpha: 0.78),
              borderRadius: BorderRadius.circular(Radii.inner),
              border: Border.all(color: p.stroke.withValues(alpha: p.isDark ? 0.9 : 0.8)),
            ),
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: rows),
          ),
          if (footer != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(Space.xs, Space.s - 2, Space.xs, 0),
              child: Text(footer!, style: context.type.caption),
            ),
        ],
      ),
    );
  }
}

/// The padding every row has.
const EdgeInsets rowPadding = EdgeInsets.symmetric(horizontal: Space.m + 2, vertical: Space.s + 2);

/// A setting that's on or off: the title (and what it does) and a switch; clicking the row flips it too.
class ToggleRow extends StatelessWidget {
  const ToggleRow({super.key, required this.title, this.subtitle, required this.value, required this.onChanged});

  final String title;
  final String? subtitle;
  final bool value;

  /// Null: shown but can't be changed now.
  final ValueChanged<bool>? onChanged;

  @override
  Widget build(BuildContext context) {
    final enabled = onChanged != null;
    return MergeSemantics(
      child: InkWell(
        onTap: enabled ? () => onChanged!(!value) : null,
        // The switch takes the keyboard focus; the row is for the mouse.
        canRequestFocus: false,
        child: Padding(
          padding: rowPadding,
          child: Row(
            children: [
              Expanded(
                child: Opacity(
                  opacity: enabled ? 1 : 0.55,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(title, style: context.type.subheadline.copyWith(fontWeight: FontWeight.w600)),
                      if (subtitle != null) ...[const SizedBox(height: 2), Text(subtitle!, style: context.type.caption)],
                    ],
                  ),
                ),
              ),
              const SizedBox(width: Space.m),
              Switch(value: value, onChanged: onChanged),
            ],
          ),
        ),
      ),
    );
  }
}

/// A label and its value ("Claude Code · C:\Users\…\claude.exe"); long values wrap and can be selected.
class InfoRow extends StatelessWidget {
  const InfoRow({super.key, required this.label, required this.value, this.selectable = false, this.mono = false});

  final String label;
  final String value;
  final bool selectable;
  final bool mono;

  @override
  Widget build(BuildContext context) {
    final style = context.type.footnote.copyWith(fontFamily: mono ? 'monospace' : null);
    return MergeSemantics(
      child: Padding(
        padding: rowPadding,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(flex: 2, child: Text(label, style: context.type.subheadline)),
            const SizedBox(width: Space.m),
            Expanded(
              flex: 3,
              child: selectable
                  ? SelectableText(value, style: style, textAlign: TextAlign.end)
                  : Text(value, style: style, textAlign: TextAlign.end),
            ),
          ],
        ),
      ),
    );
  }
}

/// How something is doing: a filled tick (good) or a dashed ring, its name, and a word on it (the Mac's status rows).
class StatusRow extends StatelessWidget {
  const StatusRow({super.key, required this.title, required this.ok, required this.detail, this.icon, this.tint});

  final String title;
  final bool ok;
  final String detail;

  /// The device's own icon instead of the tick.
  final IconData? icon;
  final Color? tint;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final color = tint ?? (ok ? p.success : p.inkSecondary);
    return MergeSemantics(
      child: Padding(
        padding: rowPadding,
        child: Row(
          children: [
            ExcludeSemantics(
              child: Icon(icon ?? (ok ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded), size: 18, color: color),
            ),
            const SizedBox(width: Space.s + 2),
            Expanded(flex: 3, child: Text(title, style: context.type.subheadline.copyWith(fontWeight: FontWeight.w600))),
            const SizedBox(width: Space.s),
            Expanded(
              flex: 2,
              child: Text(detail, textAlign: TextAlign.end, style: context.type.footnote.copyWith(color: ok ? p.ink : null)),
            ),
          ],
        ),
      ),
    );
  }
}

/// Something the Mac does that Mochi for Windows doesn't yet: named, explained, and tagged, never hidden.
class SoonRow extends StatelessWidget {
  const SoonRow({super.key, required this.title, required this.detail});

  final String title;
  final String detail;

  static const String tag = 'Not on Windows yet';

  @override
  Widget build(BuildContext context) => MergeSemantics(
    child: Padding(
      padding: rowPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: Space.s,
            runSpacing: Space.xs,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(title, style: context.type.subheadline.copyWith(fontWeight: FontWeight.w600)),
              Tag(text: tag, icon: Icons.schedule_rounded, tint: context.palette.inkSecondary),
            ],
          ),
          const SizedBox(height: 2),
          Text(detail, style: context.type.caption),
        ],
      ),
    ),
  );
}

/// Buttons in a row that wraps at large text sizes.
class ActionsRow extends StatelessWidget {
  const ActionsRow({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) => Padding(
    padding: rowPadding,
    child: Wrap(spacing: Space.s, runSpacing: Space.s, crossAxisAlignment: WrapCrossAlignment.center, children: children),
  );
}

/// A note inside a group: a hint, a warning or a problem.
class NoteRow extends StatelessWidget {
  const NoteRow({super.key, required this.text, this.icon = Icons.info_outline_rounded, this.tint, this.textColor});

  final String text;
  final IconData icon;
  final Color? tint;
  final Color? textColor;

  @override
  Widget build(BuildContext context) => Padding(
    padding: rowPadding,
    child: NoteLabel(text: text, icon: icon, tint: tint, textColor: textColor),
  );
}

/// A paragraph inside a group.
class TextRow extends StatelessWidget {
  const TextRow(this.text, {super.key, this.secondary = false});

  final String text;
  final bool secondary;

  @override
  Widget build(BuildContext context) => Padding(
    padding: rowPadding,
    child: Text(text, style: secondary ? context.type.footnote : context.type.subheadline),
  );
}

/// One of a few choices, as chips that wrap onto more lines at large text sizes.
class ChoiceRow<T> extends StatelessWidget {
  const ChoiceRow({super.key, required this.label, required this.selected, required this.onSelected, required this.choices});

  final String label;
  final T selected;

  /// Null: shown but can't be changed now.
  final ValueChanged<T>? onSelected;
  final List<(T, String, IconData)> choices;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Padding(
      padding: rowPadding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: context.type.subheadline.copyWith(fontWeight: FontWeight.w600)),
          const SizedBox(height: Space.s),
          Wrap(
            spacing: Space.s,
            runSpacing: Space.s,
            children: [
              for (final (value, text, icon) in choices)
                ChoiceChip(
                  label: Text(text),
                  avatar: Icon(icon, size: 16, color: value == selected ? p.onTint : p.tint),
                  showCheckmark: false,
                  selected: value == selected,
                  selectedColor: p.tint,
                  labelStyle: context.type.label.copyWith(fontSize: 13, color: value == selected ? p.onTint : p.ink),
                  backgroundColor: p.sunken,
                  side: BorderSide(color: p.stroke),
                  onSelected: onSelected == null ? null : (_) => onSelected!(value),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// A label and a menu of choices (accessories, the theme, a birthday).
class MenuRow<T> extends StatelessWidget {
  const MenuRow({super.key, required this.label, required this.value, required this.items, required this.onChanged, this.locked = const {}});

  final String label;
  final T value;
  final List<(T, String)> items;
  final ValueChanged<T>? onChanged;

  /// Items shown but not to be chosen now (an accessory not earned yet).
  final Set<T> locked;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final menu = Container(
      padding: const EdgeInsets.symmetric(horizontal: Space.m),
      decoration: BoxDecoration(color: p.sunken, borderRadius: BorderRadius.circular(Radii.tile)),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isExpanded: true,
          borderRadius: BorderRadius.circular(Radii.inner),
          dropdownColor: p.surface,
          style: context.type.subheadline,
          focusColor: Colors.transparent,
          onChanged: onChanged == null ? null : (value) => onChanged!(value as T),
          items: [
            for (final (item, text) in items)
              DropdownMenuItem<T>(
                value: item,
                enabled: !locked.contains(item),
                child: Text(text, overflow: TextOverflow.ellipsis, style: locked.contains(item) ? TextStyle(color: p.inkSecondary) : null),
              ),
          ],
        ),
      ),
    );
    return Semantics(
      label: label,
      child: Padding(
        padding: rowPadding,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final title = ExcludeSemantics(child: Text(label, style: context.type.subheadline.copyWith(fontWeight: FontWeight.w600)));
            // Side by side when there's room; the menu under its label at large text sizes.
            if (constraints.maxWidth < 360 || MediaQuery.textScalerOf(context).scale(14) > 20) {
              return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [title, const SizedBox(height: Space.xs), menu]);
            }
            return Row(
              children: [
                Expanded(flex: 2, child: title),
                const SizedBox(width: Space.m),
                Expanded(flex: 3, child: menu),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// A name you type (the pet's, the companion's), saved as you type.
class NameFieldRow extends StatefulWidget {
  const NameFieldRow({super.key, required this.label, required this.text, required this.placeholder, required this.onChanged});

  final String label;
  final String text;
  final String placeholder;
  final ValueChanged<String> onChanged;

  @override
  State<NameFieldRow> createState() => _NameFieldRowState();
}

class _NameFieldRowState extends State<NameFieldRow> {
  late final TextEditingController _controller = TextEditingController(text: widget.text);

  @override
  void didUpdateWidget(NameFieldRow old) {
    super.didUpdateWidget(old);
    // Changed elsewhere (Reset): show the new name.
    if (widget.text != _controller.text) _controller.text = widget.text;
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: rowPadding,
    child: TextField(
      controller: _controller,
      maxLength: 24,
      onChanged: widget.onChanged,
      decoration: InputDecoration(labelText: widget.label, hintText: widget.placeholder, counterText: '', isDense: true),
    ),
  );
}

/// Asks before something that can't be undone. True when confirmed.
Future<bool> confirmAction(
  BuildContext context, {
  required String title,
  required String message,
  required String confirm,
  bool destructive = false,
}) async {
  final p = context.palette;
  final answer = await showDialog<bool>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text(title),
      content: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Text(message)),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Cancel')),
        FilledButton(
          autofocus: true,
          style: destructive ? FilledButton.styleFrom(backgroundColor: p.danger, foregroundColor: Colors.white) : null,
          onPressed: () => Navigator.pop(dialog, true),
          child: Text(confirm),
        ),
      ],
    ),
  );
  return answer ?? false;
}

/// Copies [text] and says so (on screen and to a screen reader).
Future<void> copyText(BuildContext context, String text, {String said = 'Copied'}) async {
  await Clipboard.setData(ClipboardData(text: text));
  if (!context.mounted) return;
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(said), duration: const Duration(seconds: 2)));
}

/// A small text button that opens another pane ("Phones Settings").
class PaneLink extends StatelessWidget {
  const PaneLink({super.key, required this.host, required this.tab, this.label});

  final SettingsHost host;
  final SettingsTab tab;
  final String? label;

  @override
  Widget build(BuildContext context) => TextButton.icon(
    onPressed: () => host.open(tab),
    icon: const Icon(Icons.arrow_forward_rounded, size: 16),
    label: Text(label ?? '${tab.title} Settings'),
  );
}
