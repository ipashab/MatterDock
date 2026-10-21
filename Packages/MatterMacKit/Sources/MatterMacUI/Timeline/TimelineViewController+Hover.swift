import AppKit
import MatterMacModels
import MatterMacCore

/// Hover handling: one `HoverActionBar` overlay for the hovered message row (or, when
/// the pointer is not over a message, the single selected row), a subtle hover
/// background, and the continuation-row timestamp. Driven by a mouse-moved tracking area
/// on the container, scrolling, snapshot application and selection changes; there is
/// no repeating timer. While the user scrolls, the bar and highlight stay hidden and
/// return once the scroll settles (live-scroll end, or a short one-shot delay after the
/// last wheel step). Nothing here changes row heights.
extension TimelineViewController {
    func installHoverBar(in container: NSView) {
        hoverBar.onAction = { [weak self] action in self?.performPrepared(action) }
        hoverBar.onMore = { [weak self] button in self?.presentMoreMenu(from: button) }
        container.addSubview(hoverBar)
        container.addSubview(reactionPanel)
    }

    // MARK: - Events

    func hoverMouseMoved(_ event: NSEvent) {
        hoverPointerLocation = event.locationInWindow
        updateHover()
    }

    func hoverMouseExited() {
        hoverPointerLocation = nil
        updateHover()
    }

    /// Re-evaluates the hovered row after scrolling, content or selection changes.
    func refreshHover() {
        guard isViewLoaded else { return }
        if hoverPointerLocation != nil, NSApp.isActive, let window = view.window, window.isKeyWindow {
            // The pointer may have stayed still while rows moved beneath it.
            hoverPointerLocation = window.mouseLocationOutsideOfEventStream
        }
        updateHover()
    }

    // MARK: - Scrolling

    static let hoverScrollSettleDelay: Duration = .milliseconds(200)

    /// A user scroll moved the rows: hide the hover until scrolling settles, so the bar
    /// does not flicker from row to row under a still pointer.
    func suspendHoverForScroll() {
        hoverScrollSettleTask?.cancel()
        hoverScrollSettleTask = nil
        isHoverSuspendedByScroll = true
        // A live (trackpad) scroll ends with `didEndLiveScroll`, after any momentum.
        guard !isLiveScrolling else { return }
        hoverScrollSettleTask = Task { [weak self] in
            try? await Task.sleep(for: Self.hoverScrollSettleDelay)
            guard !Task.isCancelled else { return }
            self?.resumeHoverAfterScroll()
        }
    }

    func resumeHoverAfterScroll() {
        hoverScrollSettleTask?.cancel()
        hoverScrollSettleTask = nil
        guard isHoverSuspendedByScroll, !isLiveScrolling else { return }
        isHoverSuspendedByScroll = false
        refreshHover()
    }

    @objc func liveScrollWillStart(_ notification: Notification) {
        isLiveScrolling = true
        suspendHoverForScroll()
        updateHover()
    }

    @objc func liveScrollDidEnd(_ notification: Notification) {
        isLiveScrolling = false
        resumeHoverAfterScroll()
    }

    // MARK: - State

    /// The message row the bar belongs to: the row under the pointer (kept while the
    /// pointer is over the bar itself), else the only selected row.
    func hoverTargetRow() -> (row: Int, isPointer: Bool)? {
        if let location = hoverPointerLocation {
            let local = view.convert(location, from: nil)
            if !hoverBar.isHidden, hoverBar.frame.contains(local), let id = hoverBar.itemID, let row = rowIndex[id] {
                return (row, true)
            }
            // Наведённая панель реакторов сохраняет свою строку (она лежит над строкой).
            if !reactionPanel.isHidden, reactionPanel.frame.contains(local), let id = reactionPanel.itemID,
               let row = rowIndex[id] {
                return (row, true)
            }
            let clip = scrollView.contentView
            if clip.bounds.contains(clip.convert(location, from: nil)), !isPointerOccluded(at: location) {
                let row = tableView.row(at: tableView.convert(location, from: nil))
                if items.indices.contains(row), items[row].post?.postID != nil { return (row, true) }
            }
        }
        let selected = tableView.selectedRowIndexes
        if selected.count == 1, let row = selected.first, items.indices.contains(row), items[row].post != nil {
            return (row, false)
        }
        return nil
    }

    /// Whether something drawn over the timeline is under the pointer: the floating
    /// composer, the jump-to-latest pill, toasts and banners, the image viewer.
    /// The rows beneath them are not hovered.
    func isPointerOccluded(at location: NSPoint) -> Bool {
        guard let window = view.window, let frame = window.contentView?.superview ?? window.contentView,
              let hit = frame.hitTest(frame.convert(location, from: nil)) else { return false }
        return !hit.isDescendant(of: tableView)
    }

    func updateHover() {
        if isHoverSuspendedByScroll {
            setHoverHighlight(nil)
            setHoverTimestamp(nil)
            hoverBar.reset()
            reactionPanel.reset()
            return
        }
        let target = hoverTargetRow()
        let pointerID = target.flatMap { $0.isPointer ? items[$0.row].id : nil }
        setHoverHighlight(pointerID)
        setHoverTimestamp(target.map { items[$0.row].id })
        guard let target, let post = items[target.row].post,
              hoverBar.configure(item: items[target.row].id, post: post, quickReactions: quickReactions,
                                 emojiText: { [renderer] in renderer.emojiText(for: $0) })
        else {
            hoverBar.reset()
            reactionPanel.reset()
            return
        }
        positionHoverBar(row: target.row)
        updateReactionPanel(row: target.row, isPointer: target.isPointer)
    }

    func positionHoverBar(row: Int) {
        let rowRect = view.convert(tableView.rect(ofRow: row), from: tableView)
        let clip = view.convert(scrollView.contentView.bounds, from: scrollView.contentView)
        let visibleRow = rowRect.intersection(clip)
        guard !visibleRow.isNull, visibleRow.height > 4 else {
            hoverBar.reset()
            return
        }
        let width = hoverBar.preferredWidth
        let height = HoverActionBar.height
        let x = max(clip.minX + 4, rowRect.maxX - width - TimelineRowMetrics.horizontalInset)
        // Straddle the row's top edge (like the official client), kept inside the viewport.
        var frame: NSRect
        if view.isFlipped {
            let top = min(max(rowRect.minY - height / 2 + 4, clip.minY + 2), clip.maxY - height - 2)
            frame = NSRect(x: x, y: top, width: width, height: height)
        } else {
            let bottom = max(min(rowRect.maxY - height / 2 - 4, clip.maxY - height - 2), clip.minY + 2)
            frame = NSRect(x: x, y: bottom, width: width, height: height)
        }
        frame = frame.integral
        if hoverBar.frame != frame { hoverBar.frame = frame }
        hoverBar.isHidden = false
        hoverBar.needsLayout = true
    }

    private func setHoverHighlight(_ id: TimelineItemID?) {
        guard id != hoverHighlightedID else { return }
        if let old = hoverHighlightedID, let row = rowIndex[old] {
            (tableView.rowView(atRow: row, makeIfNecessary: false) as? TimelineRowView)?.isHovered = false
        }
        hoverHighlightedID = id
        if let id, let row = rowIndex[id] {
            (tableView.rowView(atRow: row, makeIfNecessary: false) as? TimelineRowView)?.isHovered = true
        }
    }

    private func setHoverTimestamp(_ id: TimelineItemID?) {
        guard id != hoverTimestampID else { return }
        if let old = hoverTimestampID, let row = rowIndex[old] {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView)?.setHovered(false)
        }
        hoverTimestampID = id
        if let id, let row = rowIndex[id] {
            (tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView)?.setHovered(true)
        }
    }

    // MARK: - Панель реакторов

    /// Панель «кто отреагировал» у чипа под курсором — мгновенно, как в
    /// веб-клиенте (нативный toolTip появляется только с системной задержкой).
    func updateReactionPanel(row: Int, isPointer: Bool) {
        guard isPointer, let location = hoverPointerLocation else {
            reactionPanel.reset()
            return
        }
        let local = view.convert(location, from: nil)
        if !reactionPanel.isHidden, reactionPanel.frame.contains(local) { return }
        guard let cell = tableView.view(atColumn: 0, row: row, makeIfNecessary: false) as? MessageCellView,
              let hit = cell.reactionChip(at: cell.convert(location, from: nil)) else {
            reactionPanel.reset()
            return
        }
        reactionPanel.configure(item: items[row].id, emojiName: hit.group.emojiName,
                                names: TimelineStrings.reactorPanelNames(hit.group, emoji: { [renderer] in
                                    renderer.emojiText(for: $0)
                                }),
                                hint: hit.group.includesCurrentUser ? TimelineStrings.reactionRemoveHint
                                                                    : TimelineStrings.reactionAddHint)
        positionReactionPanel(cell: cell, chipInCell: hit.frame)
    }

    func positionReactionPanel(cell: MessageCellView, chipInCell: CGRect) {
        let clip = view.convert(scrollView.contentView.bounds, from: scrollView.contentView)
        let chip = view.convert(chipInCell, from: cell)
        let frame = Self.reactionPanelFrame(chip: chip, panelSize: reactionPanel.preferredSize, clip: clip,
                                            flipped: view.isFlipped)
        if reactionPanel.frame != frame { reactionPanel.frame = frame }
        reactionPanel.isHidden = false
    }

    /// Позиция панели под чипом; не влезает снизу — над чипом; всегда внутри
    /// видимой области (координаты контейнера, flipped или нет).
    static func reactionPanelFrame(chip: CGRect, panelSize: CGSize, clip: CGRect, flipped: Bool) -> CGRect {
        let gap: CGFloat = 4
        let x = min(max(chip.minX, clip.minX + 4), max(clip.minX + 4, clip.maxX - panelSize.width - 4))
        let below = flipped ? chip.maxY + gap : chip.minY - panelSize.height - gap
        let above = flipped ? chip.minY - panelSize.height - gap : chip.maxY + gap
        let fitsBelow = below >= clip.minY + 2 && below + panelSize.height <= clip.maxY - 2
        var y = fitsBelow ? below : above
        y = min(max(y, clip.minY + 2), max(clip.minY + 2, clip.maxY - panelSize.height - 2))
        return NSRect(x: x.rounded(), y: y.rounded(), width: panelSize.width, height: panelSize.height)
    }

    // MARK: - Menus

    /// The "More" menu: the row's context-menu items.
    func moreMenu(for postID: PostID) -> NSMenu? {
        guard let row = rowIndex[TimelineItemID(.post(postID))], let post = items[row].post else { return nil }
        let menu = NSMenu()
        populate(menu, post: post)
        return menu.items.isEmpty ? nil : menu
    }

    func presentMoreMenu(from button: NSButton) {
        guard let postID = hoverBar.postID, let menu = moreMenu(for: postID) else { return }
        menu.popUp(positioning: nil, at: NSPoint(x: 0, y: button.bounds.maxY + 4), in: button)
    }

    /// Keyboard access to the actions of the selected row (Control-Return).
    func presentActionsMenuForSelection() -> Bool {
        let row = tableView.selectedRow
        guard items.indices.contains(row), let post = items[row].post, post.postID != nil else { return false }
        let menu = NSMenu()
        populate(menu, post: post)
        guard !menu.items.isEmpty else { return false }
        updateHover()
        if !hoverBar.isHidden, hoverBar.postID == post.postID, let more = hoverBar.button(.more) {
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: more.bounds.maxY + 4), in: more)
        } else {
            let rect = tableView.rect(ofRow: row)
            menu.popUp(positioning: nil, at: NSPoint(x: TimelineRowMetrics.contentLeading, y: rect.minY + 20), in: tableView)
        }
        return true
    }
}
