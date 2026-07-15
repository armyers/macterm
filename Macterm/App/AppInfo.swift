import Foundation

/// The running app's bundle identifier — `com.thdxg.cyotearm.debug` in debug
/// builds, `com.thdxg.cyotearm` in release (see `project.yml`). Used as the
/// os.Logger subsystem so the two builds log to distinct subsystems
/// (`scripts/logs.sh`). Falls back to the release ID in non-bundle contexts
/// (e.g. unit tests).
let appBundleID = Bundle.main.bundleIdentifier ?? "com.thdxg.cyotearm"

/// The running app's display name — "CYOTE-arm Debug" in debug builds,
/// "CYOTE-arm" in release (`PRODUCT_DISPLAY_NAME` in `project.yml` →
/// `CFBundleDisplayName`). Used wherever the app refers to itself by name — the
/// Application Support directory, window titles, dialogs — so the debug build
/// keeps its own identity and data, mirroring the bundle-ID split above. Falls
/// back to the release name in non-bundle contexts (e.g. unit tests).
let appDisplayName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String ?? "CYOTE-arm"
