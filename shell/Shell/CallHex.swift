import AppIntents

/// "Call hex" to Siri, a Shortcut or the Action button: opens the app and starts the call.
struct CallHex: AppIntent {
  static let title: LocalizedStringResource = "Call hex"
  static let description = IntentDescription("Starts a voice call with hex.")
  static let openAppWhenRun = true

  @MainActor
  func perform() async throws -> some IntentResult {
    Call.shared.start()
    return .result()
  }
}

struct Shortcuts: AppShortcutsProvider {
  static var appShortcuts: [AppShortcut] {
    AppShortcut(
      intent: CallHex(),
      phrases: ["Call hex in \(.applicationName)", "Start a \(.applicationName) call"],
      shortTitle: "Call hex",
      systemImageName: "phone.fill")
  }
}
