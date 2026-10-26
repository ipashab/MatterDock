import AppKit
import Testing
import MatterMacModels
import MatterMacCore
import TestSupport
@testable import MatterMacUI

@MainActor
@Suite("Reaction picker and emoji rendering")
struct ReactionPickerTests {
    private final class Spy {
        var picked: [String] = []
        var cancels = 0
    }

    private func makePicker() -> (ReactionPickerViewController, NSWindow, Spy) {
        let picker = ReactionPickerViewController()
        let spy = Spy()
        picker.onPick = { spy.picked.append($0) }
        picker.onCancel = { spy.cancels += 1 }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: ReactionPickerViewController.preferredSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = picker
        window.contentView?.layoutSubtreeIfNeeded()
        return (picker, window, spy)
    }

    private func command(_ picker: ReactionPickerViewController, _ selector: Selector) {
        _ = picker.control(picker.searchField, textView: NSTextView(), doCommandBy: selector)
    }

    private func search(_ picker: ReactionPickerViewController, _ text: String) {
        picker.searchField.stringValue = text
        picker.controlTextDidChange(Notification(name: NSControl.textDidChangeNotification, object: picker.searchField))
    }

    @Test func browseStartsWithStaticFrequentRowAndReturnPicksFirst() {
        let (picker, window, spy) = makePicker()
        defer { window.close() }
        #expect(picker.sections.first?.emoji.map(\.name) == EmojiCatalog.defaultQuickReactions)
        #expect(picker.sections.count == 1 + EmojiCategory.allCases.filter(\.isShownInPicker).count)
        #expect(picker.selectedEmoji?.name == "+1")
        command(picker, #selector(NSResponder.insertNewline(_:)))
        #expect(spy.picked == ["+1"])
    }

    @Test func arrowKeysMoveTheSelectionAndAnnounceIt() {
        let (picker, window, spy) = makePicker()
        defer { window.close() }
        command(picker, #selector(NSResponder.moveRight(_:)))
        #expect(picker.selectedEmoji?.name == "smile")
        #expect(picker.lastAnnouncement == "smile")
        command(picker, #selector(NSResponder.moveLeft(_:)))
        command(picker, #selector(NSResponder.moveLeft(_:)))
        #expect(picker.selectedEmoji?.name == "+1", "stops at the first item")
        // The frequent row is shorter than a grid row: Down enters the next section.
        command(picker, #selector(NSResponder.moveDown(_:)))
        #expect(picker.selection?.section == 1)
        #expect(picker.selectedEmoji?.name == "grinning")
        command(picker, #selector(NSResponder.moveDown(_:)))
        #expect(picker.selection == IndexPath(item: picker.columnCount, section: 1))
        command(picker, #selector(NSResponder.moveUp(_:)))
        command(picker, #selector(NSResponder.moveUp(_:)))
        #expect(picker.selection == IndexPath(item: 0, section: 0))
        command(picker, #selector(NSResponder.moveRight(_:)))
        command(picker, #selector(NSResponder.moveRight(_:)))
        command(picker, #selector(NSResponder.moveRight(_:)))
        command(picker, #selector(NSResponder.insertNewline(_:)))
        #expect(spy.picked == ["heart"])
    }

    @Test func searchFiltersAndReturnPicksTheFirstResult() {
        let (picker, window, spy) = makePicker()
        defer { window.close() }
        search(picker, "tad")
        #expect(picker.sections.count == 1)
        #expect(picker.selectedEmoji?.name == "tada")
        command(picker, #selector(NSResponder.insertNewline(_:)))
        #expect(spy.picked == ["tada"])
        // An alias resolves to the primary name that is sent to the server.
        search(picker, "thumbsup")
        command(picker, #selector(NSResponder.insertNewline(_:)))
        #expect(spy.picked == ["tada", "+1"])
        search(picker, "zzqqxx")
        #expect(picker.sections.isEmpty)
        #expect(picker.selectedEmoji == nil)
        command(picker, #selector(NSResponder.insertNewline(_:)))
        #expect(spy.picked.count == 2)
        search(picker, "")
        #expect(picker.selectedEmoji?.name == "+1")
    }

    @Test func escapeCancelsAndClickPicks() {
        let (picker, window, spy) = makePicker()
        defer { window.close() }
        command(picker, #selector(NSResponder.cancelOperation(_:)))
        #expect(spy.cancels == 1)
        #expect(spy.picked.isEmpty)
        picker.collectionView(picker.collectionView, didSelectItemsAt: [IndexPath(item: 2, section: 0)])
        #expect(spy.picked == ["white_check_mark"])
        // Clicking the highlighted item also picks: the collection view's own
        // selection is kept empty so the click always reports.
        picker.apply(query: "")
        let first = IndexPath(item: 0, section: 0)
        picker.collectionView.selectItems(at: [first], scrollPosition: [])
        picker.collectionView(picker.collectionView, didSelectItemsAt: [first])
        #expect(spy.picked == ["white_check_mark", "+1"])
        #expect(picker.collectionView.selectionIndexPaths.isEmpty)
    }

    /// Правила жеста удержания: превью по порогу, отпускание после превью
    /// не выбирает, быстрый клик выбирает, дрейф наружу отменяет.
    @Test func holdGestureRules() {
        // Удержание дольше порога: превью показали, отпускание НЕ выбирает —
        // «зажали — посмотрели».
        let slow = EmojiHoldGesture(threshold: 0.35)
        slow.press()
        #expect(!slow.tick(now: Date(timeIntervalSinceNow: 0.1)), "рано — без превью")
        #expect(slow.tick(now: Date(timeIntervalSinceNow: 0.4)), "порог пройден — превью")
        #expect(!slow.tick(now: Date(timeIntervalSinceNow: 0.5)), "повторно превью не показываем")
        slow.dragged(inside: false)
        slow.dragged(inside: true)
        #expect(!slow.release(), "после превью отпускание не выбирает")

        // Быстрый клик без превью и без дрейфа — выбирает.
        let quick = EmojiHoldGesture(threshold: 0.35)
        quick.press()
        #expect(!quick.tick(now: Date(timeIntervalSinceNow: 0.1)))
        #expect(quick.release())

        // Дрейф наружу без превью — отпускание там же не выбирает.
        let drift = EmojiHoldGesture(threshold: 10)
        drift.press()
        drift.dragged(inside: false)
        #expect(!drift.release())

        // Дрейф наружу и обратно до порога, отпускание внутри — выбирает.
        let back = EmojiHoldGesture(threshold: 0.35)
        back.press()
        back.dragged(inside: false)
        back.dragged(inside: true)
        #expect(back.tick(now: Date(timeIntervalSinceNow: 1)), "вернулись на ячейку — превью")
        #expect(!back.release())
    }

    /// Панель превью: системный эмодзи — крупный глиф, без выбора; кастомный —
    /// подоспевшая картинка.
    @Test func showEmojiPreviewUsesTheCellContentWithoutPicking() throws {
        let (picker, window, spy) = makePicker()
        defer { window.close() }
        let path = IndexPath(item: 1, section: 0)
        _ = try #require(picker.collectionView.item(at: path) as? EmojiPickerItem)
        picker.showEmojiPreview(at: path)
        #expect(picker.holdPreviewPath == path)
        #expect(!picker.holdPreview.isHidden)
        #expect(!picker.holdPreview.displayedText.isEmpty)
        #expect(picker.holdPreview.displayedImage == nil, "системный эмодзи — глиф, не картинка")
        picker.hideEmojiPreview()
        #expect(picker.holdPreviewPath == nil)
        #expect(picker.holdPreview.isHidden)
        #expect(spy.picked.isEmpty, "превью не отправляет выбор")
    }

    /// Превью стоит над ячейкой по центру, у верхней границы спускается вниз и
    /// не выходит за края пикера.
    @Test func holdPreviewFrameStaysInsideThePicker() {
        let bounds = NSRect(x: 0, y: 0, width: 320, height: 400)
        let cell = NSRect(x: 100, y: 200, width: 36, height: 36)
        let above = ReactionPickerViewController.holdPreviewFrame(cell: cell, bounds: bounds, side: 88)
        #expect(above.midX == cell.midX)
        #expect(above.minY == cell.maxY + 6)

        // Ячейка у верхней границы — превью вниз, внутрь границ.
        let topCell = NSRect(x: 100, y: 350, width: 36, height: 36)
        let top = ReactionPickerViewController.holdPreviewFrame(cell: topCell, bounds: bounds, side: 88)
        #expect(top.maxY < bounds.maxY)
        #expect(top.maxY < topCell.minY, "превью уходит под ячейку, а не за верх")

        // Ячейка у левого края — по горизонтали клампится внутрь.
        let left = ReactionPickerViewController.holdPreviewFrame(cell: NSRect(x: -10, y: 200, width: 36, height: 36),
                                                                 bounds: bounds, side: 88)
        #expect(left.minX >= 4)
        #expect(left.minX == bounds.minX + 4)
    }

    @Test func itemsExposeTheEmojiNameToVoiceOver() throws {
        let (picker, window, _) = makePicker()
        defer { window.close() }
        let item = picker.collectionView(picker.collectionView, itemForRepresentedObjectAt: IndexPath(item: 2, section: 0))
        #expect(item.view.accessibilityLabel() == "white check mark")
        #expect(item.view.accessibilityRole() == .button)
        #expect(item.view.toolTip == ":white_check_mark:")
        #expect((item as? EmojiPickerItem)?.isCurrent == false)
        let current = picker.collectionView(picker.collectionView, itemForRepresentedObjectAt: IndexPath(item: 0, section: 0))
        #expect((current as? EmojiPickerItem)?.isCurrent == true)
        #expect(current.view.isAccessibilitySelected())
    }

    @Test func timelineRendersGlyphsAndGivesARowAnchor() throws {
        let c = TimelineViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: 480),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.isRestorable = false
        window.contentViewController = c
        defer { c.removeAllContent(); window.close() }
        c.emojiLookup = { EmojiCatalog.system.glyph(for: $0) }
        let post = CoreFixtures.post(1, channel: CoreFixtures.channel(1).id)
        let reactions = [ReactionGroup(emojiName: "+1", count: 2, includesCurrentUser: true),
                         ReactionGroup(emojiName: "party_parrot", count: 1, includesCurrentUser: false)]
        c.apply(TimelineSnapshot(scope: AccountScope(server: ServerSlotID(1), user: CoreFixtures.me.id),
                                 target: .channel(CoreFixtures.channel(1).id), generation: 1,
                                 items: [item(post, text: "Done :tada: :party_parrot:", reactions: reactions)],
                                 isAtLiveEdge: true, isStale: false, scrollRequest: nil))
        window.contentView?.layoutSubtreeIfNeeded()
        let cell = try #require(c.tableView.view(atColumn: 0, row: 0, makeIfNecessary: true) as? MessageCellView)
        #expect(cell.displayedBodyText == "Done 🎉 :party_parrot:")
        let chips = cell.subviews.compactMap { $0 as? ReactionChipView }.filter { !$0.isHidden }
        #expect(chips.map(\.emoji) == ["👍", ":party_parrot:"])
        // Подсказку реакторов рисует ReactionHoverPanel; чипы остаются доступны
        // VoiceOver через accessibilityHelp.
        #expect(chips.map { $0.accessibilityHelp() ?? "" }
            == ["You and 1 other reacted with :+1:", "1 person reacted with :party_parrot:"])
        #expect(chips.allSatisfy { $0.toolTip == nil })
        #expect(chips.first?.accessibilityLabel()?.contains("+1") == true)
        #expect(c.anchorRect(for: post.id) != nil)
        #expect(c.anchorRect(for: CoreFixtures.post(9, channel: post.channelID).id) == nil)
    }

    private func item(_ post: Post, text: String, reactions: [ReactionGroup]) -> TimelineItem {
        TimelineItem(id: TimelineItemID(.post(post.id)), revision: 1, content: .post(
            PostPresentation(postID: post.id, pendingID: nil, channelID: post.channelID, rootID: nil,
                author: AuthorPresentation(userID: CoreFixtures.bob.id, displayName: "Bob", username: "bob",
                                           isBot: false, isCurrentUser: false, avatarRevision: 0),
                createdAt: post.createAt, isContinuation: false,
                body: .document(MarkupParser.parse(text), isCollapsed: false), isEdited: false,
                isPinned: false, files: [], reactions: reactions, replyCount: 0, showsThreadContext: false,
                sendState: nil, actions: .none, permalink: nil)))
    }
}

/// Вкладки категорий в шапке пикера (ADR 0059): иконки разделов, клик —
/// прокрутка к разделу, активная вкладка следует за скроллом.
@MainActor
@Suite("Reaction picker categories")
struct ReactionPickerCategoryTests {
    @Test func barMirrorsBrowseSectionsAndScrolls() throws {
        let picker = ReactionPickerViewController()
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: ReactionPickerViewController.preferredSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = picker
        window.contentView?.layoutSubtreeIfNeeded()

        // Вкладки: «Часто используемые» + все категории каталога; «Пользовательские»
        // не показана, пока серверная страница не загрузилась.
        let expected = [String(localized: "Frequently Used")]
            + EmojiCategory.allCases.filter(\.isShownInPicker).map(\.displayName)
        #expect(picker.categoryTitlesForTesting == expected)
        #expect(picker.categoryButtons.allSatisfy { $0.toolTip != nil && $0.image != nil })
        #expect(picker.customCategoryButton?.isHidden == true)
        #expect(picker.categoryBar.isHidden == false)

        // Клик по вкладке прокручивает сетку к шапке раздела и подсвечивает вкладку.
        picker.scrollToCategory(2)
        window.contentView?.layoutSubtreeIfNeeded()
        #expect(picker.activeCategoryForTesting == 2, "после прокрутки активна вкладка целевой категории")
        #expect(picker.categoryButtons[2].contentTintColor == NSColor.controlAccentColor)
        #expect(picker.categoryButtons[0].contentTintColor == NSColor.secondaryLabelColor)
        window.orderOut(nil)
    }

    @Test func searchHidesTheBarAndCustomTabAppearsAfterPageLoads() async throws {
        let picker = ReactionPickerViewController()
        picker.customPage = { _, _ in [CustomEmoji(id: "c1", name: "gifka")] }
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: ReactionPickerViewController.preferredSize),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentViewController = picker
        window.contentView?.layoutSubtreeIfNeeded()

        // Поиск прячет вкладки; очистка возвращает их.
        picker.apply(query: "smile")
        #expect(picker.categoryBar.isHidden == true)
        picker.apply(query: "")
        #expect(picker.categoryBar.isHidden == false)

        // Серверная страница пользовательских эмодзи добавляет вкладку.
        picker.loadCustomPage()
        let deadline = Date().addingTimeInterval(2)
        while Date() < deadline, picker.customCategoryButton?.isHidden != false {
            try await Task.sleep(for: .milliseconds(20))
            window.contentView?.layoutSubtreeIfNeeded()
        }
        #expect(picker.customCategoryButton?.isHidden == false, "вкладка «Пользовательские» появилась")
        #expect(picker.customCategoryButton?.tag == picker.categoryButtons.count)
        picker.scrollToCategory(picker.customCategoryButton?.tag ?? 0)
        #expect(picker.activeCategoryForTesting == picker.categoryButtons.count)
        window.orderOut(nil)
    }
}
