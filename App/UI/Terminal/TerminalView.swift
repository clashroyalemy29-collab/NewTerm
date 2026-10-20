//
//  TerminalView.swift
//  NewTerm (iOS)
//
//  Created by Adam Demasi on 5/4/2022.
//

import SwiftUI
import SwiftUIX
import SwiftTerm
import NewTermCommon

/// A cell position in the terminal, using scroll-invariant rows (the same indices as `TerminalState.lines`).
struct TerminalCell: Equatable, Comparable {
	var row: Int
	var col: Int

	static func < (lhs: TerminalCell, rhs: TerminalCell) -> Bool {
		lhs.row == rhs.row ? lhs.col < rhs.col : lhs.row < rhs.row
	}
}

struct TerminalSelection: Equatable {
	var anchor: TerminalCell
	var head: TerminalCell

	var start: TerminalCell { min(anchor, head) }
	var end: TerminalCell { max(anchor, head) }
}

enum TerminalSelectionAction {
	case copy, translate, share, paste, selectAll, clear
}

class TerminalState: ObservableObject {
	@Published var lines = [TerminalLine]()
	@Published var fontMetrics = FontMetrics(font: AppFont(), fontSize: 12)
	@Published var colorMap = ColorMap(theme: AppTheme())
	@Published var isSplitViewResizing = false

	// Text selection
	@Published var selection: TerminalSelection?
	@Published var isSelecting = false
	var columns = 80
	var onSelectionAction: ((TerminalSelectionAction) -> Void)?

	// Scroll tracking. These change on every scroll frame, so they’re deliberately not @Published.
	var contentFrame = CGRect.zero
	var viewportFrame = CGRect.zero
	var isAtBottom = true
}

private struct ContentFrameKey: PreferenceKey {
	static var defaultValue = CGRect.zero
	static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private struct ViewportFrameKey: PreferenceKey {
	static var defaultValue = CGRect.zero
	static func reduce(value: inout CGRect, nextValue: () -> CGRect) { value = nextValue() }
}

private func systemString(_ key: String) -> String {
	// Reuse UIKit’s own translations, so the buttons follow the system language automatically.
	NSLocalizedString(key, tableName: nil, bundle: Bundle(for: UIView.self), value: key, comment: "")
}

struct TerminalView: View {
	static let horizontalSpacing: CGFloat = isBigDevice ? 3 : 0
	static let verticalSpacing: CGFloat = isBigDevice ? 2 : 0

	@EnvironmentObject private var state: TerminalState
	@State private var showsJumpToBottom = false

	private var lineHeight: CGFloat { state.fontMetrics.height.rounded(.up) }
	private var cellWidth: CGFloat { state.fontMetrics.width }

	private func updateIsAtBottom() {
		let atBottom = state.contentFrame.maxY - state.viewportFrame.maxY < 60
		state.isAtBottom = atBottom
		if showsJumpToBottom == atBottom {
			showsJumpToBottom = !atBottom
		}
	}

	var body: some View {
		let view = ScrollViewReader { scrollView in
			ZStack(alignment: .top) {
				ScrollView(.vertical, showsIndicators: true) {
					LazyVStack(alignment: .leading, spacing: 0) {
						ForEach(state.lines.indices, id: \.self) { i in
							state.lines[i]
								.equatable()
								.drawingGroup(opaque: true)
								.frame(height: lineHeight, alignment: .topLeading)
								.overlay(selectionHighlight(row: i), alignment: .topLeading)
								.id(i)
						}
					}
						.background(GeometryReader { geometry in
							Color.clear.preference(key: ContentFrameKey.self, value: geometry.frame(in: .global))
						})
						.padding(.vertical, Self.verticalSpacing)
						.padding(.horizontal, Self.horizontalSpacing)
						.background(Color(state.colorMap.background))
				}
					.background(Color(state.colorMap.background))
					.background(GeometryReader { geometry in
						Color.clear.preference(key: ViewportFrameKey.self, value: geometry.frame(in: .global))
					})
					.onPreferenceChange(ContentFrameKey.self) { frame in
						state.contentFrame = frame
						updateIsAtBottom()
					}
					.onPreferenceChange(ViewportFrameKey.self) { frame in
						state.viewportFrame = frame
						updateIsAtBottom()
					}
					.onChange(of: state.lines.indices.last, perform: { _ in
						// Only follow new output if the user hasn’t scrolled back to read something.
						if state.isAtBottom {
							scrollView.scrollTo(state.lines.indices.last, anchor: .bottom)
						}
					})

				if state.selection != nil && !state.isSelecting {
					selectionBar
						.padding(.top, 8)
						.transition(.opacity)
				}

				if showsJumpToBottom && state.selection == nil {
					VStack {
						Spacer()
						HStack {
							Spacer()
							Button(action: {
								withAnimation(.easeOut(duration: 0.2)) {
									scrollView.scrollTo(state.lines.indices.last, anchor: .bottom)
								}
							}) {
								Image(systemName: "chevron.down.circle.fill")
									.font(.system(size: 32))
									.foregroundColor(Color(state.colorMap.foreground).opacity(0.6))
							}
								.accessibilityLabel(Text("Scroll to bottom"))
								.padding(12)
						}
					}
					.transition(.opacity)
				}
			}
		}
			.opacity(state.isSplitViewResizing ? 0.6 : 1)
			.animation(.linear(duration: 0.1), value: state.isSplitViewResizing)
			.animation(.easeOut(duration: 0.15), value: state.selection == nil)
			.animation(.easeOut(duration: 0.15), value: state.isSelecting)

		if #available(iOS 15, *) {
			return view
				.accessibilityTextContentType(.console)
		} else {
			return view
		}
	}

	// MARK: - Selection

	@ViewBuilder
	private func selectionHighlight(row: Int) -> some View {
		if let selection = state.selection,
			 row >= selection.start.row && row <= selection.end.row {
			let first = row == selection.start.row ? selection.start.col : 0
			let last = row == selection.end.row ? selection.end.col : max(state.columns - 1, 0)
			if first <= last {
				Color.accentColor
					.opacity(0.35)
					.frame(width: CGFloat(last - first + 1) * cellWidth, height: lineHeight)
					.offset(x: CGFloat(first) * cellWidth)
					.allowsHitTesting(false)
			}
		}
	}

	private var selectionBar: some View {
		HStack(spacing: 2) {
			barButton("doc.on.doc", title: systemString("Copy"), action: .copy)
			barButton("globe", title: systemString("Translate"), action: .translate)
			barButton("square.and.arrow.up", title: systemString("Share…"), action: .share)
			if UIPasteboard.general.hasStrings {
				barButton("doc.on.clipboard", title: systemString("Paste"), action: .paste)
			}
			barButton("selection.pin.in.out", title: systemString("Select All"), action: .selectAll)
			barButton("xmark", title: systemString("Done"), action: .clear)
		}
			.padding(.horizontal, 6)
			.padding(.vertical, 2)
			.background(Capsule().fill(Color(state.colorMap.isDark
																				? UIColor(white: 0.17, alpha: 0.97)
																				: UIColor(white: 0.97, alpha: 0.97))))
			.overlay(Capsule().stroke(Color.gray.opacity(0.35), lineWidth: 0.5))
			.shadow(color: Color.black.opacity(0.25), radius: 6, x: 0, y: 2)
	}

	private func barButton(_ systemImage: String, title: String, action: TerminalSelectionAction) -> some View {
		Button(action: { state.onSelectionAction?(action) }) {
			Image(systemName: systemImage)
				.font(.system(size: 16, weight: .medium))
				.foregroundColor(Color(state.colorMap.isDark ? UIColor.white : UIColor.black))
				.frame(width: 42, height: 38)
		}
			.accessibilityLabel(Text(title))
	}
}

class TerminalHostingView: UIHostingView<AnyView> {
	init(state: TerminalState) {
		let view = TerminalView()
			.environmentObject(state)
		super.init(rootView: AnyView(view))
	}

	required init?(coder: NSCoder) {
		fatalError("init(coder:) has not been implemented")
	}

	required init(rootView: AnyView) {
		fatalError("init(rootView:) has not been implemented")
	}
}

struct TerminalSampleView: View {
	private class TerminalSampleViewDelegate: NSObject, TerminalDelegate {
		func send(source: Terminal, data: ArraySlice<UInt8>) {}
	}

	@State var fontMetrics: FontMetrics
	@State var colorMap: ColorMap

	private var terminal: Terminal!
	private let stringSupplier = StringSupplier()
	private let delegate = TerminalSampleViewDelegate()
	private let state = TerminalState()

	private let timer = Timer.publish(every: 1, on: .main, in: .common)
		.autoconnect()

	init(fontMetrics: FontMetrics = FontMetrics(font: AppFont(), fontSize: 12),
			 colorMap: ColorMap = ColorMap(theme: AppTheme())) {
		self.fontMetrics = fontMetrics
		self.colorMap = colorMap

		let options = TerminalOptions(cols: 80,
																	rows: 25,
																	termName: "xterm-256color",
																	scrollback: 100)
		terminal = Terminal(delegate: delegate, options: options)
		stringSupplier.terminal = terminal

		if let colorTest = try? Data(contentsOf: Bundle.main.url(forResource: "colortest", withExtension: "txt")!) {
			terminal?.feed(byteArray: [UTF8Char](colorTest))
		}
	}

	var body: some View {
		TerminalView()
			.environmentObject(state)
			.onAppear {
				stringSupplier.colorMap = colorMap
				stringSupplier.fontMetrics = fontMetrics
			}
			.onChange(of: colorMap, perform: { stringSupplier.colorMap = $0 })
			.onChange(of: fontMetrics, perform: { stringSupplier.fontMetrics = $0 })
			.onChangeOfFrame(perform: { size in
				// Determine the screen size based on the font size
				// TODO: Calculate the exact number of lines we need from the buffer
				let glyphSize = stringSupplier.fontMetrics?.boundingBox ?? .zero
				terminal.resize(cols: Int(size.width / glyphSize.width),
												rows: 32)
			})
			.onReceive(timer) { _ in
				state.lines = Array(0...(terminal.rows + terminal.getTopVisibleRow()))
					.map { stringSupplier.attributedString(forScrollInvariantRow: $0) }
			}
	}
}

struct TerminalView_Previews: PreviewProvider {
	static var previews: some View {
		TerminalSampleView()
			.preferredColorScheme(.dark)
	}
}
