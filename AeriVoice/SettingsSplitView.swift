import AppKit
import SwiftUI

final class SettingsSplitViewController<Sidebar: View, Detail: View>: NSSplitViewController,
  NSToolbarDelegate
{
  private let titleView: NSView?
  private let titleIdentifier = NSToolbarItem.Identifier("SettingsSectionTitle")
  private var didSetInitialWidth = false
  private let sidebarHost: NSHostingController<Sidebar>
  private let detailHost: SettingsDetailViewController<Detail>

  init(sidebar: Sidebar, detail: Detail, titleView: NSView? = nil) {
    self.titleView = titleView
    sidebarHost = NSHostingController(rootView: sidebar)
    detailHost = SettingsDetailViewController(rootView: detail)
    super.init(nibName: nil, bundle: nil)

    let sidebarItem = NSSplitViewItem(sidebarWithViewController: sidebarHost)
    sidebarItem.canCollapse = false
    sidebarItem.canCollapseFromWindowResize = false
    sidebarItem.allowsFullHeightLayout = true
    sidebarItem.minimumThickness = 180
    sidebarItem.maximumThickness = 240
    sidebarItem.holdingPriority = .defaultLow + 1
    addSplitViewItem(sidebarItem)
    addSplitViewItem(NSSplitViewItem(viewController: detailHost))
  }

  required init?(coder: NSCoder) {
    fatalError("SettingsSplitViewController is created programmatically")
  }

  override func viewDidAppear() {
    super.viewDidAppear()
    if !didSetInitialWidth, splitView.bounds.width > 0 {
      didSetInitialWidth = true
      splitView.setPosition(200, ofDividerAt: 0)
    }
  }

  func makeToolbar() -> NSToolbar {
    let toolbar = NSToolbar(identifier: "SettingsToolbar")
    toolbar.delegate = self
    toolbar.allowsUserCustomization = false
    toolbar.displayMode = .iconOnly
    return toolbar
  }

  func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.sidebarTrackingSeparator] + (titleView == nil ? [] : [titleIdentifier, .flexibleSpace])
  }

  func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
    [.sidebarTrackingSeparator] + (titleView == nil ? [] : [titleIdentifier, .flexibleSpace])
  }

  func toolbar(
    _ toolbar: NSToolbar, itemForItemIdentifier identifier: NSToolbarItem.Identifier,
    willBeInsertedIntoToolbar flag: Bool
  ) -> NSToolbarItem? {
    if identifier == .sidebarTrackingSeparator {
      return NSTrackingSeparatorToolbarItem(
        identifier: identifier, splitView: splitView, dividerIndex: 0)
    }
    guard identifier == titleIdentifier, let titleView else { return nil }
    let item = NSToolbarItem(itemIdentifier: identifier)
    item.view = titleView
    item.isBordered = false
    item.isNavigational = true
    return item
  }

  override func toggleSidebar(_ sender: Any?) {
    // Settings navigation stays available even when a responder action is sent directly.
  }

  override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
    if item.action == #selector(NSSplitViewController.toggleSidebar(_:)) { return false }
    return super.validateUserInterfaceItem(item)
  }
}

// Give scrolling pages a viewport below the toolbar instead of letting their
// content move behind the fixed section title in a full-size-content window.
private final class SettingsDetailViewController<Content: View>: NSViewController {
  private let host: NSHostingController<Content>

  init(rootView: Content) {
    host = NSHostingController(rootView: rootView)
    super.init(nibName: nil, bundle: nil)
  }

  required init?(coder: NSCoder) {
    fatalError("SettingsDetailViewController is created programmatically")
  }

  override func loadView() {
    view = NSView()
    addChild(host)
    host.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(host.view)
    NSLayoutConstraint.activate([
      host.view.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
      host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
    ])
  }
}
