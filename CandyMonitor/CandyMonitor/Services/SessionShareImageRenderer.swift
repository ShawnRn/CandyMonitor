import AppKit
import Foundation

enum SessionShareImageRenderer {
    static func pngData(session: ChargingSession, samples: [PortSample]) -> Data? {
        let size = NSSize(width: 1400, height: 900)
        let image = NSImage(size: size)
        image.lockFocus()
        defer { image.unlockFocus() }

        let background = NSColor(calibratedWhite: 0.10, alpha: 1)
        let panel = NSColor(calibratedWhite: 0.15, alpha: 1)
        let grid = NSColor.white.withAlphaComponent(0.12)
        let orange = NSColor(calibratedRed: 1.00, green: 0.28, blue: 0.12, alpha: 1)
        let text = NSColor(calibratedWhite: 0.94, alpha: 1)
        let secondary = NSColor(calibratedWhite: 0.68, alpha: 1)

        background.setFill()
        NSRect(origin: .zero, size: size).fill()

        let card = NSRect(x: 70, y: 70, width: size.width - 140, height: size.height - 140)
        rounded(card, radius: 34, fill: panel, stroke: NSColor.white.withAlphaComponent(0.08))

        drawText(session.displayTitle, at: CGPoint(x: 120, y: 770), font: .systemFont(ofSize: 44, weight: .bold), color: text)
        drawText("\(session.deviceName) / \(session.portName)", at: CGPoint(x: 120, y: 724), font: .systemFont(ofSize: 24, weight: .semibold), color: secondary)

        let stats = [
            ("峰值功率", String(format: "%.1f W", session.peakPowerW)),
            ("平均功率", String(format: "%.1f W", session.averagePowerW)),
            ("能量估算", String(format: "%.2f Wh", CSVExporter.estimatedEnergyWh(samples: samples))),
            ("采样点", "\(samples.count)")
        ]

        for (index, stat) in stats.enumerated() {
            let x = 120 + CGFloat(index) * 300
            rounded(NSRect(x: x, y: 610, width: 250, height: 94), radius: 18, fill: NSColor.white.withAlphaComponent(0.045), stroke: NSColor.white.withAlphaComponent(0.06))
            drawText(stat.0, at: CGPoint(x: x + 22, y: 670), font: .systemFont(ofSize: 18, weight: .medium), color: secondary)
            drawText(stat.1, at: CGPoint(x: x + 22, y: 632), font: .systemFont(ofSize: 28, weight: .bold), color: text)
        }

        let chartRect = NSRect(x: 120, y: 160, width: 1160, height: 380)
        rounded(chartRect, radius: 24, fill: NSColor.black.withAlphaComponent(0.16), stroke: NSColor.white.withAlphaComponent(0.06))

        for i in 0...4 {
            let y = chartRect.minY + CGFloat(i) * chartRect.height / 4
            let path = NSBezierPath()
            path.move(to: CGPoint(x: chartRect.minX + 26, y: y))
            path.line(to: CGPoint(x: chartRect.maxX - 26, y: y))
            grid.setStroke()
            path.lineWidth = 1
            path.stroke()
        }

        drawPowerLine(samples: samples, in: chartRect.insetBy(dx: 36, dy: 36), color: orange)
        drawText("CandyMonitor", at: CGPoint(x: 120, y: 108), font: .systemFont(ofSize: 20, weight: .semibold), color: secondary)
        drawText(Date(), at: CGPoint(x: 1060, y: 108), font: .systemFont(ofSize: 18, weight: .medium), color: secondary)

        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff) else { return nil }
        return bitmap.representation(using: .png, properties: [:])
    }

    private static func drawPowerLine(samples: [PortSample], in rect: NSRect, color: NSColor) {
        let ordered = samples.sorted(by: { $0.timestamp < $1.timestamp })
        guard ordered.count > 1,
              let first = ordered.first?.timestamp,
              let last = ordered.last?.timestamp else { return }

        let maxPower = max(5, (ordered.map(\.powerW).max() ?? 0) * 1.15)
        let duration = max(last.timeIntervalSince(first), 1)
        let path = NSBezierPath()

        for (index, sample) in ordered.enumerated() {
            let x = rect.minX + rect.width * sample.timestamp.timeIntervalSince(first) / duration
            let y = rect.minY + rect.height * min(max(sample.powerW / maxPower, 0), 1)
            let point = CGPoint(x: x, y: y)
            if index == 0 {
                path.move(to: point)
            } else {
                path.line(to: point)
            }
        }

        color.setStroke()
        path.lineWidth = 5
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.stroke()
    }

    private static func rounded(_ rect: NSRect, radius: CGFloat, fill: NSColor, stroke: NSColor) {
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        path.fill()
        stroke.setStroke()
        path.lineWidth = 1
        path.stroke()
    }

    private static func drawText(_ value: String, at point: CGPoint, font: NSFont, color: NSColor) {
        value.draw(at: point, withAttributes: [.font: font, .foregroundColor: color])
    }

    private static func drawText(_ date: Date, at point: CGPoint, font: NSFont, color: NSColor) {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        drawText(formatter.string(from: date), at: point, font: font, color: color)
    }
}
