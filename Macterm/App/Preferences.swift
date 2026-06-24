import AppKit
import Foundation
import Observation

/// When the numbered tab switcher in the title bar is shown.
enum TabSwitcherVisibility: String, CaseIterable, Identifiable {
    case always
    case whenMultiple = "when_multiple"
    case hidden

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .always: "Always"
        case .whenMultiple: "When multiple tabs"
        case .hidden: "Hidden"
        }
    }
}

/// Which `NSGlassEffectView.Style` the liquid-glass window background uses.
/// Maps to AppKit's `.regular` / `.clear` (see `WindowAppearance`).
enum WindowGlassStyle: String, CaseIterable, Identifiable {
    case regular
    case clear

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .regular: "Regular"
        case .clear: "Clear"
        }
    }
}

/// How the project/context sidebar's visibility is decided at launch.
enum SidebarStartupBehavior: String, CaseIterable, Identifiable {
    case visible
    case hidden
    case resumeLast = "resume_last"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .visible: "Visible on startup"
        case .hidden: "Hidden on startup"
        case .resumeLast: "Resume last state"
        }
    }
}

/// Single observable source of truth for UserDefaults-backed preferences.
///
/// Macterm only stores app-shaped state here (window opacity/blur, quick
/// terminal, hotkeys, etc.). Anything that's a ghostty config setting lives
/// in the user's Ghostty config instead — see `MactermConfig` for the wrapper
/// files Macterm generates around it.
@MainActor @Observable
final class Preferences {
    static let shared = Preferences()

    // MARK: - Layout / appearance

    var autoTilingEnabled: Bool {
        didSet {
            defaults.set(autoTilingEnabled, forKey: Keys.autoTiling)
            // Legacy notification — listeners predate Preferences.
            NotificationCenter.default.post(name: .autoTilingEnabledDidChange, object: nil)
        }
    }

    /// Start every tab of the focused project immediately (off-screen) rather
    /// than only the active tab. Defaults to on.
    var eagerlyStartProjectTabs: Bool {
        didSet { defaults.set(eagerlyStartProjectTabs, forKey: Keys.eagerlyStartProjectTabs) }
    }

    /// Restore each pane's running command/shell across restarts. Off by default
    /// (today's behavior: panes restore as plain shells). When on, the live
    /// foreground command is captured at save and re-launched on relaunch; with
    /// zmx installed it upgrades to true live-process reattach (see ZmxService).
    var sessionPersistenceEnabled: Bool {
        didSet { defaults.set(sessionPersistenceEnabled, forKey: Keys.sessionPersistenceEnabled) }
    }

    /// Replay each zmx-backed pane's color scrollback after a reboot (the
    /// tmux-resurrect path). On by default. When off, a rebooted pane still
    /// re-runs its restartable command (and reattaches live across an app quit) —
    /// it just doesn't replay prior scrollback. No effect without session
    /// persistence + zmx.
    var scrollbackResurrectionEnabled: Bool {
        didSet { defaults.set(scrollbackResurrectionEnabled, forKey: Keys.scrollbackResurrectionEnabled) }
    }

    /// How much scrollback to capture and replay per pane on reboot, in MB
    /// (byte-capped, most-recent tail). Bounded so replay stays quick; the
    /// destination pane's own `scrollback-limit` caps what ultimately stays
    /// visible. Clamped to a sane range on read.
    var scrollbackRestoreMB: Double {
        didSet { defaults.set(scrollbackRestoreMB, forKey: Keys.scrollbackRestoreMB) }
    }

    /// Explicit path to the `zmx` binary, for installs outside the built-in
    /// search list. Empty = auto-detect from the standard locations.
    var zmxPathOverride: String {
        didSet { defaults.set(zmxPathOverride, forKey: Keys.zmxPathOverride) }
    }

    // MARK: - Panes

    /// Draw the accent border around the focused pane when a tab is split
    /// (zellij-style). On by default.
    var paneHighlightBorderEnabled: Bool {
        didSet { defaults.set(paneHighlightBorderEnabled, forKey: Keys.paneHighlightBorderEnabled) }
    }

    /// How much to dim inactive panes in a split, 0 (none) to 0.9. Clamped on
    /// read. Default 0.45.
    var inactivePaneDimming: Double {
        didSet { defaults.set(inactivePaneDimming, forKey: Keys.inactivePaneDimming) }
    }

    /// Warp the mouse cursor to the center of the newly-active pane when pane
    /// focus changes. macOS routes scroll-wheel events to the pane under the
    /// cursor, so without this an evenly-split layout won't scroll the focused
    /// pane until the mouse is moved onto it. On by default.
    var warpCursorToActivePaneEnabled: Bool {
        didSet { defaults.set(warpCursorToActivePaneEnabled, forKey: Keys.warpCursorToActivePaneEnabled) }
    }

    // MARK: - Sidebar icons

    var projectIconSymbol: String {
        didSet { defaults.set(projectIconSymbol, forKey: Keys.projectIconSymbol) }
    }

    var tabIconSymbol: String {
        didSet { defaults.set(tabIconSymbol, forKey: Keys.tabIconSymbol) }
    }

    /// Show a status badge over each tab icon: a spinner while a command is
    /// running (replacing the icon) and a small status dot when a command has
    /// finished and awaits attention. Off = pure icons, no status tracking.
    var showTabStatusIndicator: Bool {
        didSet { defaults.set(showTabStatusIndicator, forKey: Keys.showTabStatusIndicator) }
    }

    var showNewProjectButton: Bool {
        didSet { defaults.set(showNewProjectButton, forKey: Keys.showNewProjectButton) }
    }

    /// Last live sidebar visibility, persisted on every toggle. `AppState
    /// .sidebarVisible` mirrors this; it's the value restored when
    /// `sidebarStartupBehavior` is `.resumeLast`.
    var sidebarVisible: Bool {
        didSet { defaults.set(sidebarVisible, forKey: Keys.sidebarVisible) }
    }

    /// How the sidebar's visibility is decided at launch. Defaults to `.visible`
    /// so the project/context bar is discoverable out of the box.
    var sidebarStartupBehavior: SidebarStartupBehavior {
        didSet { defaults.set(sidebarStartupBehavior.rawValue, forKey: Keys.sidebarStartupBehavior) }
    }

    /// The sidebar visibility to apply at launch, per `sidebarStartupBehavior`:
    /// always-visible, always-hidden, or the persisted last state.
    var initialSidebarVisible: Bool {
        switch sidebarStartupBehavior {
        case .visible: true
        case .hidden: false
        case .resumeLast: sidebarVisible
        }
    }

    // MARK: - Toolbar

    var tabSwitcherVisibility: TabSwitcherVisibility {
        didSet { defaults.set(tabSwitcherVisibility.rawValue, forKey: Keys.tabSwitcherVisibility) }
    }

    /// Sentinel for "no icon" — sidebar rows skip the leading glyph when set.
    static let noIcon = "none"
    /// Sentinels for "show 1-based top-down position" — sidebar rows render a number glyph.
    /// Each variant picks a different SF Symbols container (or plain text) around the digit.
    static let numberIconCircleFill = "number.circle.fill"
    static let numberIconCircle = "number.circle"
    static let numberIconSquareFill = "number.square.fill"
    static let numberIconSquare = "number.square"
    static let numberIconPlain = "number.plain"

    static let numberIconChoices: Set<String> = [
        numberIconCircleFill,
        numberIconCircle,
        numberIconSquareFill,
        numberIconSquare,
        numberIconPlain,
    ]

    /// Curated SF Symbols offered in Settings — keeps users from typing invalid names.
    static let projectIconChoices: [String] = [
        noIcon,
        numberIconCircleFill,
        numberIconCircle,
        numberIconSquareFill,
        numberIconSquare,
        numberIconPlain,
        "folder",
        "folder.fill",
        "briefcase",
        "shippingbox",
        "cube",
        "hammer",
    ]
    static let tabIconChoices: [String] = [
        noIcon,
        numberIconCircleFill,
        numberIconCircle,
        numberIconSquareFill,
        numberIconSquare,
        numberIconPlain,
        "terminal",
        "chevron.right",
        "chevron.compact.right",
        "circle.fill",
        "circle",
        "command",
    ]

    // MARK: - Window

    /// Macterm-painted window background opacity (0–1). Independent from
    /// ghostty's renderer — `macterm-overrides.conf` pins `background-opacity
    /// = 0` so ghostty draws fully transparent, then Macterm composites this
    /// translucency at the window level. Avoids the double-paint problem when
    /// both layers tint.
    var windowOpacity: Double {
        didSet {
            defaults.set(windowOpacity, forKey: Keys.windowOpacity)
            notifyConfigChanged()
        }
    }

    /// CGSSetWindowBackgroundBlurRadius value (0–100). 0 = no blur.
    var windowBlurRadius: Int {
        didSet {
            defaults.set(windowBlurRadius, forKey: Keys.windowBlurRadius)
            notifyConfigChanged()
        }
    }

    /// Use the macOS 26 liquid-glass material (`NSGlassEffectView`) for the
    /// translucent window background instead of the legacy CGS Gaussian blur.
    /// Only has any effect when `windowOpacity < 1` — at full opacity the
    /// window is solid and neither blur nor glass is visible. When enabled the
    /// `windowBlurRadius` slider is ignored; the glass material defines its own
    /// look.
    var windowGlassEnabled: Bool {
        didSet {
            defaults.set(windowGlassEnabled, forKey: Keys.windowGlassEnabled)
            notifyConfigChanged()
        }
    }

    /// Which liquid-glass material to use when `windowGlassEnabled` is on.
    /// `.regular` is frostier/more tinted; `.clear` is more transparent. No
    /// effect unless glass is enabled.
    var windowGlassStyle: WindowGlassStyle {
        didSet {
            defaults.set(windowGlassStyle.rawValue, forKey: Keys.windowGlassStyle)
            notifyConfigChanged()
        }
    }

    // MARK: - Ghostty config

    /// Path to the user's Ghostty config. Empty string = don't load any user
    /// config (Macterm-defaults only). Tilde-expand via
    /// `expandedUserGhosttyConfigPath` at use sites.
    ///
    /// Note: this setter does NOT auto-reload, intentionally. Settings UI is
    /// the only writer and it calls `GhosttyApp.shared.reloadConfig()`
    /// directly so it can surface any errors (missing file, parse errors)
    /// in an alert. Other reloads happen silently.
    var userGhosttyConfigPath: String {
        didSet {
            defaults.set(userGhosttyConfigPath, forKey: Keys.userGhosttyConfigPath)
        }
    }

    /// `userGhosttyConfigPath` with leading `~` expanded to the home dir.
    /// Empty when the user has disabled loading by clearing the field.
    var expandedUserGhosttyConfigPath: String {
        guard !userGhosttyConfigPath.isEmpty else { return "" }
        return (userGhosttyConfigPath as NSString).expandingTildeInPath
    }

    /// Window-level appearance + libghostty reload. Both happen on the same
    /// notification so the renderer and the window chrome stay in sync.
    private func notifyConfigChanged() {
        MactermConfig.shared.regenerate()
        GhosttyApp.shared.reloadConfig()
    }

    // MARK: - Quick terminal

    var quickTerminalEnabled: Bool {
        didSet { defaults.set(quickTerminalEnabled, forKey: Keys.quickTerminalEnabled) }
    }

    /// Fraction of screen width (0–1).
    var quickTerminalWidthFraction: Double {
        didSet { defaults.set(quickTerminalWidthFraction, forKey: Keys.quickTerminalWidth) }
    }

    /// Fraction of screen height (0–1).
    var quickTerminalHeightFraction: Double {
        didSet { defaults.set(quickTerminalHeightFraction, forKey: Keys.quickTerminalHeight) }
    }

    // MARK: - Session

    /// Persisted so the app re-opens to the last-used project on launch.
    var activeProjectID: UUID? {
        didSet { defaults.set(activeProjectID?.uuidString, forKey: Keys.activeProjectID) }
    }

    // MARK: - Init

    private let defaults: UserDefaults

    private init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        autoTilingEnabled = defaults.bool(forKey: Keys.autoTiling)
        eagerlyStartProjectTabs = (defaults.object(forKey: Keys.eagerlyStartProjectTabs) as? Bool) ?? true
        sessionPersistenceEnabled = defaults.object(forKey: Keys.sessionPersistenceEnabled) as? Bool ?? false
        scrollbackResurrectionEnabled = defaults.object(forKey: Keys.scrollbackResurrectionEnabled) as? Bool ?? true
        scrollbackRestoreMB = min(8, max(0.25, (defaults.object(forKey: Keys.scrollbackRestoreMB) as? Double) ?? 2.0))
        zmxPathOverride = defaults.string(forKey: Keys.zmxPathOverride) ?? ""
        paneHighlightBorderEnabled = defaults.object(forKey: Keys.paneHighlightBorderEnabled) as? Bool ?? true
        inactivePaneDimming = min(0.9, max(0, (defaults.object(forKey: Keys.inactivePaneDimming) as? Double) ?? 0.45))
        warpCursorToActivePaneEnabled = defaults.object(forKey: Keys.warpCursorToActivePaneEnabled) as? Bool ?? true
        windowOpacity = (defaults.object(forKey: Keys.windowOpacity) as? Double) ?? 1.0
        windowBlurRadius = defaults.integer(forKey: Keys.windowBlurRadius)
        windowGlassEnabled = defaults.object(forKey: Keys.windowGlassEnabled) as? Bool ?? false
        windowGlassStyle = (defaults.string(forKey: Keys.windowGlassStyle))
            .flatMap(WindowGlassStyle.init(rawValue:)) ?? .regular
        userGhosttyConfigPath = defaults.string(forKey: Keys.userGhosttyConfigPath) ?? "~/.config/ghostty/config"
        quickTerminalEnabled = defaults.object(forKey: Keys.quickTerminalEnabled) as? Bool ?? true
        quickTerminalWidthFraction = Self.clampFraction(defaults.double(forKey: Keys.quickTerminalWidth), fallback: 0.6)
        quickTerminalHeightFraction = Self.clampFraction(defaults.double(forKey: Keys.quickTerminalHeight), fallback: 0.5)
        activeProjectID = (defaults.string(forKey: Keys.activeProjectID)).flatMap(UUID.init)
        projectIconSymbol = defaults.string(forKey: Keys.projectIconSymbol) ?? "folder"
        tabIconSymbol = defaults.string(forKey: Keys.tabIconSymbol) ?? "terminal"
        showTabStatusIndicator = defaults.object(forKey: Keys.showTabStatusIndicator) as? Bool ?? false
        showNewProjectButton = defaults.object(forKey: Keys.showNewProjectButton) as? Bool ?? true
        sidebarVisible = defaults.object(forKey: Keys.sidebarVisible) as? Bool ?? false
        sidebarStartupBehavior = (defaults.string(forKey: Keys.sidebarStartupBehavior))
            .flatMap(SidebarStartupBehavior.init) ?? .visible
        tabSwitcherVisibility = (defaults.string(forKey: Keys.tabSwitcherVisibility))
            .flatMap(TabSwitcherVisibility.init(rawValue:)) ?? .whenMultiple
        Self.runOneTimeMigrations(defaults: defaults)
    }

    private static func clampFraction(_ v: Double, fallback: Double) -> Double {
        guard v > 0 else { return fallback }
        return max(0.2, min(1.0, v))
    }

    /// Pre-v2 builds stored theme/font/option-as-alt in UserDefaults. Those
    /// settings now live entirely in the user's Ghostty config, so the keys
    /// are dead. Drop them so `defaults read com.thdxg.macterm` is clean
    /// and there's no risk of resurrecting the old values if someone wires
    /// them back up later.
    private static func runOneTimeMigrations(defaults: UserDefaults) {
        if !defaults.bool(forKey: Keys.migrationV2GhosttyConfigOwned) {
            defaults.removeObject(forKey: "macterm.appearance.theme")
            defaults.removeObject(forKey: "macterm.appearance.fontFamily")
            defaults.removeObject(forKey: "macterm.appearance.fontSize")
            defaults.removeObject(forKey: "macterm.input.optionAsAlt")
            defaults.set(true, forKey: Keys.migrationV2GhosttyConfigOwned)
        }
    }

    // MARK: - UserDefaults keys

    enum Keys {
        static let autoTiling = "macterm.autoTiling.enabled"
        static let eagerlyStartProjectTabs = "macterm.eagerlyStartProjectTabs.enabled"
        static let sessionPersistenceEnabled = "macterm.sessionPersistence.enabled"
        static let scrollbackResurrectionEnabled = "macterm.resurrect.scrollbackEnabled"
        static let scrollbackRestoreMB = "macterm.resurrect.scrollbackMB"
        static let zmxPathOverride = "macterm.zmx.pathOverride"
        static let paneHighlightBorderEnabled = "macterm.pane.highlightBorderEnabled"
        static let inactivePaneDimming = "macterm.pane.inactiveDimming"
        static let warpCursorToActivePaneEnabled = "macterm.pane.warpCursorToActivePane"
        static let windowOpacity = "macterm.window.opacity"
        static let windowBlurRadius = "macterm.window.blurRadius"
        static let windowGlassEnabled = "macterm.window.glassEnabled"
        static let windowGlassStyle = "macterm.window.glassStyle"
        static let userGhosttyConfigPath = "macterm.ghostty.userConfigPath"
        static let quickTerminalEnabled = "macterm.quickTerminal.enabled"
        static let quickTerminalWidth = "macterm.quickTerminal.width"
        static let quickTerminalHeight = "macterm.quickTerminal.height"
        static let activeProjectID = "macterm.activeProjectID"
        static let projectIconSymbol = "macterm.sidebar.projectIcon"
        static let tabIconSymbol = "macterm.sidebar.tabIcon"
        static let showTabStatusIndicator = "macterm.sidebar.showTabStatusIndicator"
        static let showNewProjectButton = "macterm.sidebar.showNewProjectButton"
        static let sidebarVisible = "macterm.sidebar.visible"
        static let sidebarStartupBehavior = "macterm.sidebar.startupBehavior"
        static let tabSwitcherVisibility = "macterm.toolbar.tabSwitcherVisibility"
        static let migrationV2GhosttyConfigOwned = "macterm.migration.v2_ghostty_config_owned"
    }
}
