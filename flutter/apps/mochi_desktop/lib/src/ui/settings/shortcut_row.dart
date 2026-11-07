// A global shortcut in Settings (docs/SPRINT_2.md W4): the combination as key caps, Change… to record a new one (Esc
// cancels), back to the default, or none. A combination Windows, the app you're in or Mochi's other shortcut already
// uses is refused with the reason; one another app has registered shows up once Windows says so.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mochi_ui/mochi_ui.dart';

import '../../core/hotkeys.dart';
import '../../desktop.dart';
import 'settings_kit.dart';

class ShortcutRow extends StatefulWidget {
  const ShortcutRow({super.key, required this.desktop, required this.shortcut, required this.title, required this.subtitle});

  final MochiDesktop desktop;
  final MochiShortcut shortcut;
  final String title;
  final String subtitle;

  @override
  State<ShortcutRow> createState() => _ShortcutRowState();
}

class _ShortcutRowState extends State<ShortcutRow> {
  bool _recording = false;
  String? _refused;
  final FocusNode _recorder = FocusNode(debugLabel: 'shortcut recorder');

  MochiDesktop get desktop => widget.desktop;

  @override
  void dispose() {
    FocusManager.instance.removeListener(_keepFocus);
    if (_recording) desktop.hotkeys.resume().ignore();
    _recorder.dispose();
    super.dispose();
  }

  Future<void> _record() async {
    setState(() {
      _recording = true;
      _refused = null;
    });
    // The keys come here (never to a button, where Space or Enter would press it), and stay here: on Windows, the
    // window coming forward under the click can hand the focus back to where it was a moment later.
    _recorder.requestFocus();
    FocusManager.instance.addListener(_keepFocus);
    // Mochi's own shortcuts let go meanwhile, so pressing one records it instead of running it.
    await desktop.hotkeys.suspend();
  }

  void _keepFocus() {
    if (_recording && mounted && !_recorder.hasPrimaryFocus) _recorder.requestFocus();
  }

  Future<void> _stop() async {
    if (!_recording) return;
    FocusManager.instance.removeListener(_keepFocus);
    setState(() => _recording = false);
    await desktop.hotkeys.resume();
  }

  /// While recording every key is the recorder's: the first that isn't a modifier makes the combination; Escape on its
  /// own cancels.
  KeyEventResult _key(FocusNode node, KeyEvent event) {
    if (!_recording) return KeyEventResult.ignored;
    if (event is! KeyDownEvent) return KeyEventResult.handled;
    final keys = HardwareKeyboard.instance;
    final key = event.logicalKey;
    if (Hotkey.isModifier(key)) return KeyEventResult.handled;
    final plain = !keys.isControlPressed && !keys.isAltPressed && !keys.isShiftPressed && !keys.isMetaPressed;
    if (key == LogicalKeyboardKey.escape && plain) {
      _stop().ignore();
      return KeyEventResult.handled;
    }
    final code = Hotkey.keyFor(key);
    if (code == null) {
      setState(() => _refused = 'Mochi can’t use that key. Try a letter, a number, Space or a function key.');
      return KeyEventResult.handled;
    }
    choose(Hotkey(code, ctrl: keys.isControlPressed, alt: keys.isAltPressed, shift: keys.isShiftPressed, win: keys.isMetaPressed));
    return KeyEventResult.handled;
  }

  /// Takes [hotkey] unless it clashes with something (then says why and keeps the old one).
  void choose(Hotkey? hotkey) {
    final settings = desktop.settings;
    final other = MochiShortcut.values.firstWhere((value) => value != widget.shortcut);
    final problem = hotkey == null ? null : HotkeyConflicts.problem(hotkey, shortcut: widget.shortcut, other: settings.shortcut(other));
    setState(() => _refused = problem);
    if (problem == null) settings.setShortcut(widget.shortcut, hotkey);
    _stop().ignore();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: Listenable.merge([desktop.settings, desktop.hotkeys]),
    builder: (context, _) {
      final p = context.palette;
      final supported = desktop.hotkeys.registrar.supported;
      final current = desktop.settings.shortcut(widget.shortcut);
      final taken = desktop.hotkeys.problem(widget.shortcut);
      final atDefault = current == widget.shortcut.defaultHotkey;
      return Focus(
        focusNode: _recorder,
        onKeyEvent: _key,
        child: Padding(
          padding: rowPadding,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              MergeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(widget.title, style: context.type.subheadline.copyWith(fontWeight: FontWeight.w600)),
                    const SizedBox(height: 2),
                    Text(widget.subtitle, style: context.type.caption),
                  ],
                ),
              ),
              const SizedBox(height: Space.s),
              Semantics(
                liveRegion: _recording,
                label: _recording
                    ? 'Recording a shortcut. Press the keys, or Escape to cancel.'
                    : '${widget.title}: ${current?.label ?? 'none'}',
                excludeSemantics: true,
                child: _recording
                    ? Container(
                        padding: const EdgeInsets.symmetric(horizontal: Space.m, vertical: Space.s),
                        decoration: BoxDecoration(
                          color: p.sunken,
                          borderRadius: BorderRadius.circular(Radii.tile),
                          border: Border.all(color: p.tint, width: 2),
                        ),
                        child: Text('Press the new shortcut… (Esc cancels)', style: context.type.footnote.copyWith(color: p.ink)),
                      )
                    : current == null
                    ? Text('None', style: context.type.footnote)
                    : Wrap(spacing: 4, runSpacing: 4, children: [for (final key in current.keys) _KeyCap(text: key)]),
              ),
              const SizedBox(height: Space.s),
              Wrap(
                spacing: Space.s,
                runSpacing: Space.s,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  if (_recording)
                    OutlinedButton(onPressed: () => _stop().ignore(), child: const Text('Cancel'))
                  else
                    OutlinedButton(onPressed: supported ? () => _record().ignore() : null, child: const Text('Change…')),
                  if (!atDefault && !_recording)
                    TextButton(
                      onPressed: supported ? () => choose(widget.shortcut.defaultHotkey) : null,
                      child: Text('Use ${widget.shortcut.defaultHotkey.label}'),
                    ),
                  if (current != null && !_recording)
                    TextButton(onPressed: supported ? () => choose(null) : null, child: const Text('Turn Off')),
                ],
              ),
              if (!supported)
                const Padding(
                  padding: EdgeInsets.only(top: Space.s),
                  child: NoteLabel(text: 'Global shortcuts work in Mochi for Windows.', icon: Icons.info_outline_rounded),
                ),
              if (_refused != null)
                Padding(
                  padding: const EdgeInsets.only(top: Space.s),
                  child: NoteLabel(text: _refused!, icon: Icons.block_rounded, tint: p.warning, textColor: p.warning),
                ),
              if (taken != null && _refused == null && !_recording)
                Padding(
                  padding: const EdgeInsets.only(top: Space.s),
                  child: NoteLabel(text: taken, icon: Icons.warning_amber_rounded, tint: p.warning, textColor: p.warning),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// One key of a shortcut, drawn as a key cap.
class _KeyCap extends StatelessWidget {
  const _KeyCap({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    return Container(
      constraints: const BoxConstraints(minWidth: 28),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: p.sunken,
        borderRadius: BorderRadius.circular(6),
        border: Border(
          top: BorderSide(color: p.stroke),
          left: BorderSide(color: p.stroke),
          right: BorderSide(color: p.stroke),
          bottom: BorderSide(color: p.stroke, width: 2),
        ),
      ),
      child: Text(text, textAlign: TextAlign.center, style: context.type.footnote.copyWith(color: p.ink, fontWeight: FontWeight.w700)),
    );
  }
}
