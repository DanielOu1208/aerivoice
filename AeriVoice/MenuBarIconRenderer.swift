import AppKit

@MainActor
enum MenuBarIconRenderer {
  static func image(from source: NSImage, recording: Bool) -> NSImage {
    guard recording else {
      let image = source.copy() as! NSImage
      image.isTemplate = true
      return image
    }

    // Status items can ignore contentTintColor for template images. Bake the
    // system orange into the alpha mask, then preserve it as a non-template image.
    let image = NSImage(size: source.size, flipped: false) { rect in
      source.draw(in: rect)
      NSColor.systemOrange.setFill()
      rect.fill(using: .sourceIn)
      return true
    }
    image.isTemplate = false
    return image
  }
}
