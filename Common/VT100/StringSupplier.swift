//
//  StringSupplier.swift
//  NewTerm Common
//
//  Created by Adam Demasi on 2/4/21.
//

import Foundation
import SwiftTerm
import SwiftUI

/// A single rendered terminal row. Rows are value types that conform to `Equatable`, so SwiftUI can
/// skip re-rendering any row whose contents haven’t changed. This is the main reason scrolling and
/// output-heavy commands stay smooth, compared to storing type-erased `AnyView`s.
public struct TerminalLine: View, Equatable {

	struct Run: Equatable {
		var text: String
		var width: CGFloat
		var foreground: UIColor
		var background: UIColor
		var font: UIFont
		var underline: Bool
		var strikethrough: Bool
	}

	public static let empty = TerminalLine(runs: [])

	var runs: [Run]

	public var body: some View {
		HStack(alignment: .firstTextBaseline, spacing: 0) {
			ForEach(runs.indices, id: \.self) { i in
				let run = runs[i]
				Text(run.text)
					// Text attributes
					.foregroundColor(Color(run.foreground))
					.font(Font(run.font))
					.underline(run.underline)
					.strikethrough(run.strikethrough)
					.tracking(0)
					// View attributes
					.allowsTightening(false)
					.lineLimit(1)
					.background(Color(run.background))
					.frame(width: run.width)
					.fixedSize(horizontal: false, vertical: true)
			}
		}
	}

}

open class StringSupplier {

	open var terminal: Terminal!
	open var colorMap: ColorMap!
	open var fontMetrics: FontMetrics!
	open var cursorVisible = true

	public init() {}

	public func attributedString(forScrollInvariantRow row: Int) -> TerminalLine {
		guard let terminal = terminal else {
			fatalError()
		}

		guard let line = terminal.getScrollInvariantLine(row: row) else {
			return .empty
		}

		let cursorPosition = terminal.getCursorLocation()
		let scrollbackRows = terminal.getTopVisibleRow()

		var lastAttribute = Attribute.empty
		var runs = [TerminalLine.Run]()
		var buffer = ""
		for j in 0..<terminal.cols {
			let data = line[j]
			let isCursor = cursorVisible && row - scrollbackRows == cursorPosition.y && j == cursorPosition.x

			if isCursor || lastAttribute != data.attribute {
				// Finish up the last run by appending it, then reset for the next run.
				if !buffer.isEmpty {
					runs.append(run(buffer, attribute: lastAttribute))
				}
				lastAttribute = data.attribute
				buffer.removeAll()
			}

			let character = data.getCharacter()
			buffer.append(character == "\0" ? " " : character)

			if isCursor {
				// We may need to insert a space for the cursor to show up.
				if buffer.isEmpty {
					buffer.append(" ")
				}

				runs.append(run(buffer, attribute: lastAttribute, isCursor: true))
				buffer.removeAll()
			}
		}

		// Append the final run
		if !buffer.isEmpty {
			runs.append(run(buffer, attribute: lastAttribute))
		}

		return TerminalLine(runs: runs)
	}

	private func run(_ run: String, attribute: Attribute, isCursor: Bool = false) -> TerminalLine.Run {
		var fgColor = attribute.fg
		var bgColor = attribute.bg

		if attribute.style.contains(.inverse) {
			swap(&bgColor, &fgColor)
			if fgColor == .defaultColor {
				fgColor = .defaultInvertedColor
			}
			if bgColor == .defaultColor {
				bgColor = .defaultInvertedColor
			}
		}

		let foreground = colorMap?.color(for: fgColor,
																		 isForeground: true,
																		 isBold: attribute.style.contains(.bold),
																		 isCursor: isCursor)
		let background = colorMap?.color(for: bgColor,
																		 isForeground: false,
																		 isCursor: isCursor)

		let font: UIFont?
		if attribute.style.contains(.bold) || attribute.style.contains(.blink) {
			font = attribute.style.contains(.italic) ? fontMetrics?.boldItalicFont : fontMetrics?.boldFont
		} else if attribute.style.contains(.dim) {
			font = attribute.style.contains(.italic) ? fontMetrics?.lightItalicFont : fontMetrics?.lightFont
		} else {
			font = attribute.style.contains(.italic) ? fontMetrics?.italicFont : fontMetrics?.regularFont
		}

		let width = CGFloat(run.unicodeScalars.reduce(0, { $0 + UnicodeUtil.columnWidth(rune: $1) })) * (fontMetrics?.width ?? 0)

		return TerminalLine.Run(text: run,
														width: width,
														foreground: foreground ?? .white,
														background: background ?? .black,
														font: font ?? .monospacedSystemFont(ofSize: 12, weight: .regular),
														underline: attribute.style.contains(.underline),
														strikethrough: attribute.style.contains(.crossedOut))
	}

}
