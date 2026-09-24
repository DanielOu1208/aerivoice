import Foundation

enum AppStoragePaths {
  static var applicationSupport: URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appending(path: directoryName, directoryHint: .isDirectory)
  }

  static var caches: URL {
    FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      .appending(path: cacheName, directoryHint: .isDirectory)
  }

  #if AERIVOICE_UPDATER_QA
    private static let directoryName = "AeriVoiceUpdaterQA"
    private static let cacheName = "com.danielou.AeriVoice.UpdaterQA"
  #else
    private static let directoryName = "AeriVoice"
    private static let cacheName = "com.danielou.AeriVoice"
  #endif
}
