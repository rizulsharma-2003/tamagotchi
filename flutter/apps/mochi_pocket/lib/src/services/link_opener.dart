import 'package:mochi_link/mochi_link.dart';
import 'package:url_launcher/url_launcher.dart';

/// Where tapping an update goes (iOS/MochiPocket/OpenLinks.swift): mail in the Gmail app when it's installed and
/// takes the link, meetings in Meet, Zoom or Teams, pages in Notion, else the browser.
abstract interface class LinkOpener {
  /// The note's link in the app that owns it, else in the browser. False when there's nothing to open.
  Future<bool> open(AgentNote note);

  /// The note's link in the browser (the exact email, where the Gmail app would open the inbox).
  Future<bool> openInBrowser(AgentNote note);
}

class UrlLinkOpener implements LinkOpener {
  const UrlLinkOpener();

  @override
  Future<bool> open(AgentNote note) async {
    final uri = _uri(note);
    if (uri == null) return false;
    try {
      // An app that handles the link (Gmail for mail.google.com, Meet, Zoom, Notion), without a browser in between.
      if (await launchUrl(uri, mode: LaunchMode.externalNonBrowserApplication)) return true;
    } on Object {
      // No app claims it: the browser below.
    }
    return openInBrowser(note);
  }

  @override
  Future<bool> openInBrowser(AgentNote note) async {
    final uri = _uri(note);
    if (uri == null) return false;
    try {
      return await launchUrl(uri, mode: LaunchMode.externalApplication);
    } on Object {
      return false;
    }
  }

  /// Only web links: a note's link comes from your mail and calendar, so nothing else is opened.
  static Uri? _uri(AgentNote note) {
    final uri = Uri.tryParse(note.link ?? '');
    return uri != null && (uri.scheme == 'https' || uri.scheme == 'http') ? uri : null;
  }
}
