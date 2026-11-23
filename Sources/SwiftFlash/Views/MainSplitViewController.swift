import AppKit
import Combine
import SwiftUI

// MARK: - Passthrough Hosting View for Workspace Overlays

final class WorkspaceOverlayContainerView<Content: View>: NSHostingView<Content> {
    weak var workspace: WorkspaceState?

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let workspace, workspace.activeOverlay != .none else {
            return nil
        }
        return super.hitTest(point)
    }
}

// MARK: - Vertical Split (Editor Top + Terminal Bottom)

@MainActor
final class EditorTerminalSplitController: NSSplitViewController {
    let workspace: WorkspaceState
    let terminalSession: TerminalSession
    private var terminalSplitItem: NSSplitViewItem!

    init(workspace: WorkspaceState) {
        self.workspace = workspace
        self.terminalSession = TerminalSession(workingDirectory: workspace.rootURL)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = false
        splitView.dividerStyle = .thin

        let editorVC = NSHostingController(rootView: EditorWorkspaceView(workspace: workspace))
        editorVC.safeAreaRegions = []
        let editorItem = NSSplitViewItem(viewController: editorVC)
        editorItem.minimumThickness = 220
        editorItem.holdingPriority = NSLayoutConstraint.Priority(200)

        let terminalVC = NSHostingController(
            rootView: IntegratedTerminalView(workspace: workspace, session: terminalSession)
        )
        terminalVC.safeAreaRegions = []
        terminalSplitItem = NSSplitViewItem(viewController: terminalVC)
        terminalSplitItem.canCollapse = true
        terminalSplitItem.minimumThickness = 140
        terminalSplitItem.maximumThickness = 460
        terminalSplitItem.holdingPriority = NSLayoutConstraint.Priority(260)
        terminalSplitItem.isCollapsed = !workspace.isTerminalVisible

        addSplitViewItem(editorItem)
        addSplitViewItem(terminalSplitItem)
    }

    func toggleTerminal() {
        let shouldCollapse = !terminalSplitItem.isCollapsed
        terminalSplitItem.animator().isCollapsed = shouldCollapse
        workspace.isTerminalVisible = !shouldCollapse
        if shouldCollapse {
            workspace.onFocusEditorRequested?()
        }
    }
}

// MARK: - Horizontal Split (Sidebar Left + Editor/Terminal Right)

@MainActor
final class MainSplitViewController: NSSplitViewController {
    let workspace: WorkspaceState
    private var sidebarItem: NSSplitViewItem!
    private var rightSplitController: EditorTerminalSplitController!

    init(workspace: WorkspaceState) {
        self.workspace = workspace
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        splitView.isVertical = true
        splitView.dividerStyle = .thin

        let sidebarVC = NSHostingController(rootView: SidebarView(workspace: workspace))
        sidebarVC.safeAreaRegions = []
        sidebarItem = NSSplitViewItem(viewController: sidebarVC)
        sidebarItem.canCollapse = true
        sidebarItem.minimumThickness = 280
        sidebarItem.maximumThickness = 480
        sidebarItem.holdingPriority = NSLayoutConstraint.Priority(260)
        sidebarItem.isCollapsed = !workspace.isSidebarVisible

        rightSplitController = EditorTerminalSplitController(workspace: workspace)
        let rightItem = NSSplitViewItem(viewController: rightSplitController)
        rightItem.minimumThickness = 420
        rightItem.holdingPriority = NSLayoutConstraint.Priority(200)

        addSplitViewItem(sidebarItem)
        addSplitViewItem(rightItem)

        workspace.onToggleSidebarAction = { [weak self] in
            self?.toggleSidebar()
        }
        workspace.onSelectSidebarModeAction = { [weak self] mode in
            self?.selectOrToggleSidebar(mode: mode)
        }
        workspace.onToggleTerminalAction = { [weak self] in
            self?.toggleTerminal()
        }
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        if splitView.arrangedSubviews.count > 1 {
            splitView.setPosition(310, ofDividerAt: 0)
        }
        if rightSplitController.splitView.arrangedSubviews.count > 1 {
            let totalH = rightSplitController.view.bounds.height
            if totalH > 360 {
                rightSplitController.splitView.setPosition(totalH - 210, ofDividerAt: 0)
            }
        }
    }

    func toggleSidebar() {
        let shouldCollapse = !sidebarItem.isCollapsed
        sidebarItem.animator().isCollapsed = shouldCollapse
        workspace.isSidebarVisible = !shouldCollapse
    }

    func ensureSidebarVisible(mode: SidebarMode) {
        workspace.sidebarMode = mode
        if sidebarItem.isCollapsed {
            sidebarItem.animator().isCollapsed = false
            workspace.isSidebarVisible = true
        }
        if mode == .git {
            workspace.refreshGitMetadata()
        }
    }

    func selectOrToggleSidebar(mode: SidebarMode) {
        if !sidebarItem.isCollapsed && workspace.sidebarMode == mode {
            sidebarItem.animator().isCollapsed = true
            workspace.isSidebarVisible = false
        } else {
            workspace.sidebarMode = mode
            if sidebarItem.isCollapsed {
                sidebarItem.animator().isCollapsed = false
                workspace.isSidebarVisible = true
            }
            if mode == .git {
                workspace.refreshGitMetadata()
            }
        }
    }

    func toggleTerminal() {
        rightSplitController.toggleTerminal()
    }
}

// MARK: - Root Window Content Controller (Header + SplitView + Overlays)

@MainActor
final class RootIDEViewController: NSViewController {
    let workspace: WorkspaceState
    let mainSplitController: MainSplitViewController
    private var topHeaderView: NSHostingView<ZedTopHeaderBarView>!
    private var statusBarView: NSHostingView<StatusBarView>!
    private var overlayContainer: WorkspaceOverlayContainerView<WorkspaceOverlayHostView>!
    private var themeCancellable: AnyCancellable?

    init(workspace: WorkspaceState) {
        self.workspace = workspace
        self.mainSplitController = MainSplitViewController(workspace: workspace)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 1320, height: 840))
        container.wantsLayer = true
        container.layer?.backgroundColor = ZedTheme.background.cgColor
        self.view = container
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        topHeaderView = NSHostingView(rootView: ZedTopHeaderBarView(workspace: workspace))
        topHeaderView.safeAreaRegions = []
        topHeaderView.translatesAutoresizingMaskIntoConstraints = false
        topHeaderView.clipsToBounds = true
        view.addSubview(topHeaderView)

        addChild(mainSplitController)
        let splitView = mainSplitController.view
        splitView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(splitView)

        statusBarView = NSHostingView(rootView: StatusBarView(workspace: workspace))
        statusBarView.safeAreaRegions = []
        statusBarView.translatesAutoresizingMaskIntoConstraints = false
        statusBarView.clipsToBounds = true
        view.addSubview(statusBarView)

        overlayContainer = WorkspaceOverlayContainerView(
            rootView: WorkspaceOverlayHostView(workspace: workspace)
        )
        overlayContainer.safeAreaRegions = []
        overlayContainer.workspace = workspace
        overlayContainer.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(overlayContainer)

        NSLayoutConstraint.activate([
            topHeaderView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            topHeaderView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            topHeaderView.topAnchor.constraint(equalTo: view.topAnchor),
            topHeaderView.heightAnchor.constraint(equalToConstant: 38),

            splitView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            splitView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            splitView.topAnchor.constraint(equalTo: topHeaderView.bottomAnchor),
            splitView.bottomAnchor.constraint(equalTo: statusBarView.topAnchor),

            statusBarView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            statusBarView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            statusBarView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            statusBarView.heightAnchor.constraint(equalToConstant: 28),

            overlayContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            overlayContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            overlayContainer.topAnchor.constraint(equalTo: view.topAnchor),
            overlayContainer.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])

        themeCancellable = ThemeManager.shared.$currentThemeID.sink { [weak self] _ in
            self?.view.layer?.backgroundColor = ZedTheme.background.cgColor
        }
    }
}
