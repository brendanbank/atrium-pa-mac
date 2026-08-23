import AppKit

/// The menu bar every ordinary Mac app has, built in code.
///
/// A SwiftPM executable has no nib, so nothing supplies the App, Edit
/// and Window menus that AppKit otherwise gets for free — and their
/// absence is not cosmetic. Without the App menu there is no ⌘Q; without
/// the Edit menu, ⌘C and ⌘V do nothing in a text field, which matters
/// the moment there is a field for typing somebody's name into.
enum MainMenu {

    static func install(appName: String) {
        let main = NSMenu()

        // App menu. The title is ignored — macOS always shows the
        // process name in bold here — but the items are not.
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(
            withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        // ⌘, in the App menu, which is where every Mac user looks for
        // it. The item is filled in by the delegate — this only owns the
        // slot, for the same reason the Capture menu does.
        let settings = appMenu.addItem(
            withTitle: "Settings…", action: nil, keyEquivalent: ",")
        settings.identifier = NSUserInterfaceItemIdentifier("settings")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)),
            keyEquivalent: "h")
        let hideOthers = appMenu.addItem(
            withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)),
            keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(
            withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)),
            keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Edit. Copy and paste in a text field are AppKit responder
        // actions; they only work if something in the menu bar claims
        // the key equivalents.
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = editMenu.addItem(
            withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Minimise", action: #selector(NSWindow.performMiniaturize(_:)),
            keyEquivalent: "m")
        windowMenu.addItem(
            withTitle: "Close", action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w")
        windowItem.submenu = windowMenu
        main.addItem(windowItem)

        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    /// Insert an empty **Capture** menu after the App menu and hand it
    /// back for the delegate to fill.
    ///
    /// Empty on purpose: every entry in it depends on what is happening
    /// right now — what is recording, what is queued, whether we are
    /// signed in — so `AppDelegate.refreshMenu()` owns the contents and
    /// this owns only the slot. The alternative was a menu bar that says
    /// "Start Recording" while a recording is running.
    /// The App menu's **Settings…** item, so the delegate can point it
    /// at itself once it exists.
    static func settingsItem() -> NSMenuItem? {
        NSApp.mainMenu?.items.first?.submenu?.items.first {
            $0.identifier?.rawValue == "settings"
        }
    }

    static func installCaptureMenu() -> NSMenuItem {
        let item = NSMenuItem()
        item.title = "Capture"
        item.submenu = NSMenu(title: "Capture")
        // After the App menu, before Edit: it is what this application
        // is for, so it goes where a document app puts File.
        NSApp.mainMenu?.insertItem(item, at: 1)
        return item
    }
}
