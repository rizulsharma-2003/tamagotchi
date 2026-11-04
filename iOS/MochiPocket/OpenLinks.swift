import TamagotchiCore
import UIKit

/// Where tapping an update goes: mail opens in the Gmail app when it's installed (the browser otherwise),
/// meetings in Meet, Zoom or Teams and pages in Notion when those apps are installed.
@MainActor
enum OpenLinks {
    static func open(_ note: AgentNote) {
        let web = note.link.flatMap(URL.init(string:))
        if let thread = note.threadID {
            openGmail(thread: thread, fallback: web)
        } else if let web {
            openApp(web)
        }
    }

    /// The Gmail app (at your inbox, where new mail sits at the top), or the web link if Gmail isn't installed.
    /// Gmail for iPhone no longer opens one particular email from a link (its old `cv=` form now shows
    /// "failed to open link"), so the exact email is "Open This Email in Safari" in the long-press menu.
    static func openGmail(thread: String, fallback: URL?) {
        guard let app = URL(string: "googlegmail://") else { return }
        UIApplication.shared.open(app) { opened in
            if !opened, let fallback { UIApplication.shared.open(fallback) }
        }
    }

    /// The exact email (or page) in Safari.
    static func openInBrowser(_ note: AgentNote) {
        guard let link = note.link, let url = URL(string: link) else { return }
        UIApplication.shared.open(url)
    }

    /// An https link in the app that owns it, else in the browser.
    static func openApp(_ url: URL) {
        UIApplication.shared.open(url, options: [.universalLinksOnly: true]) { opened in
            if !opened { UIApplication.shared.open(url) }
        }
    }
}
