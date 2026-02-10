import AVFoundation
import SwiftUI

struct Idea: Identifiable, Equatable {
    let id: String
    var title: String
    var insight: String
    var videoFileName: String? = nil
}

struct TodoItem: Identifiable, Equatable {
    let id: String
    var title: String
    var isAccepted: Bool = false
}

struct NotificationItem: Identifiable, Equatable {
    let id: String
    var title: String
    var date: Date
}

struct EggComment: Identifiable, Equatable {
    let id: String
    var user: String
    var text: String
    var date: Date
    var scope: Scope

    enum Scope {
        case myEgg
        case community
    }
}

private enum LibraryTab: String, CaseIterable {
    case ideas = "Ideas"
    case todos = "Todos"
    case alerts = "Alerts"
    case comments = "Comments"
}

struct LibraryView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var viewModel: EggtartViewModel

    @State private var selectedTab: LibraryTab = .ideas
    @State private var isRefreshing: Bool = false
    @State private var refreshMessage: String?

    @State private var ideas: [Idea] = []
    @State private var todos: [TodoItem] = []
    @State private var notifications: [NotificationItem] = []
    @State private var comments: [EggComment] = []

    @State private var commentDates: [Date] = LibraryView.defaultCommentDates()
    @State private var selectedCommentIndex: Int = 0

    @State private var editingTodoID: String?
    @State private var editingTodoText: String = ""
    @State private var showNotificationAlert: Bool = false
    @State private var editingNotification: NotificationItem?
    @State private var latestTabHashes: [LibraryTab: Int] = [:]
    @State private var seenTabHashes: [LibraryTab: Int] = [:]
    @State private var lastAppliedDemoPayloadVersion: Int = 0

    private let pageBackground = Color(red: 0.96, green: 0.97, blue: 0.98)
    private let seenTabHashKeyPrefix = "eggtart.eggbook.seenHash."

    var body: some View {
        NavigationStack {
            VStack(spacing: 12) {
                Text("egg book")
                    .font(.system(size: 44, weight: .bold, design: .rounded))
                    .frame(maxWidth: .infinity, alignment: .leading)

                if let syncText = syncStatusText {
                    SyncStatusStrip(text: syncText, processing: viewModel.hasProcessingEvents)
                }

                if let refreshMessage {
                    Text(refreshMessage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }

                tabBar

                Group {
                    switch selectedTab {
                    case .ideas:
                        ideasView
                    case .todos:
                        todosView
                    case .alerts:
                        alertsView
                    case .comments:
                        commentsView
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .padding(.bottom, 12)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
            .background(pageBackground.ignoresSafeArea())
            .alert("notification added", isPresented: $showNotificationAlert) {
                Button("OK", role: .cancel) {}
            }
            .sheet(item: $editingNotification) { item in
                NotificationDateEditor(item: item) { updated in
                    updateNotification(updated)
                }
            }
            .task {
                loadSeenTabHashesIfNeeded()
                await manualRefresh(showSuccessMessage: false)
                applyDemoPayload(markAsNew: false)
            }
            .onChange(of: selectedTab) { _, tab in
                markTabAsSeen(tab)
            }
            .onChange(of: viewModel.demoPayloadVersion) { _, _ in
                applyDemoPayload(markAsNew: true)
            }
        }
    }

    private var syncStatusText: String? {
        if selectedTab != .comments, let demoText = viewModel.demoSyncBannerText {
            return demoText
        }
        if selectedTab != .comments && viewModel.hasUploadProcessingPending && viewModel.hasProcessingEvents {
            return "New items are processing..."
        }
        if selectedTab != .comments && hasUnreadInNonCommentTabs {
            return "Updated."
        }
        return nil
    }

    private var tabBar: some View {
        HStack(spacing: 8) {
            ForEach(LibraryTab.allCases, id: \.self) { tab in
                tabButton(tab)
            }
        }
        .padding(6)
        .background(Color.black.opacity(0.05), in: Capsule())
    }

    private func tabButton(_ tab: LibraryTab) -> some View {
        let isSelected = selectedTab == tab
        return Button {
            selectedTab = tab
        } label: {
            ZStack(alignment: .topTrailing) {
                Text(tab.rawValue)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(isSelected ? Color.black : Color.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)
                    .frame(maxWidth: .infinity)

                if tabHasUpdateDot(tab) {
                    Circle()
                        .fill(Color.red)
                        .frame(width: 6, height: 6)
                        .offset(x: -6, y: 3)
                }
            }
            .padding(.vertical, 8)
            .background(isSelected ? Color.white : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private func tabHasUpdateDot(_ tab: LibraryTab) -> Bool {
        guard let latest = latestTabHashes[tab] else { return false }
        guard let seen = seenTabHashes[tab] else { return false }
        return latest != seen
    }

    private var ideasView: some View {
        List {
            Section {
                ForEach(ideas.indices, id: \.self) { index in
                    NavigationLink {
                        IdeaDetailView(ideas: ideas, index: index)
                    } label: {
                        Text(ideas[index].title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                            .padding(.vertical, 6)
                    }
                    .listRowBackground(cardBackground())
                    .listRowSeparator(.hidden)
                    .swipeActions {
                        Button(role: .destructive) {
                            deleteIdea(ideas[index])
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                sectionHeader("scrolling ideas")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .refreshable {
            await manualRefresh()
        }
    }

    private var todosView: some View {
        List {
            Section {
                ForEach(todos) { item in
                    todoRow(for: item)
                        .listRowBackground(cardBackground())
                        .listRowSeparator(.hidden)
                        .swipeActions {
                            Button(role: .destructive) {
                                deleteTodo(item)
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            } header: {
                sectionHeader("todo lists")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .refreshable {
            await manualRefresh()
        }
    }

    private var alertsView: some View {
        List {
            Section {
                ForEach(notifications) { item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title)
                                .font(.body.weight(.semibold))
                            Button {
                                editNotification(item)
                            } label: {
                                Text(Self.dateFormatter.string(from: item.date))
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }

                        Spacer()

                        Button {
                            editNotification(item)
                        } label: {
                            Image(systemName: "pencil")
                        }
                        .buttonStyle(.borderless)
                    }
                    .listRowBackground(cardBackground())
                    .listRowSeparator(.hidden)
                    .swipeActions {
                        Button(role: .destructive) {
                            deleteNotification(item)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                sectionHeader("notifications")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .refreshable {
            await manualRefresh()
        }
    }

    private var commentsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                if viewModel.commentsGenerating {
                    ProcessingBanner(text: "Generating today’s comments…")
                }

                Button {
                    viewModel.triggerCommentsGeneration(manual: true)
                } label: {
                    Text(viewModel.commentsGenerating ? "Generating…" : "Generate today’s comments")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .background(Color.black.opacity(0.65), in: Capsule())
                }
                .buttonStyle(.plain)
                .disabled(viewModel.commentsGenerating)

                Text("use arrows to change date")
                    .font(.footnote)
                    .foregroundStyle(.secondary)

                EggCommentsView(
                    dates: commentDates,
                    selectedIndex: $selectedCommentIndex,
                    comments: comments
                )

                Text("only show comments in the last 7 days")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.top, 6)
            }
            .padding(.top, 6)
        }
        .refreshable {
            await manualRefresh()
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        Text(title)
            .font(.footnote.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(nil)
            .padding(.bottom, 4)
    }

    private func cardBackground() -> some View {
        RoundedRectangle(cornerRadius: 16)
            .fill(Color.white)
            .shadow(color: Color.black.opacity(0.04), radius: 8, x: 0, y: 4)
    }

    private func todoRow(for item: TodoItem) -> some View {
        HStack(spacing: 12) {
            if editingTodoID == item.id {
                TextField("todo", text: $editingTodoText)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .onSubmit {
                        commitEdit(for: item)
                    }
            } else {
                Text(item.title)
                    .font(.body.weight(.semibold))
            }

            Spacer()

            if !item.isAccepted {
                Button {
                    acceptTodo(item)
                } label: {
                    Image(systemName: "checkmark.circle")
                }
                .buttonStyle(.borderless)
            }

            Button {
                moveTodoToNotifications(item)
            } label: {
                Image(systemName: "alarm")
            }
            .buttonStyle(.borderless)
        }
        .contentShape(Rectangle())
        .onTapGesture {
            beginEdit(item)
        }
        .padding(.vertical, 6)
    }

    private func beginEdit(_ item: TodoItem) {
        editingTodoID = item.id
        editingTodoText = item.title
    }

    private func commitEdit(for item: TodoItem) {
        guard let index = todos.firstIndex(of: item) else { return }
        let newTitle = editingTodoText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !newTitle.isEmpty else {
            editingTodoID = nil
            return
        }
        todos[index].title = newTitle
        editingTodoID = nil
        Task {
            do {
                _ = try await APIClient.shared.updateTodo(id: item.id, title: newTitle, isAccepted: nil)
            } catch {
                await MainActor.run {
                    self.refreshMessage = "Failed to update todo."
                }
            }
        }
    }

    private func acceptTodo(_ item: TodoItem) {
        guard let index = todos.firstIndex(of: item) else { return }
        todos[index].isAccepted = true
        let accepted = todos.remove(at: index)
        todos.insert(accepted, at: 0)

        Task {
            do {
                let dto = try await APIClient.shared.acceptTodo(id: item.id)
                await MainActor.run {
                    if let idx = todos.firstIndex(where: { $0.id == item.id }) {
                        todos[idx].isAccepted = dto.isAccepted
                    }
                }
            } catch {
                await MainActor.run {
                    self.refreshMessage = "Failed to accept todo."
                }
            }
        }
    }

    private func deleteIdea(_ item: Idea) {
        ideas.removeAll { $0.id == item.id }
        Task {
            do {
                _ = try await APIClient.shared.deleteIdea(id: item.id)
            } catch {
                await MainActor.run {
                    self.refreshMessage = "Failed to delete idea."
                }
            }
        }
    }

    private func deleteTodo(_ item: TodoItem) {
        todos.removeAll { $0.id == item.id }
        Task {
            do {
                _ = try await APIClient.shared.deleteTodo(id: item.id)
            } catch {
                await MainActor.run {
                    self.refreshMessage = "Failed to delete todo."
                }
            }
        }
    }

    private func moveTodoToNotifications(_ item: TodoItem) {
        deleteTodo(item)
        let newNotification = NotificationItem(id: "local-\(UUID().uuidString)", title: item.title, date: Date())
        notifications.insert(newNotification, at: 0)
        showNotificationAlert = true

        Task {
            do {
                _ = try await APIClient.shared.createNotification(
                    title: item.title,
                    notifyAt: Self.isoDateFormatter.string(from: Date()),
                    todoId: item.id
                )
                _ = try await APIClient.shared.deleteTodo(id: item.id)
                await manualRefresh()
            } catch {
                await MainActor.run {
                    self.refreshMessage = "Failed to move todo to notifications."
                }
            }
        }
    }

    private func deleteNotification(_ item: NotificationItem) {
        notifications.removeAll { $0.id == item.id }
        Task {
            do {
                _ = try await APIClient.shared.deleteNotification(id: item.id)
            } catch {
                await MainActor.run {
                    self.refreshMessage = "Failed to delete notification."
                }
            }
        }
    }

    private func updateNotification(_ updated: NotificationItem) {
        guard let index = notifications.firstIndex(where: { $0.id == updated.id }) else { return }
        notifications[index] = updated
        Task {
            do {
                _ = try await APIClient.shared.updateNotification(
                    id: updated.id,
                    notifyAt: Self.isoDateFormatter.string(from: updated.date)
                )
            } catch {
                await MainActor.run {
                    self.refreshMessage = "Failed to update notification time."
                }
            }
        }
    }

    private func editNotification(_ item: NotificationItem) {
        editingNotification = item
    }

    @MainActor
    private func manualRefresh(showSuccessMessage: Bool = true) async {
        if isRefreshing { return }
        isRefreshing = true
        defer { isRefreshing = false }
        do {
            async let ideasTask = APIClient.shared.getIdeas()
            async let todosTask = APIClient.shared.getTodos()
            async let notificationsTask = APIClient.shared.getNotifications()
            async let commentsTask = APIClient.shared.getComments(date: Self.dateDayFormatter.string(from: Date()), days: 7)

            let ideasDTO = try await ideasTask
            let todosDTO = try await todosTask
            let notificationsDTO = try await notificationsTask
            let commentsDTO = try await commentsTask

            ideas = mapIdeas(ideasDTO)
            todos = mapTodos(todosDTO)
            notifications = mapNotifications(notificationsDTO)
            applyComments(commentsDTO)
            applyDemoPayload(markAsNew: false)
            refreshTabHashesAndUnreadState()

            await viewModel.refreshEggbookSyncStatusAfterManualRefresh()
            updateBookBadge()
            refreshMessage = showSuccessMessage ? "Updated just now." : nil
        } catch {
            refreshMessage = "Refresh failed. Pull again."
        }
    }

    private func mapIdeas(_ dtos: [EggIdeaDTO]) -> [Idea] {
        if dtos.isEmpty { return [] }
        return dtos.map { dto in
            let title: String
            if let raw = dto.title?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty {
                title = raw
            } else {
                title = dto.content.split(separator: "\n").first.map(String.init) ?? "untitled idea"
            }
            return Idea(id: dto.id, title: title, insight: dto.content)
        }
    }

    private func mapTodos(_ dtos: [APIClient.TodoDTO]) -> [TodoItem] {
        if dtos.isEmpty { return [] }
        return dtos.map { dto in
            TodoItem(id: dto.id, title: dto.title, isAccepted: dto.isAccepted)
        }
    }

    private func mapNotifications(_ dtos: [APIClient.NotificationDTO]) -> [NotificationItem] {
        if dtos.isEmpty { return [] }
        return dtos.map { dto in
            NotificationItem(
                id: dto.id,
                title: dto.title,
                date: Self.parseServerDateTime(dto.notifyAt) ?? Date()
            )
        }
    }

    private func applyComments(_ response: APIClient.CommentsResponse) {
        var merged: [EggComment] = []

        for dto in response.myEgg {
            let (user, text) = Self.parseCommentContent(dto, fallbackUser: "my egg")
            merged.append(
                EggComment(
                    id: dto.id,
                    user: user,
                    text: text,
                    date: Self.parseServerDay(dto.date) ?? Date(),
                    scope: .myEgg
                )
            )
        }

        for dto in response.community {
            let (user, text) = Self.parseCommentContent(dto, fallbackUser: "egg community")
            let displayUser = user.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? Self.randomCommunityEggName()
                : user
            merged.append(
                EggComment(
                    id: dto.id,
                    user: displayUser,
                    text: text,
                    date: Self.parseServerDay(dto.date) ?? Date(),
                    scope: .community
                )
            )
        }

        comments = merged
        commentDates = Self.buildCommentDates(from: merged)
        selectedCommentIndex = min(selectedCommentIndex, max(0, commentDates.count - 1))
    }

    private var hasUnreadInNonCommentTabs: Bool {
        tabHasUpdateDot(.ideas) || tabHasUpdateDot(.todos) || tabHasUpdateDot(.alerts)
    }

    private func loadSeenTabHashesIfNeeded() {
        guard seenTabHashes.isEmpty else { return }
        let defaults = UserDefaults.standard
        for tab in LibraryTab.allCases {
            let key = seenHashKey(for: tab)
            guard defaults.object(forKey: key) != nil else { continue }
            seenTabHashes[tab] = defaults.integer(forKey: key)
        }
    }

    private func refreshTabHashesAndUnreadState() {
        latestTabHashes[.ideas] = hashIdeas(ideas)
        latestTabHashes[.todos] = hashTodos(todos)
        latestTabHashes[.alerts] = hashNotifications(notifications)
        latestTabHashes[.comments] = hashComments(comments)

        let defaults = UserDefaults.standard
        for tab in LibraryTab.allCases {
            guard let latest = latestTabHashes[tab] else { continue }
            if seenTabHashes[tab] == nil {
                let key = seenHashKey(for: tab)
                if defaults.object(forKey: key) == nil {
                    seenTabHashes[tab] = latest
                    defaults.set(latest, forKey: key)
                } else {
                    seenTabHashes[tab] = defaults.integer(forKey: key)
                }
            }
        }

        markTabAsSeen(selectedTab)
        updateBookBadge()
    }

    private func markTabAsSeen(_ tab: LibraryTab) {
        guard let latest = latestTabHashes[tab] else { return }
        if seenTabHashes[tab] != latest {
            seenTabHashes[tab] = latest
            UserDefaults.standard.set(latest, forKey: seenHashKey(for: tab))
        }
        updateBookBadge()
    }

    private func updateBookBadge() {
        let hasAnyUnread = LibraryTab.allCases.contains { tabHasUpdateDot($0) }
        viewModel.hasBookUpdates = hasAnyUnread || (viewModel.hasUploadProcessingPending && viewModel.hasProcessingEvents)
    }

    private func applyDemoPayload(markAsNew: Bool) {
        guard let payload = viewModel.demoEggbookPayload else { return }

        let demoIdeaID = "demo-idea-xiaohongshu-uiux"
        var inserted = false
        if let existingIndex = ideas.firstIndex(where: { $0.id == demoIdeaID }) {
            if ideas[existingIndex].videoFileName != "demovid" {
                ideas[existingIndex].videoFileName = "demovid"
            }
        } else {
            ideas.insert(
                Idea(
                    id: demoIdeaID,
                    title: payload.ideaTitle,
                    insight: payload.ideaDetail,
                    videoFileName: "demovid"
                ),
                at: 0
            )
            inserted = true
        }

        for (index, todoTitle) in payload.todoItems.enumerated() {
            let todoID = "demo-todo-xiaohongshu-\(index)"
            if !todos.contains(where: { $0.id == todoID }) {
                todos.insert(
                    TodoItem(
                        id: todoID,
                        title: todoTitle,
                        isAccepted: false
                    ),
                    at: min(index, todos.count)
                )
                inserted = true
            }
        }

        if markAsNew && viewModel.demoPayloadVersion > lastAppliedDemoPayloadVersion {
            lastAppliedDemoPayloadVersion = viewModel.demoPayloadVersion
            refreshTabHashesAndUnreadState()
            return
        }

        if inserted {
            refreshTabHashesAndUnreadState()
        }
    }

    private func seenHashKey(for tab: LibraryTab) -> String {
        "\(seenTabHashKeyPrefix)\(tab.rawValue.lowercased())"
    }

    private func hashIdeas(_ items: [Idea]) -> Int {
        var hasher = Hasher()
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.title)
            hasher.combine(item.insight)
        }
        return hasher.finalize()
    }

    private func hashTodos(_ items: [TodoItem]) -> Int {
        var hasher = Hasher()
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.title)
            hasher.combine(item.isAccepted)
        }
        return hasher.finalize()
    }

    private func hashNotifications(_ items: [NotificationItem]) -> Int {
        var hasher = Hasher()
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.title)
            hasher.combine(item.date.timeIntervalSince1970)
        }
        return hasher.finalize()
    }

    private func hashComments(_ items: [EggComment]) -> Int {
        var hasher = Hasher()
        for item in items {
            hasher.combine(item.id)
            hasher.combine(item.user)
            hasher.combine(item.text)
            hasher.combine(item.scope == .myEgg ? 0 : 1)
            hasher.combine(item.date.timeIntervalSince1970)
        }
        return hasher.finalize()
    }

    private static func parseCommentContent(_ dto: APIClient.CommentDTO, fallbackUser: String) -> (String, String) {
        let explicitUser = nonEmpty(dto.eggName) ?? nonEmpty(dto.userName)
        let explicitText = nonEmpty(dto.eggComment) ?? nonEmpty(dto.content)

        if let explicitText {
            if let explicitUser {
                return (explicitUser, explicitText)
            }
            return parseCommentContentLine(explicitText, fallbackUser: fallbackUser)
        }

        if let explicitUser {
            return (explicitUser, "")
        }
        return (fallbackUser, "")
    }

    private static func parseCommentContentLine(_ content: String, fallbackUser: String) -> (String, String) {
        guard let separator = content.firstIndex(of: ":") else {
            return (fallbackUser, content)
        }
        let user = String(content[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = String(content[content.index(after: separator)...]).trimmingCharacters(in: .whitespacesAndNewlines)
        if user.isEmpty { return (fallbackUser, text) }
        if text.isEmpty { return (user, content) }
        return (user, text)
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let value else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static let communityEggNameFallbackPool: [String] = [
        "ancient egg",
        "burning egg",
        "sleepy egg",
        "chaos egg",
        "zen egg",
        "study egg",
        "night owl egg",
        "grind egg",
        "soft egg",
        "meme egg"
    ]

    private static func randomCommunityEggName() -> String {
        guard !communityEggNameFallbackPool.isEmpty else { return "egg community" }
        return communityEggNameFallbackPool.randomElement() ?? "egg community"
    }

    private static func buildCommentDates(from comments: [EggComment]) -> [Date] {
        let calendar = Calendar.current
        let unique = Set(comments.map { calendar.startOfDay(for: $0.date) })
        let sorted = unique.sorted(by: >)
        if sorted.count >= 7 {
            return Array(sorted.prefix(7))
        }
        var result = sorted
        var cursor = calendar.startOfDay(for: Date())
        while result.count < 7 {
            if !result.contains(cursor) {
                result.append(cursor)
            }
            guard let prev = calendar.date(byAdding: .day, value: -1, to: cursor) else { break }
            cursor = prev
        }
        return result.sorted(by: >)
    }

    private static func parseServerDateTime(_ string: String) -> Date? {
        if let date = isoDateFormatter.date(from: string) {
            return date
        }
        if let date = isoDateFractionFormatter.date(from: string) {
            return date
        }
        return nil
    }

    private static func parseServerDay(_ string: String) -> Date? {
        dateDayFormatter.date(from: string)
    }

    private static var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd h:mma"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static var dateDayFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    private static var isoDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static var isoDateFractionFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func dateFromComponents(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? Date()
    }

    private static func defaultCommentDates() -> [Date] {
        let calendar = Calendar.current
        let start = calendar.startOfDay(for: Date())
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: -$0, to: start) }
    }
}

private struct SyncStatusStrip: View {
    let text: String
    let processing: Bool

    var body: some View {
        HStack(spacing: 8) {
            if processing {
                ProgressView()
                    .scaleEffect(0.85)
                    .tint(.white)
            } else {
                Image(systemName: "arrow.down.circle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
            }
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
    }
}

private struct ProcessingBanner: View {
    let text: String

    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .tint(.white)
            Text(text)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.white)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 14))
    }
}

struct IdeaDetailView: View {
    let ideas: [Idea]
    let index: Int

    @State private var isPlaying: Bool = false
    @State private var player = AVPlayer()
    @State private var hasVideo: Bool = false

    var body: some View {
        let idea = ideas[index]

        VStack(spacing: 20) {
            Group {
                if hasVideo {
                    VideoPlayerView(player: player)
                        .frame(height: 240)
                        .clipShape(RoundedRectangle(cornerRadius: 20))
                } else {
                    RoundedRectangle(cornerRadius: 20)
                        .fill(Color.black.opacity(0.12))
                        .frame(height: 240)
                        .overlay(
                            Image(systemName: "video.slash")
                                .font(.system(size: 32, weight: .semibold))
                                .foregroundStyle(.white)
                        )
                }
            }

            Button {
                togglePlayback()
            } label: {
                Label(
                    hasVideo ? (isPlaying ? "Pause" : "Play") : "No Video",
                    systemImage: hasVideo ? (isPlaying ? "pause.circle" : "play.circle") : "video.slash"
                )
            }
            .buttonStyle(.borderedProminent)
            .disabled(!hasVideo)

            VStack(alignment: .leading, spacing: 8) {
                Text("insight")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(idea.insight)
                    .font(.body)
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.white, in: RoundedRectangle(cornerRadius: 16))
            .shadow(color: Color.black.opacity(0.05), radius: 8, x: 0, y: 4)

            if index + 1 < ideas.count {
                NavigationLink {
                    IdeaDetailView(ideas: ideas, index: index + 1)
                } label: {
                    Label("Next Idea", systemImage: "chevron.right")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .tint(Color(red: 0.96, green: 0.68, blue: 0.18))
            }

            Spacer()
        }
        .padding()
        .background(Color(red: 0.97, green: 0.98, blue: 0.99))
        .navigationTitle("idea detail")
        .onAppear {
            configurePlayer(for: idea)
        }
        .onDisappear {
            player.pause()
            isPlaying = false
        }
    }

    private func configurePlayer(for idea: Idea) {
        player.pause()
        isPlaying = false
        guard
            let fileName = idea.videoFileName,
            let url = Bundle.main.url(forResource: fileName, withExtension: "mp4")
        else {
            hasVideo = false
            return
        }
        hasVideo = true
        player.replaceCurrentItem(with: AVPlayerItem(url: url))
        player.play()
        isPlaying = true
    }

    private func togglePlayback() {
        guard hasVideo else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }
}

struct NotificationDateEditor: View {
    @Environment(\.dismiss) private var dismiss

    @State var item: NotificationItem
    var onSave: (NotificationItem) -> Void

    var body: some View {
        NavigationStack {
            Form {
                DatePicker(
                    "remind time",
                    selection: $item.date,
                    displayedComponents: [.date, .hourAndMinute]
                )
                .datePickerStyle(.graphical)
            }
            .navigationTitle("edit time")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Save") {
                        onSave(item)
                        dismiss()
                    }
                }
            }
        }
    }
}

struct EggCommentsView: View {
    let dates: [Date]
    @Binding var selectedIndex: Int
    let comments: [EggComment]

    var body: some View {
        let date = dates[safe: selectedIndex] ?? dates.first

        VStack(spacing: 16) {
            header(date: date)

            if let date {
                commentColumns(for: date)
            }
        }
        .padding(16)
        .background(Color.white, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: Color.black.opacity(0.05), radius: 10, x: 0, y: 6)
    }

    private func header(date: Date?) -> some View {
        HStack {
            Button {
                goPrevious()
            } label: {
                Image(systemName: "chevron.left")
            }
            .buttonStyle(.plain)

            Spacer()

            VStack(spacing: 4) {
                Text(dayLabel(for: date))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(dateLabel(for: date))
                    .font(.title3.weight(.semibold))
            }

            Spacer()

            Button {
                goNext()
            } label: {
                Image(systemName: "chevron.right")
            }
            .buttonStyle(.plain)
        }
    }

    private func commentColumns(for date: Date) -> some View {
        HStack(alignment: .top, spacing: 12) {
            commentColumn(
                title: "My Egg",
                comments: filteredComments(for: date, scope: .myEgg),
                background: Color(red: 0.99, green: 0.95, blue: 0.83)
            )

            commentColumn(
                title: "Egg Community",
                comments: filteredComments(for: date, scope: .community),
                background: Color(red: 0.90, green: 0.95, blue: 1.0)
            )
        }
    }

    private func commentColumn(title: String, comments: [EggComment], background: Color) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            ForEach(comments) { comment in
                VStack(alignment: .leading, spacing: 6) {
                    Text(comment.user)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(comment.text)
                        .font(.callout)
                        .foregroundStyle(.primary)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(background, in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func filteredComments(for date: Date, scope: EggComment.Scope) -> [EggComment] {
        let calendar = Calendar.current
        return comments.filter {
            $0.scope == scope && calendar.isDate($0.date, inSameDayAs: date)
        }
    }

    private func dateLabel(for date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd"
        return formatter.string(from: date)
    }

    private func dayLabel(for date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }

    private func goNext() {
        guard selectedIndex + 1 < dates.count else { return }
        selectedIndex += 1
    }

    private func goPrevious() {
        guard selectedIndex > 0 else { return }
        selectedIndex -= 1
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
