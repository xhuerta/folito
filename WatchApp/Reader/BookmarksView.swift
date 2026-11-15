import SwiftUI
import ReaderCore

/// "Add Bookmark" in the reader menu (#65): marks the line at the top of the screen. Once that line is
/// bookmarked it reads "Bookmarked" and is dimmed (VoiceOver: "Bookmarked, dimmed"), so the same place is
/// never added twice.
struct AddBookmarkButton: View {
    let isBookmarked: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if isBookmarked {
                Label("Bookmarked", systemImage: "bookmark.fill")
            } else {
                Label("Add Bookmark", systemImage: "bookmark")
            }
        }
        .disabled(isBookmarked)
        .accessibilityHint(Text("Bookmarks the line at the top of the screen.",
                                comment: "VoiceOver hint of 'Add Bookmark' in the reader menu"))
        .accessibilityIdentifier("addBookmarkButton")
    }
}

/// The reader menu's row that opens the bookmark list, with how many there are. VoiceOver reads it as one
/// element ("All Bookmarks, 3").
struct BookmarksLinkLabel: View {
    let count: Int

    var body: some View {
        HStack {
            Label("All Bookmarks", systemImage: "list.bullet")
            Spacer(minLength: 4)
            Text(count, format: .number)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }
}

/// The book's bookmarks, newest first: chapter, the first words at the mark and how far into the book it is.
/// A tap opens the book there; swipe left (or the VoiceOver action) deletes one.
struct BookmarksView: View {
    @ObservedObject var model: ReaderViewModel
    /// Jumps to the bookmark and closes the reader menu.
    let onSelect: (Bookmark) -> Void

    var body: some View {
        List {
            if model.bookmarks.isEmpty {
                Text("No bookmarks in this book.",
                     comment: "Shown in the bookmark list of the reader menu once every bookmark was deleted")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .listRowBackground(Color.clear)
                    .accessibilityIdentifier("noBookmarks")
            } else {
                ForEach(model.bookmarks.items) { bookmark in
                    BookmarkRowView(bookmark: bookmark,
                                    onSelect: { onSelect(bookmark) },
                                    onDelete: { model.deleteBookmark(id: bookmark.id) })
                }
                .onDelete { model.deleteBookmarks(atOffsets: $0) }
            }
        }
        .navigationTitle(Text("Bookmarks"))
    }
}

/// One bookmark: the chapter (when it has a title), the snippet and the percentage, all wrapping at large
/// Dynamic Type sizes. VoiceOver reads the three as one button, with a Delete action next to the swipe.
struct BookmarkRowView: View {
    let bookmark: Bookmark
    let onSelect: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: 2) {
                if let chapter = bookmark.chapterTitle {
                    Text(chapter)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.tint)
                        .lineLimit(2)
                }
                if !bookmark.snippet.isEmpty {
                    Text(bookmark.snippet)
                        .lineLimit(3)
                }
                Text(ReadingProgressFormat.percent(bookmark.percentage))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityHint(Text("Opens the book at this bookmark.",
                                comment: "VoiceOver hint of a bookmark in the reader menu's bookmark list"))
        .accessibilityAction(named: Text("Delete Bookmark")) { onDelete() }
        .accessibilityIdentifier("bookmarkRow")
    }
}
