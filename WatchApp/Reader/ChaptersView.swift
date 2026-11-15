import SwiftUI
import ReaderCore

/// The reader menu's row that opens the chapter list (#172), with the current chapter's title as its value.
/// VoiceOver reads it as one element ("Chapters, Down the Rabbit-Hole"); in front matter before the first TOC
/// entry it reads "Chapters" alone.
struct ChaptersLinkLabel: View {
    let currentTitle: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Label("Chapters", systemImage: "list.bullet.indent")
            if let currentTitle, !currentTitle.isEmpty {
                Text(currentTitle)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}

/// The book's chapter list, pushed from the reader menu (#172). It opens scrolled to the current chapter, which
/// is marked with a checkmark (VoiceOver: "selected"); a tap jumps there and closes the menu.
struct ChaptersView: View {
    @ObservedObject var model: ReaderViewModel
    /// Jumps to the row's start and closes the reader menu.
    let onSelect: (FlatBook.ContentsRow) -> Void

    var body: some View {
        let current = model.currentContentsRow
        ScrollViewReader { proxy in
            List {
                ForEach(Array(model.flat.contents.enumerated()), id: \.offset) { offset, row in
                    ContentsRowView(row: row, isCurrent: offset == current) {
                        if row.startIndex != nil { onSelect(row) }
                    }
                    .id(offset)
                }
            }
            .onAppear {
                // Books can list hundreds of entries: open on the current one.
                if let current { proxy.scrollTo(current, anchor: .center) }
            }
        }
        .navigationTitle(Text("Chapters"))
    }
}

extension ReaderViewModel {
    /// Row of the chapter list marked as the current one (nil in front matter before the first TOC entry).
    var currentContentsRow: Int? {
        flat.currentContentsRow(at: currentIndex, characterOffset: currentOffset)
    }

    /// Title of the current row of the chapter list, shown as the value of the menu's Chapters row.
    var currentContentsTitle: String? {
        guard let row = currentContentsRow, flat.contents.indices.contains(row) else { return nil }
        let title = flat.contents[row].title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? nil : title
    }
}

/// A row of the chapter list: a chapter (marked with a checkmark when it is the current one), or a group header
/// above the chapters ("Part One") in a TOC. VoiceOver reads the group with an indented chapter
/// ("Chapter 3, in Part One") and says "selected" for the current row.
struct ContentsRowView: View {
    let row: FlatBook.ContentsRow
    let isCurrent: Bool
    let action: () -> Void

    var body: some View {
        if row.kind == .group, row.startIndex == nil {
            label
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(spokenTitle)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("chapterGroup")
        } else {
            Button(action: action) { label }
                .accessibilityLabel(spokenTitle)
                // The checkmark is visual only: VoiceOver says "selected" instead.
                .accessibilityAddTraits(isCurrent ? .isSelected : [])
                .accessibilityAddTraits(row.kind == .group ? .isHeader : [])
                .accessibilityIdentifier(row.kind == .group ? "chapterGroup" : "chapterButton")
        }
    }

    private var label: some View {
        HStack {
            title
            if isCurrent {
                Spacer(minLength: 4)
                Image(systemName: "checkmark")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
            }
        }
        .padding(.leading, row.isIndented ? 8 : 0)
    }

    @ViewBuilder private var title: some View {
        if row.kind == .group {
            Text(row.title)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .lineLimit(3)
        } else {
            Text(row.title).lineLimit(3)
        }
    }

    private var spokenTitle: Text {
        guard row.isIndented, let group = row.groupTitle else { return Text(row.title) }
        return Text("\(row.title), in \(group)",
                    comment: "VoiceOver label of a chapter in the reader's chapter list, with the part it belongs to, e.g. 'Chapter 3, in Part One'")
    }
}
