// The Settings window, after the Mac's (Sources/App/Windows/SettingsView.swift): two floating glass cards over a soft
// backdrop that takes the open pane's colours. On the left, the sidebar: a search field, your pet, and the panes in
// four groups with coloured icon tiles. On the right, the open pane: a big icon tile, its title and header line, then
// its settings in groups.
//
// Keyboard: Ctrl+F searches (Enter opens the first match, Escape clears it), Up and Down move through the sidebar
// (the pane follows), Tab reaches every control, Escape closes Settings (app.dart). Narrow windows get a sidebar of
// icons only.

import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:mochi_link/mochi_link.dart';
import 'package:mochi_ui/mochi_ui.dart';

import '../settings/panes_app.dart';
import '../settings/panes_claude.dart';
import '../settings/panes_pet.dart';
import '../settings/panes_phones.dart';
import '../settings/previews.dart';
import '../settings/settings_kit.dart';
import '../settings/settings_tabs.dart';

export '../settings/settings_kit.dart' show SettingsHost;
export '../settings/settings_tabs.dart' show SettingsNavigation, SettingsTab;

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.host});

  final SettingsHost host;

  /// Below this width the sidebar shows icons only.
  static const double railBelow = 680;

  /// The smallest the cards are laid out at (the main window's minimum, less the title bar).
  static const Size minimum = Size(400, 420);

  @override
  State<SettingsScreen> createState() => SettingsScreenState();
}

class SettingsScreenState extends State<SettingsScreen> {
  final TextEditingController _search = TextEditingController();
  final FocusNode searchFocus = FocusNode(debugLabel: 'Settings search');
  final Map<SettingsTab, FocusNode> _rows = {for (final tab in SettingsTab.values) tab: FocusNode(debugLabel: 'Settings ${tab.name}')};
  final ScrollController _sidebar = ScrollController();
  final ScrollController _content = ScrollController();

  SettingsHost get host => widget.host;
  SettingsNavigation get navigation => host.navigation;

  @override
  void initState() {
    super.initState();
    _search.text = navigation.query;
    navigation.addListener(_navigated);
  }

  late SettingsTab _shown = navigation.tab;

  void _navigated() {
    // A new pane opens at its top.
    if (navigation.tab != _shown && _content.hasClients) _content.jumpTo(0);
    _shown = navigation.tab;
    if (_search.text != navigation.query) _search.text = navigation.query;
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    navigation.removeListener(_navigated);
    _search.dispose();
    searchFocus.dispose();
    for (final node in _rows.values) {
      node.dispose();
    }
    _sidebar.dispose();
    _content.dispose();
    super.dispose();
  }

  void _select(SettingsTab tab, {bool focus = false}) {
    navigation.tab = tab;
    if (focus) _rows[tab]!.requestFocus();
  }

  /// Up and Down in the sidebar (and Down from the search field): the next pane opens and takes the focus.
  KeyEventResult _sidebarKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
    final key = event.logicalKey;
    if (key != LogicalKeyboardKey.arrowDown && key != LogicalKeyboardKey.arrowUp) return KeyEventResult.ignored;
    final tabs = navigation.visibleTabs;
    if (tabs.isEmpty) return KeyEventResult.ignored;
    if (searchFocus.hasFocus) {
      if (key != LogicalKeyboardKey.arrowDown) return KeyEventResult.ignored;
      _select(tabs.contains(navigation.tab) ? navigation.tab : tabs.first, focus: true);
      return KeyEventResult.handled;
    }
    final focused = tabs.where((tab) => _rows[tab]!.hasFocus).firstOrNull;
    if (focused == null) return KeyEventResult.ignored;
    final index = tabs.indexOf(focused);
    if (key == LogicalKeyboardKey.arrowUp) {
      if (index == 0) {
        if (_railMode) return KeyEventResult.handled;
        searchFocus.requestFocus();
      } else {
        _select(tabs[index - 1], focus: true);
      }
    } else if (index < tabs.length - 1) {
      _select(tabs[index + 1], focus: true);
    }
    return KeyEventResult.handled;
  }

  /// Escape in the search field clears it first; with nothing in it, Escape closes Settings as anywhere else.
  KeyEventResult _searchKey(FocusNode node, KeyEvent event) {
    if (event is KeyDownEvent && event.logicalKey == LogicalKeyboardKey.escape && _search.text.isNotEmpty) {
      _search.clear();
      navigation.query = '';
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  bool _railMode = false;

  @override
  Widget build(BuildContext context) {
    final settings = host.desktop.settings;
    return ListenableBuilder(
      listenable: Listenable.merge([settings, host.desktop.link, host.desktop.hooks, host.desktop.motion, ?host.stroll]),
      builder: (context, _) => Scaffold(
        backgroundColor: Colors.transparent,
        body: CallbackShortcuts(
          bindings: {
            const SingleActivator(LogicalKeyboardKey.keyF, control: true): () => searchFocus.requestFocus(),
            const SingleActivator(LogicalKeyboardKey.keyF, meta: true): () => searchFocus.requestFocus(),
          },
          child: LayoutBuilder(
            builder: (context, constraints) {
              _railMode = constraints.maxWidth < SettingsScreen.railBelow;
              final cards = Padding(
                padding: const EdgeInsets.fromLTRB(14, 2, 14, 14),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    SizedBox(width: _railMode ? 68 : 236, child: GlassCard(child: _railMode ? _rail(context) : _sidebarCard(context))),
                    const SizedBox(width: 14),
                    Expanded(child: GlassCard(child: _contentCard(context))),
                  ],
                ),
              );
              // Never smaller than the main window's minimum: below it (only while the window is still changing
              // form) the cards are cut off rather than squeezed.
              const minimum = SettingsScreen.minimum;
              if (constraints.maxWidth >= minimum.width && constraints.maxHeight >= minimum.height) return cards;
              return ClipRect(
                child: OverflowBox(
                  alignment: Alignment.topLeft,
                  minWidth: minimum.width,
                  maxWidth: constraints.maxWidth < minimum.width ? minimum.width : constraints.maxWidth,
                  minHeight: minimum.height,
                  maxHeight: constraints.maxHeight < minimum.height ? minimum.height : constraints.maxHeight,
                  child: cards,
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  // MARK: Sidebar

  Widget _sidebarCard(BuildContext context) {
    final groups = navigation.visibleGroups;
    final p = context.palette;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _sidebarKey,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 0), child: _searchField(context)),
          if (navigation.query.isEmpty)
            Padding(padding: const EdgeInsets.fromLTRB(12, 10, 12, 4), child: _PetCard(host: host)),
          Expanded(
            child: Scrollbar(
              controller: _sidebar,
              child: ListView(
                controller: _sidebar,
                padding: const EdgeInsets.fromLTRB(8, 0, 8, 12),
                children: [
                  for (final group in groups) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 12, 10, 3),
                      child: Semantics(
                        header: true,
                        child: Text(group.name, style: context.type.caption.copyWith(fontWeight: FontWeight.w700)),
                      ),
                    ),
                    for (final tab in group.tabs)
                      _SidebarRow(
                        tab: tab,
                        selected: navigation.tab == tab,
                        focusNode: _rows[tab]!,
                        onTap: () => _select(tab),
                      ),
                  ],
                  if (groups.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Semantics(
                        liveRegion: true,
                        child: Text('No settings match “${navigation.query}”.', style: context.type.footnote.copyWith(color: p.inkSecondary)),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _searchField(BuildContext context) {
    final p = context.palette;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onKeyEvent: _searchKey,
      child: TextField(
        controller: _search,
        focusNode: searchFocus,
        onChanged: (value) => navigation.query = value,
        onSubmitted: (_) {
          final first = navigation.visibleTabs.firstOrNull;
          if (first != null) _select(first, focus: true);
        },
        textInputAction: TextInputAction.search,
        style: context.type.subheadline,
        decoration: InputDecoration(
          hintText: 'Search',
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          prefixIcon: Icon(Icons.search_rounded, size: 18, color: p.inkSecondary),
          prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 34),
          suffixIcon: navigation.query.isEmpty
              ? null
              : IconButton(
                  tooltip: 'Clear the search',
                  iconSize: 16,
                  onPressed: () {
                    _search.clear();
                    navigation.query = '';
                    searchFocus.requestFocus();
                  },
                  icon: const Icon(Icons.cancel_rounded),
                ),
          border: const OutlineInputBorder(borderRadius: BorderRadius.all(Radius.circular(20)), borderSide: BorderSide.none),
          focusedBorder: OutlineInputBorder(
            borderRadius: const BorderRadius.all(Radius.circular(20)),
            borderSide: BorderSide(color: p.focus, width: 2),
          ),
          semanticCounterText: '',
        ),
      ),
    );
  }

  /// Narrow windows: the panes as icon tiles, named in tooltips and to screen readers.
  Widget _rail(BuildContext context) => Focus(
    canRequestFocus: false,
    skipTraversal: true,
    onKeyEvent: _sidebarKey,
    child: Scrollbar(
      controller: _sidebar,
      child: ListView(
        controller: _sidebar,
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
        children: [
          for (final (index, group) in SettingsTab.groups.indexed) ...[
            if (index > 0) const Padding(padding: EdgeInsets.symmetric(vertical: 6, horizontal: 8), child: Divider()),
            for (final tab in group.tabs)
              _SidebarRow(tab: tab, selected: navigation.tab == tab, focusNode: _rows[tab]!, onTap: () => _select(tab), compact: true),
          ],
        ],
      ),
    ),
  );

  // MARK: Content

  Widget _contentCard(BuildContext context) {
    final tab = navigation.tab;
    final link = host.desktop.link;
    final phones = LinkPeerNames.phones(link.peers, me: link.credentials?.device);
    final blurb = tab.blurb(
      pet: host.pet,
      companion: host.companion,
      phoneNames: phones.isEmpty ? LinkPeerNames.yourPhones : LinkPeerNames.phoneNames(link.peers, me: link.credentials?.device),
    );
    final calm = MediaQuery.disableAnimationsOf(context);
    return Stack(
      children: [
        // A whisper of the pane's colour at the top of the card.
        Positioned(
          left: 0,
          right: 0,
          top: 0,
          height: 160,
          child: AnimatedContainer(
            duration: calm ? Duration.zero : const Duration(milliseconds: 300),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [tab.tint.withValues(alpha: 0.12), tab.tint.withValues(alpha: 0)],
              ),
            ),
          ),
        ),
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 20, 24, 10),
              child: Row(
                children: [
                  DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [BoxShadow(color: tab.tint.withValues(alpha: 0.35), blurRadius: 12, offset: const Offset(0, 4))],
                    ),
                    child: SettingsIcon.of(tab, size: 44),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Semantics(
                          header: true,
                          child: Text(tab.title, style: context.type.largeTitle.copyWith(fontSize: 24), maxLines: 2, overflow: TextOverflow.ellipsis),
                        ),
                        const SizedBox(height: 2),
                        Text(blurb, style: context.type.footnote, maxLines: 3, overflow: TextOverflow.ellipsis),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: Scrollbar(
                controller: _content,
                child: SingleChildScrollView(
                  controller: _content,
                  padding: const EdgeInsets.fromLTRB(24, 6, 24, 12),
                  child: AnimatedSwitcher(
                    duration: calm ? Duration.zero : const Duration(milliseconds: 180),
                    child: KeyedSubtree(key: ValueKey(tab), child: _pane(tab)),
                  ),
                ),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _pane(SettingsTab tab) => switch (tab) {
    SettingsTab.general => GeneralPane(host: host),
    SettingsTab.characters => CharactersPane(host: host),
    SettingsTab.claude => ClaudeCodePane(host: host),
    SettingsTab.assistant => AssistantPane(host: host),
    SettingsTab.phones => PhonesPane(host: host),
    SettingsTab.agent => AgentPane(host: host),
    SettingsTab.notifications => NotificationsPane(host: host),
    SettingsTab.desktop => DesktopPetPane(host: host),
    SettingsTab.fun => FunPane(host: host),
    SettingsTab.privacy => PrivacyPane(host: host),
    SettingsTab.developer => DeveloperPane(host: host),
    SettingsTab.about => AboutPane(host: host),
  };
}

/// One pane in the sidebar: its icon tile and name; the open pane sits on a pill in Mochi's colour.
class _SidebarRow extends StatefulWidget {
  const _SidebarRow({required this.tab, required this.selected, required this.focusNode, required this.onTap, this.compact = false});

  final SettingsTab tab;
  final bool selected;
  final FocusNode focusNode;
  final VoidCallback onTap;

  /// Icon only (narrow windows).
  final bool compact;

  @override
  State<_SidebarRow> createState() => _SidebarRowState();
}

class _SidebarRowState extends State<_SidebarRow> {
  bool _hovering = false;
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final selected = widget.selected;
    final radius = BorderRadius.circular(11);
    final decoration = BoxDecoration(
      borderRadius: radius,
      gradient: selected
          ? LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [Color.lerp(p.tint, Colors.white, 0.12)!, p.tint])
          : null,
      color: selected ? null : (_hovering ? p.ink.withValues(alpha: 0.06) : null),
      boxShadow: selected ? [BoxShadow(color: p.tint.withValues(alpha: 0.30), blurRadius: 6, offset: const Offset(0, 2))] : null,
      border: _focused ? Border.all(color: p.focus, width: 2, strokeAlign: BorderSide.strokeAlignOutside) : null,
    );
    final row = AnimatedContainer(
      duration: MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 150),
      margin: const EdgeInsets.symmetric(vertical: 1),
      padding: widget.compact ? const EdgeInsets.all(8) : const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: decoration,
      child: widget.compact
          ? Center(child: SettingsIcon.of(widget.tab, size: 28))
          : Row(
              children: [
                SettingsIcon.of(widget.tab, size: 24),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    widget.tab.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: context.type.subheadline.copyWith(
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: selected ? p.onTint : p.ink,
                    ),
                  ),
                ),
              ],
            ),
    );
    return Semantics(
      button: true,
      selected: selected,
      label: widget.tab.title,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: FocusableActionDetector(
        focusNode: widget.focusNode,
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (hovering) => setState(() => _hovering = hovering),
        onShowFocusHighlight: (focused) => setState(() => _focused = focused),
        shortcuts: const {
          SingleActivator(LogicalKeyboardKey.enter): ActivateIntent(),
          SingleActivator(LogicalKeyboardKey.space): ActivateIntent(),
        },
        actions: {ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) => widget.onTap())},
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: widget.compact ? Tooltip(message: widget.tab.title, child: row) : row,
        ),
      ),
    );
  }
}

/// The card at the top of the sidebar: your pet, as it looks today. Click it for Characters.
class _PetCard extends StatelessWidget {
  const _PetCard({required this.host});

  final SettingsHost host;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final settings = host.desktop.settings;
    return Tooltip(
      message: 'Change how ${host.pet} looks',
      child: ClayPress(
        onTap: () => host.open(SettingsTab.characters),
        semanticLabel: '${host.pet}, with ${host.companion}. Change how ${host.pet} looks',
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            color: p.ink.withValues(alpha: 0.05),
            border: Border.all(color: p.ink.withValues(alpha: 0.06)),
          ),
          child: Row(
            children: [
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(shape: BoxShape.circle, color: SettingsTab.about.tint.withValues(alpha: 0.22)),
                child: PetPreview(settings: settings, now: host.now, library: host.library, fill: 0.9, bottomInset: 2),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(host.pet, style: context.type.headline, maxLines: 1, overflow: TextOverflow.ellipsis),
                    Text('with ${host.companion}', style: context.type.caption, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// A floating card: rounded, frosted over the backdrop, with a light rim and a soft shadow (the Mac's settingsCard).
class GlassCard extends StatelessWidget {
  const GlassCard({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    const radius = BorderRadius.all(Radius.circular(22));
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: p.isDark ? 0.35 : 0.10), blurRadius: 18, offset: const Offset(0, 6))],
      ),
      child: ClipRRect(
        borderRadius: radius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: p.surface.withValues(alpha: p.isDark ? 0.78 : 0.80),
              borderRadius: radius,
              border: Border.all(color: p.isDark ? Colors.white.withValues(alpha: 0.08) : Colors.white.withValues(alpha: 0.75)),
            ),
            child: Material(type: MaterialType.transparency, child: child),
          ),
        ),
      ),
    );
  }
}

/// The window's backdrop behind the cards: a calm warm base with two soft glows in the open pane's colours.
class SettingsBackdrop extends StatelessWidget {
  const SettingsBackdrop({super.key, required this.tab, required this.child});

  final SettingsTab tab;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final p = context.palette;
    final (first, second) = tab.glow;
    final strength = p.isDark ? 1.0 : 0.6;
    final duration = MediaQuery.disableAnimationsOf(context) ? Duration.zero : const Duration(milliseconds: 450);
    Widget glow(Alignment centre, double radius, Color color) => Positioned.fill(
      child: AnimatedContainer(
        duration: duration,
        decoration: BoxDecoration(
          gradient: RadialGradient(center: centre, radius: radius, colors: [color, color.withValues(alpha: 0)]),
        ),
      ),
    );
    return Stack(
      children: [
        Positioned.fill(child: ColoredBox(color: p.isDark ? const Color(0xFF15110E) : const Color(0xFFF2EBE5))),
        glow(const Alignment(0.6, -0.8), 1.0, first.withValues(alpha: 0.42 * strength)),
        glow(const Alignment(-0.7, 0.8), 0.95, second.withValues(alpha: 0.30 * strength)),
        child,
      ],
    );
  }
}
