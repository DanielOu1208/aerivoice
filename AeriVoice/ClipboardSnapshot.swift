import AppKit

/// An all-or-nothing, eagerly materialized copy. No AppKit objects cross workers.
struct ClipboardSnapshot: Sendable, Equatable {
  struct Representation: Sendable, Equatable {
    let type: String
    let data: Data
  }

  struct Item: Sendable, Equatable {
    let representations: [Representation]
  }

  struct Limits: Sendable {
    var maximumBytes = 64 * 1024 * 1024
    var maximumItems = 128
    var maximumRepresentations = 1024
  }

  let changeCount: Int
  let items: [Item]

  /// Providers may block while producing data; callers must bound worker concurrency.
  static func capture(
    from board: NSPasteboard, expectedChangeCount: Int, limits: Limits = .init()
  ) -> ClipboardSnapshot? {
    capture(
      expectedChangeCount: expectedChangeCount, limits: limits,
      changeCount: { board.changeCount }, items: { board.pasteboardItems },
      types: { $0.types.map(\.rawValue) },
      data: { $0.data(forType: .init($1)) })
  }

  /// The same read algorithm with injectable providers, including unavailable data.
  static func capture<SourceItem>(
    expectedChangeCount: Int, limits: Limits = .init(), changeCount: () -> Int,
    items sourceItems: () -> [SourceItem]?, types: (SourceItem) -> [String],
    data: (SourceItem, String) -> Data?
  ) -> ClipboardSnapshot? {
    guard limits.maximumBytes >= 0, limits.maximumItems >= 0,
      limits.maximumRepresentations >= 0, changeCount() == expectedChangeCount,
      let sourceItems = sourceItems(), sourceItems.count <= limits.maximumItems,
      changeCount() == expectedChangeCount
    else { return nil }

    var items: [Item] = []
    var bytes = 0
    var representations = 0
    for sourceItem in sourceItems {
      guard changeCount() == expectedChangeCount else { return nil }
      let advertisedTypes = types(sourceItem)
      guard changeCount() == expectedChangeCount,
        advertisedTypes.count <= limits.maximumRepresentations - representations
      else { return nil }
      representations += advertisedTypes.count
      var values: [Representation] = []
      for type in advertisedTypes {
        guard changeCount() == expectedChangeCount,
          let value = data(sourceItem, type), changeCount() == expectedChangeCount,
          value.count <= limits.maximumBytes - bytes
        else { return nil }
        bytes += value.count
        values.append(Representation(type: type, data: value))
      }
      items.append(Item(representations: values))
    }
    guard changeCount() == expectedChangeCount else { return nil }
    return ClipboardSnapshot(changeCount: expectedChangeCount, items: items)
  }

  @MainActor
  func restore(
    to board: NSPasteboard, markerType: NSPasteboard.PasteboardType, marker: String,
    ownedChangeCount: Int, dictation: String
  ) -> ClipboardRestoreWriteResult {
    restore(
      to: board, markerType: markerType, marker: marker, ownedChangeCount: ownedChangeCount,
      dictation: dictation, write: { board.writeObjects($0) })
  }

  @MainActor
  func restore(
    to board: NSPasteboard, markerType: NSPasteboard.PasteboardType, marker: String,
    ownedChangeCount: Int, dictation: String,
    write: ([NSPasteboardItem]) -> Bool
  ) -> ClipboardRestoreWriteResult {
    var restoredItems: [NSPasteboardItem] = []
    for savedItem in items {
      let item = NSPasteboardItem()
      for representation in savedItem.representations {
        guard item.setData(representation.data, forType: .init(representation.type)) else {
          return .failed
        }
      }
      restoredItems.append(item)
    }
    let fallback = NSPasteboardItem()
    guard fallback.setString(dictation, forType: .string),
      fallback.setString(marker, forType: markerType)
    else { return .failed }

    // Check count around the marker read, immediately before the first mutation.
    guard board.changeCount == ownedChangeCount,
      board.string(forType: markerType) == marker, board.changeCount == ownedChangeCount
    else { return .superseded }

    let clearedChangeCount = board.clearContents()
    if restoredItems.isEmpty { return .restored }
    guard board.changeCount == clearedChangeCount else { return .superseded }
    if write(restoredItems) { return .restored }

    // A failed write can partially publish or race another owner. Only our exact,
    // still-empty clear may receive the fallback, without another clear or retry.
    if board.changeCount == clearedChangeCount,
      let remaining = board.pasteboardItems, remaining.isEmpty,
      board.changeCount == clearedChangeCount
    {
      _ = write([fallback])
    }
    return .failed
  }
}

enum ClipboardRestoreWriteResult: Sendable, Equatable {
  case restored
  case superseded
  case failed
}
