import XCTest
import SwiftUI
import WidgetKit
import ImageIO
import UniformTypeIdentifiers
@testable import FolitoWatch

/// Renders every complication family (default, tinted, redacted, Always On and the "Start reading" placeholder)
/// to PNG attachments with ImageRenderer. CI (macos.yml, watch job) exports them as the
/// "complication-screenshots" artifact, which is how the design is reviewed without a Mac.
///
/// The frames approximate a 45 mm watch face. Outside a real watch face two things are simulated: the corner
/// family's curved gauge (a `widgetLabel`, drawn only by the system) is drawn as an arc, and the tinted face's
/// colour is applied through `complicationPreviewTint`. The Smart Stack image adds the container background.
@MainActor
final class ComplicationSnapshotTests: XCTestCase {
    private static let book = ReadingSnapshot(bookID: "sample", title: "Pride and Prejudice",
                                              chapterTitle: "Chapter 12: Elizabeth's Walk", fraction: 0.45)
    private static let withMinutes: ReadingSnapshot = {
        var s = book
        s.minutesLeft = 7
        return s
    }()
    private static let tint = Color.orange

    enum Variant: String, CaseIterable {
        case `default`, tinted, redacted, alwaysOn = "always-on", placeholder
    }

    private struct Family {
        let name: String
        let family: WidgetFamily
        let size: CGSize
    }

    private let families = [
        Family(name: "circular", family: .accessoryCircular, size: CGSize(width: 50, height: 50)),
        Family(name: "corner", family: .accessoryCorner, size: CGSize(width: 64, height: 64)),
        Family(name: "inline", family: .accessoryInline, size: CGSize(width: 180, height: 22)),
        Family(name: "rectangular", family: .accessoryRectangular, size: CGSize(width: 180, height: 76)),
    ]

    func testRenderAllFamilies() throws {
        var rendered = 0
        for family in families {
            for variant in Variant.allCases {
                let view = tile(family, variant)
                try attach(view, name: "\(family.name)-\(variant.rawValue)")
                rendered += 1
            }
        }
        // Rectangular with the optional "minutes left in chapter" line (nil until the estimator lands).
        try attach(tile(families[3], .default, snapshot: Self.withMinutes), name: "rectangular-with-minutes")
        // Inline space depends on the face; on a wide slot the title is shown, on a narrow one only the percentage.
        let wideInline = Family(name: "inline-wide", family: .accessoryInline, size: CGSize(width: 280, height: 22))
        try attach(tile(wideInline, .default), name: "inline-wide-default")
        // Smart Stack: the rectangular family on its container background.
        try attach(smartStack(Self.book), name: "smart-stack-default")
        try attach(smartStack(nil), name: "smart-stack-placeholder")
        try attach(contactSheet(), name: "contact-sheet")
        XCTAssertEqual(rendered, families.count * Variant.allCases.count)
    }

    // MARK: Views

    @ViewBuilder
    private func tile(_ family: Family, _ variant: Variant, snapshot: ReadingSnapshot? = book) -> some View {
        let shown: ReadingSnapshot? = variant == .placeholder ? nil : snapshot
        Group {
            if family.family == .accessoryCorner {
                CornerPreview(snapshot: shown)
            } else {
                ComplicationView(snapshot: shown, family: family.family)
            }
        }
        .frame(width: family.size.width, height: family.size.height)
        // The system masks circular complications to a circle; ImageRenderer does not.
        .clipShape(family.family == .accessoryCircular ? AnyShape(Circle()) : AnyShape(Rectangle()))
        .environment(\.complicationPreviewTint, variant == .tinted ? Self.tint : nil)
        .environment(\.isLuminanceReduced, variant == .alwaysOn)
        .modifier(RedactedIf(active: variant == .redacted))
        .foregroundStyle(variant == .alwaysOn ? Color.white.opacity(0.7) : Color.white)
        .padding(8)
        .background(Color.black)
        .environment(\.colorScheme, .dark)
    }

    private func smartStack(_ snapshot: ReadingSnapshot?) -> some View {
        ComplicationView(snapshot: snapshot, family: .accessoryRectangular)
            .frame(width: 168, height: 70)
            .padding(10)
            .background(
                LinearGradient(colors: [Color.folitoAccent.opacity(0.35), Color.folitoAccent.opacity(0.12)],
                               startPoint: .top, endPoint: .bottom),
                in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .foregroundStyle(.white)
            .padding(8)
            .background(Color.black)
            .environment(\.colorScheme, .dark)
    }

    private func contactSheet() -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(families, id: \.name) { family in
                Text(family.name).font(.caption2.bold()).foregroundStyle(.gray)
                HStack(alignment: .top, spacing: 6) {
                    ForEach(Variant.allCases, id: \.self) { variant in
                        VStack(spacing: 2) {
                            self.tile(family, variant)
                            Text(variant.rawValue).font(.system(size: 8)).foregroundStyle(.gray)
                        }
                    }
                }
            }
            Text("smart stack").font(.caption2.bold()).foregroundStyle(.gray)
            HStack(spacing: 6) { smartStack(Self.book); smartStack(nil) }
        }
        .padding(10)
        .background(Color(white: 0.12))
        .environment(\.colorScheme, .dark)
    }

    // MARK: Rendering

    private func attach(_ view: some View, name: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try XCTUnwrap(renderer.cgImage, "ImageRenderer produced no image for \(name)")
        let data = NSMutableData()
        let dest = try XCTUnwrap(CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        let attachment = XCTAttachment(data: data as Data, uniformTypeIdentifier: UTType.png.identifier)
        attachment.name = "\(name).png"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private struct RedactedIf: ViewModifier {
    let active: Bool
    func body(content: Content) -> some View {
        if active { content.redacted(reason: .privacy) } else { content }
    }
}

/// The corner family as the watch face draws it: the symbol (ComplicationView) in the corner and the
/// `widgetLabel` gauge curved along the bezel, approximated with an arc.
private struct CornerPreview: View {
    let snapshot: ReadingSnapshot?
    @Environment(\.complicationPreviewTint) private var tint

    var body: some View {
        ZStack {
            ArcTrack(fraction: 1).stroke(Color.white.opacity(0.25), style: StrokeStyle(lineWidth: 4, lineCap: .round))
            if let snapshot {
                ArcTrack(fraction: snapshot.fraction)
                    .stroke(tint ?? .folitoAccent, style: StrokeStyle(lineWidth: 4, lineCap: .round))
            }
            ComplicationView(snapshot: snapshot, family: .accessoryCorner)
                .frame(width: 28, height: 28)
                .offset(x: 10, y: 10)
        }
    }
}

private struct ArcTrack: Shape {
    let fraction: Double
    func path(in rect: CGRect) -> Path {
        // A quarter arc around the bottom-right corner, like the bezel at the top-left of a face.
        var p = Path()
        let r = min(rect.width, rect.height) - 4
        let center = CGPoint(x: rect.maxX, y: rect.maxY)
        p.addArc(center: center, radius: r, startAngle: .degrees(180), endAngle: .degrees(180 + 90 * max(fraction, 0.001)),
                 clockwise: false)
        return p
    }
}
