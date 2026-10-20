//
//  TerminalSessionViewController.swift
//  NewTerm
//
//  Created by Adam Demasi on 10/1/18.
//  Copyright © 2018 HASHBANG Productions. All rights reserved.
//

import UIKit
import os.log
import CoreServices
import SafariServices
import SwiftUIX
import NewTermCommon

class TerminalSessionViewController: BaseTerminalSplitViewControllerChild {

	var initialCommand: String?

	override var isSplitViewResizing: Bool {
		didSet { updateIsSplitViewResizing() }
	}
	override var showsTitleView: Bool {
		didSet { updateShowsTitleView() }
	}
	override var screenSize: ScreenSize? {
		get { terminalController.screenSize }
		set { terminalController.screenSize = newValue }
	}

	private var terminalController = TerminalController()
	private var keyInput = TerminalKeyInput(frame: .zero)
	private var textView: TerminalHostingView!
	private var textViewTapGestureRecognizer: UITapGestureRecognizer!
	private var selectionGestureRecognizer: UILongPressGestureRecognizer!
	private var pinchGestureRecognizer: UIPinchGestureRecognizer!
	private var selectionWordStart = TerminalCell(row: 0, col: 0)
	private var selectionWordEnd = TerminalCell(row: 0, col: 0)
	private var pinchStartFontSize: Double = 12

	private var state = TerminalState()

	private var hudState = HUDViewState()
	private var hudView: UIHostingView<AnyView>!

	private var hasAppeared = false
	private var hasStarted = false
	private var failureError: Error?

	private var lastAutomaticScrollOffset = CGPoint.zero
	private var invertScrollToTop = false

	private var isPickingFileForUpload = false

	override init(nibName nibNameOrNil: String?, bundle nibBundleOrNil: Bundle?) {
		super.init(nibName: nibNameOrNil, bundle: nibBundleOrNil)

		terminalController.delegate = self

		do {
			try terminalController.startSubProcess()
			hasStarted = true
		} catch {
			failureError = error
		}
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	override func loadView() {
		super.loadView()

		title = .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")

		preferencesUpdated()
		textView = TerminalHostingView(state: state)

		textViewTapGestureRecognizer = UITapGestureRecognizer(target: self, action: #selector(self.handleTextViewTap(_:)))
		textViewTapGestureRecognizer.delegate = self
		textView.addGestureRecognizer(textViewTapGestureRecognizer)

		// Long press selects the word under the finger; dragging afterwards extends the selection.
		selectionGestureRecognizer = UILongPressGestureRecognizer(target: self, action: #selector(self.handleSelectionPress(_:)))
		selectionGestureRecognizer.minimumPressDuration = 0.35
		selectionGestureRecognizer.delegate = self
		textView.addGestureRecognizer(selectionGestureRecognizer)

		// Pinch to change the font size.
		pinchGestureRecognizer = UIPinchGestureRecognizer(target: self, action: #selector(self.handlePinch(_:)))
		pinchGestureRecognizer.delegate = self
		textView.addGestureRecognizer(pinchGestureRecognizer)

		state.onSelectionAction = { [weak self] action in
			self?.performSelectionAction(action)
		}

		keyInput.frame = view.bounds
		keyInput.autoresizingMask = [.flexibleWidth, .flexibleHeight]
		keyInput.textView = textView
		keyInput.terminalInputDelegate = terminalController
		keyInput.hasSelection = { [weak self] in self?.state.selection != nil }
		keyInput.copyHandler = { [weak self] in self?.performSelectionAction(.copy) }
		keyInput.selectAllHandler = { [weak self] in self?.performSelectionAction(.selectAll) }
		keyInput.pasteHandler = { [weak self] in self?.clearSelection() }
		view.addSubview(keyInput)
	}

	override func viewDidLoad() {
		super.viewDidLoad()

		hudView = UIHostingView(rootView: AnyView(
			HUDView()
				.environmentObject(self.hudState)
		))
		hudView.translatesAutoresizingMaskIntoConstraints = false
		hudView.shouldResizeToFitContent = true
		hudView.setContentHuggingPriority(.fittingSizeLevel, for: .horizontal)
		hudView.setContentHuggingPriority(.fittingSizeLevel, for: .vertical)
		view.addSubview(hudView)

		NSLayoutConstraint.activate([
			hudView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			hudView.centerYAnchor.constraint(equalTo: view.safeAreaLayoutGuide.centerYAnchor)
		])

		addKeyCommand(UIKeyCommand(title: .localize("CLEAR_TERMINAL", comment: "VoiceOver label for a button that clears the terminal."),
															 image: UIImage(systemName: "text.badge.xmark"),
															 action: #selector(self.clearTerminal),
															 input: "k",
															 modifierFlags: .command))

		#if !targetEnvironment(macCatalyst)
		addKeyCommand(UIKeyCommand(title: .localize("PASSWORD_MANAGER", comment: "VoiceOver label for the password manager button."),
															 image: UIImage(systemName: "key.fill"),
															 action: #selector(self.activatePasswordManager),
															 input: "f",
															 modifierFlags: [ .command, .alternate ]))
		#endif

		if UIApplication.shared.supportsMultipleScenes {
			NotificationCenter.default.addObserver(self, selector: #selector(self.sceneDidEnterBackground), name: UIWindowScene.didEnterBackgroundNotification, object: nil)
			NotificationCenter.default.addObserver(self, selector: #selector(self.sceneWillEnterForeground), name: UIWindowScene.willEnterForegroundNotification, object: nil)
		}

		NotificationCenter.default.addObserver(self, selector: #selector(self.preferencesUpdated), name: Preferences.didChangeNotification, object: nil)
	}

	override func viewWillAppear(_ animated: Bool) {
		super.viewWillAppear(animated)

		keyInput.becomeFirstResponder()
		terminalController.terminalWillAppear()
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)

		hasAppeared = true

		if let error = failureError {
			didReceiveError(error: error)
		} else {
			if let initialCommand = initialCommand?.data(using: .utf8) {
				terminalController.write(initialCommand + EscapeSequences.return)
			}
		}

		initialCommand = nil
	}

	override func viewWillDisappear(_ animated: Bool) {
		super.viewWillDisappear(animated)

		keyInput.resignFirstResponder()
		terminalController.terminalWillDisappear()
	}

	override func viewDidDisappear(_ animated: Bool) {
		super.viewDidDisappear(animated)

		hasAppeared = false
	}

	override func viewWillLayoutSubviews() {
		super.viewWillLayoutSubviews()
		updateScreenSize()
	}

	override func viewSafeAreaInsetsDidChange() {
		super.viewSafeAreaInsetsDidChange()
		updateScreenSize()
	}

	override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
		super.traitCollectionDidChange(previousTraitCollection)
		updateScreenSize()
	}

	override func removeFromParent() {
		if hasStarted {
			do {
				try terminalController.stopSubProcess()
			} catch {
				Logger().error("Failed to stop subprocess: \(String(describing: error))")
			}
		}

		super.removeFromParent()
	}

	// MARK: - Screen

	func updateScreenSize() {
		if isSplitViewResizing {
			return
		}

		// Determine the screen size based on the font size
		var layoutSize = textView.safeAreaLayoutGuide.layoutFrame.size
		layoutSize.width -= TerminalView.horizontalSpacing * 2
		layoutSize.height -= TerminalView.verticalSpacing * 2

		if layoutSize.width < 0 || layoutSize.height < 0 {
			// Not laid out yet. We’ll be called again when we are.
			return
		}

		let glyphSize = terminalController.fontMetrics.boundingBox
		if glyphSize.width == 0 || glyphSize.height == 0 {
			fatalError("Failed to get glyph size")
		}

		let newSize = ScreenSize(cols: UInt16(layoutSize.width / glyphSize.width),
														 rows: UInt16(layoutSize.height / glyphSize.height.rounded(.up)),
														 cellSize: glyphSize)
		if screenSize != newSize {
			screenSize = newSize
			state.columns = Int(newSize.cols)
			delegate?.terminal(viewController: self, screenSizeDidChange: newSize)
		}
	}

	@objc func clearTerminal() {
		terminalController.clearTerminal()
	}

	private func updateIsSplitViewResizing() {
		state.isSplitViewResizing = isSplitViewResizing

		if !isSplitViewResizing {
			updateScreenSize()
		}
	}

	private func updateShowsTitleView() {
		updateScreenSize()
	}

	// MARK: - Gestures

	@objc private func handleTextViewTap(_ gestureRecognizer: UITapGestureRecognizer) {
		if gestureRecognizer.state == .ended && state.selection != nil {
			clearSelection()
		}

		if gestureRecognizer.state == .ended && !keyInput.isFirstResponder {
			keyInput.becomeFirstResponder()
			delegate?.terminalDidBecomeActive(viewController: self)
		}
	}

	// MARK: - Selection

	private func cell(at point: CGPoint) -> TerminalCell {
		// The terminal content’s frame is reported by SwiftUI in window coordinates, so convert the
		// touch to the same space. This automatically accounts for the current scroll position.
		let windowPoint = textView.convert(point, to: nil)
		let origin = state.contentFrame.origin
		let cellWidth = max(state.fontMetrics.width, 1)
		let lineHeight = max(state.fontMetrics.height.rounded(.up), 1)
		let col = Int(((windowPoint.x - origin.x) / cellWidth).rounded(.down))
		let row = Int(((windowPoint.y - origin.y - TerminalView.verticalSpacing) / lineHeight).rounded(.down))
		return TerminalCell(row: min(max(row, 0), max(state.lines.count - 1, 0)),
												col: min(max(col, 0), max(state.columns - 1, 0)))
	}

	@objc private func handleSelectionPress(_ gestureRecognizer: UILongPressGestureRecognizer) {
		let cell = cell(at: gestureRecognizer.location(in: textView))

		switch gestureRecognizer.state {
		case .began:
			let word = terminalController.wordRange(atRow: cell.row, col: cell.col)
			selectionWordStart = TerminalCell(row: cell.row, col: word.start)
			selectionWordEnd = TerminalCell(row: cell.row, col: word.end)
			state.isSelecting = true
			state.selection = TerminalSelection(anchor: selectionWordStart, head: selectionWordEnd)
			UIImpactFeedbackGenerator(style: .medium).impactOccurred()

		case .changed:
			var newSelection: TerminalSelection
			if cell < selectionWordStart {
				newSelection = TerminalSelection(anchor: selectionWordEnd, head: cell)
			} else if cell > selectionWordEnd {
				newSelection = TerminalSelection(anchor: selectionWordStart, head: cell)
			} else {
				newSelection = TerminalSelection(anchor: selectionWordStart, head: selectionWordEnd)
			}
			if newSelection != state.selection {
				state.selection = newSelection
				UISelectionFeedbackGenerator().selectionChanged()
			}

		case .ended, .cancelled, .failed:
			state.isSelecting = false

		default:
			break
		}
	}

	@objc private func handlePinch(_ gestureRecognizer: UIPinchGestureRecognizer) {
		let preferences = Preferences.shared
		switch gestureRecognizer.state {
		case .began:
			pinchStartFontSize = preferences.fontSize

		case .changed:
			let newSize = min(max((pinchStartFontSize * Double(gestureRecognizer.scale)).rounded(), 8), 36)
			if newSize != preferences.fontSize {
				preferences.fontSize = newSize
			}

		default:
			break
		}
	}

	private func selectedText() -> String? {
		guard let selection = state.selection else {
			return nil
		}
		let text = terminalController.text(fromRow: selection.start.row, col: selection.start.col,
																			 toRow: selection.end.row, col: selection.end.col)
		return text.isEmpty ? nil : text
	}

	private func clearSelection() {
		state.isSelecting = false
		state.selection = nil
	}

	private func performSelectionAction(_ action: TerminalSelectionAction) {
		switch action {
		case .copy:
			if let text = selectedText() {
				UIPasteboard.general.string = text
				UINotificationFeedbackGenerator().notificationOccurred(.success)
			}
			clearSelection()

		case .translate:
			guard let text = selectedText(),
						let url = translateURL(for: text) else {
				return
			}
			present(SFSafariViewController(url: url), animated: true, completion: nil)

		case .share:
			guard let text = selectedText() else {
				return
			}
			let viewController = UIActivityViewController(activityItems: [text], applicationActivities: nil)
			viewController.popoverPresentationController?.sourceView = view
			viewController.popoverPresentationController?.sourceRect = CGRect(x: view.bounds.midX, y: view.safeAreaInsets.top + 8, width: 0, height: 0)
			present(viewController, animated: true, completion: nil)

		case .paste:
			if let string = UIPasteboard.general.string {
				terminalController.paste(string)
			}
			clearSelection()

		case .selectAll:
			guard !state.lines.isEmpty else {
				return
			}
			state.selection = TerminalSelection(anchor: TerminalCell(row: 0, col: 0),
																					head: TerminalCell(row: state.lines.count - 1, col: max(state.columns - 1, 0)))

		case .clear:
			clearSelection()
		}
	}

	private func translateURL(for text: String) -> URL? {
		// Translate into the user’s language. Uses the web translator so it works on every iOS version.
		let preferred = Preferences.shared.preferredLocale.isEmpty
			? (Locale.preferredLanguages.first ?? "en")
			: Preferences.shared.preferredLocale
		var language = String(preferred.prefix(while: { $0 != "-" && $0 != "_" }))
		if language == "zh" {
			language = preferred.contains("Hant") || preferred.contains("TW") || preferred.contains("HK") ? "zh-TW" : "zh-CN"
		}

		var components = URLComponents(string: "https://translate.google.com/")
		components?.queryItems = [
			URLQueryItem(name: "sl", value: "auto"),
			URLQueryItem(name: "tl", value: language),
			URLQueryItem(name: "text", value: String(text.prefix(4000))),
			URLQueryItem(name: "op", value: "translate")
		]
		return components?.url
	}

	// MARK: - Lifecycle

	@objc private func sceneDidEnterBackground(_ notification: Notification) {
		if notification.object as? UIWindowScene == view.window?.windowScene {
			terminalController.windowDidEnterBackground()
		}
	}

	@objc private func sceneWillEnterForeground(_ notification: Notification) {
		if notification.object as? UIWindowScene == view.window?.windowScene {
			terminalController.windowWillEnterForeground()
		}
	}

	@objc private func preferencesUpdated() {
		state.fontMetrics = terminalController.fontMetrics
		state.colorMap = terminalController.colorMap
		state.columns = Int(screenSize?.cols ?? UInt16(state.columns))

		// A new font size changes how many columns and rows fit on screen.
		if textView != nil {
			updateScreenSize()
		}
	}

}

extension TerminalSessionViewController: TerminalControllerDelegate {

	func refresh(lines: [TerminalLine]) {
		state.lines = lines
	}

	func activateBell() {
		if Preferences.shared.bellHUD {
			hudState.isVisible = true
		}

		HapticController.playBell()
	}

	func titleDidChange(_ title: String?, isDirty: Bool, hasBell: Bool) {
		let newTitle = title ?? .localize("TERMINAL", comment: "Generic title displayed before the terminal sets a proper title.")
		delegate?.terminal(viewController: self,
											 titleDidChange: newTitle,
											 isDirty: isDirty,
											 hasBell: hasBell)
	}

	func currentFileDidChange(_ url: URL?, inWorkingDirectory workingDirectoryURL: URL?) {
		#if targetEnvironment(macCatalyst)
		if let windowScene = view.window?.windowScene {
			windowScene.titlebar?.representedURL = url
		}
		#endif
	}

	func saveFile(url: URL) {
		let viewController = UIDocumentPickerViewController(forExporting: [url], asCopy: false)
		viewController.delegate = self
		present(viewController, animated: true, completion: nil)
	}

	func fileUploadRequested() {
		isPickingFileForUpload = true

		let viewController = UIDocumentPickerViewController(forOpeningContentTypes: [.data, .directory])
		viewController.delegate = self
		present(viewController, animated: true, completion: nil)
	}

	@objc func activatePasswordManager() {
		keyInput.activatePasswordManager()
	}

	@objc func close() {
		if let splitViewController = parent as? TerminalSplitViewController {
			splitViewController.remove(viewController: self)
		}
	}

	func didReceiveError(error: Error) {
		if !hasAppeared {
			failureError = error
			return
		}
		failureError = nil

		let alertController = UIAlertController(title: .localize("TERMINAL_LAUNCH_FAILED_TITLE", comment: "Alert title displayed when a terminal could not be launched."),
																						message: .localize("TERMINAL_LAUNCH_FAILED_BODY", comment: "Alert body displayed when a terminal could not be launched."),
																						preferredStyle: .alert)
		alertController.addAction(UIAlertAction(title: .ok, style: .cancel, handler: nil))
		present(alertController, animated: true, completion: nil)
	}

}

extension TerminalSessionViewController: UIGestureRecognizerDelegate {

	func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf otherGestureRecognizer: UIGestureRecognizer) -> Bool {
		// This allows the tap-to-activate-keyboard gesture to work without conflicting with UIKit’s
		// internal text view/scroll view gestures… as much as we can avoid conflicting, at least.
		guard gestureRecognizer == textViewTapGestureRecognizer else {
			return false
		}
		// Don’t make taps wait for the long press or pinch to fail, or tapping would feel laggy.
		if otherGestureRecognizer == selectionGestureRecognizer || otherGestureRecognizer == pinchGestureRecognizer {
			return false
		}
		return !(otherGestureRecognizer is UITapGestureRecognizer) || keyInput.isFirstResponder
	}

	func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer) -> Bool {
		// Pinching must not fight with the scroll view’s own gestures.
		return gestureRecognizer == pinchGestureRecognizer
	}
}

extension TerminalSessionViewController: UIDocumentPickerDelegate {

	func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
		guard isPickingFileForUpload,
					let url = urls.first else {
			return
		}
		terminalController.uploadFile(url: url)
		isPickingFileForUpload = false
	}

	func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
		if isPickingFileForUpload {
			isPickingFileForUpload = false
			terminalController.cancelUploadRequest()
		} else {
			// The system will clean up the temp directory for us eventually anyway, but still delete the
			// downloads temp directory now so the file doesn’t linger around till then.
			terminalController.deleteDownloadCache()
		}
	}

}
