import CochleaCore
import Foundation

/// Picks the transcriber the app will run with, and says why when there isn't one.
///
/// The two things that can be missing — the `dictate` helper and the model —
/// fail differently and have different fixes, so they are reported separately
/// rather than as one "ASR unavailable". Neither is an error at launch: the
/// app still runs, the hotkey still works, and the failure surfaces when the
/// user asks for a transcription. Invariant 8 also means nothing here may
/// trigger a permission prompt.
public enum TranscriberFactory {

    public static func make(configuration: Configuration) -> Transcriber {
        let modelDirectory = configuration.modelsDirectory
            .appendingPathComponent(configuration.modelIdentifier, isDirectory: true)

        guard let executable = SidecarTranscriber.locateExecutable() else {
            return UnavailableTranscriber(reason:
                "cochlea's speech recognition runs in a helper process (D5) and "
              + "`dictate` was not found. Install it with `brew install cochlea`, "
              + "or set COCHLEA_DICTATE to its path.")
        }
        guard FileManager.default.fileExists(atPath: modelDirectory.path) else {
            return UnavailableTranscriber(reason:
                "no model at \(modelDirectory.path). cochlea ships no weights "
              + "(F21); the first-run download installs and verifies them.")
        }
        return SidecarTranscriber(executable: executable,
                                  modelDirectory: modelDirectory,
                                  identifier: configuration.modelIdentifier,
                                  language: configuration.language)
    }
}
