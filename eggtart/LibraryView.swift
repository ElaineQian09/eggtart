import SwiftUI

struct Idea: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var insight: String
}

struct TodoItem: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var isAccepted: Bool = false
}

struct NotificationItem: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var date: Date
}

struct EggComment: Identifiable, Equatable {
    let id = UUID()
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

    @State private var selectedTab: LibraryTab = .ideas

    @State private var ideas: [Idea] = [
        Idea(
            title: "capcut weekly ootd transition videos",
            insight: "use color as a theme to edit weekly ootd transition videos based on fan requests, use ai tools to generate outfit and use taobao scan to buy the most similar one"
        ),
        Idea(
            title: "new deployment methods based on Google AI studio.",
            insight: "use color as a theme to edit weekly ootd transition videos based on fan requests, use ai tools to generate outfit and use taobao scan to buy the most similar one"
        )
    ]

    @State private var todos: [TodoItem] = [
        TodoItem(title: "learn capcut"),
        TodoItem(title: "use dreamina for outfit generation"),
        TodoItem(title: "use Google ai studio to make my own outfit design app")
    ]

    @State private var notifications: [NotificationItem] = [
        NotificationItem(title: "google hackathon", date: LibraryView.dateFromComponents(2026, 2, 1, 20, 0)),
        NotificationItem(title: "data analysis midterm", date: LibraryView.dateFromComponents(2026, 2, 10, 10, 0))
    ]

    @State private var editingTodoID: UUID?
    @State private var editingTodoText: String = ""
    @State private var showNotificationAlert: Bool = false

    @State private var editingNotification: NotificationItem?
    @State private var showDatePicker: Bool = false

    private let commentDates: [Date] = {
        let calendar = Calendar.current
        let base = calendar.date(from: DateComponents(year: 2026, month: 1, day: 25)) ?? Date()
        return (0..<7).compactMap { calendar.date(byAdding: .day, value: -$0, to: base) }
    }()

    @State private var selectedCommentIndex: Int = 0

    private let comments: [EggComment] = {
        let calendar = Calendar.current
        let date = calendar.date(from: DateComponents(year: 2026, month: 1, day: 25)) ?? Date()
        return [
            EggComment(user: "my egg", text: "bro be on the phone all the time.", date: date, scope: .myEgg),
            EggComment(user: "a thousand year old egg", text: "why always look at moody stuff on TikTok, so cringe.", date: date, scope: .community),
            EggComment(user: "burning egg", text: "I dunno bruh, i like dude's hustle", date: date, scope: .community)
        ]
    }()

    private let pageBackground = Color(red: 0.96, green: 0.97, blue: 0.98)

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
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
            .navigationTitle("egg book")
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
            .sheet(isPresented: $showDatePicker) {
                if let editingNotification {
                    NotificationDateEditor(item: editingNotification) { updated in
                        updateNotification(updated)
                        showDatePicker = false
                    }
                }
            }
        }
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
            Text(tab.rawValue)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? Color.black : Color.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(isSelected ? Color.white : Color.clear, in: Capsule())
        }
        .buttonStyle(.plain)
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
                            ideas.remove(at: index)
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
    }

    private var alertsView: some View {
        List {
            Section {
                ForEach(notifications) { item in
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 6) {
                            Text(item.title)
                                .font(.body.weight(.semibold))
                            Text(Self.dateFormatter.string(from: item.date))
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }

                        Spacer()

                        Button {
                            editingNotification = item
                            showDatePicker = true
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
    }

    private var commentsView: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text("swipe up/down to change date")
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
        todos[index].title = editingTodoText
        editingTodoID = nil
    }

    private func acceptTodo(_ item: TodoItem) {
        guard let index = todos.firstIndex(of: item) else { return }
        todos[index].isAccepted = true
        let accepted = todos.remove(at: index)
        todos.insert(accepted, at: 0)
    }

    private func deleteTodo(_ item: TodoItem) {
        todos.removeAll { $0.id == item.id }
    }

    private func moveTodoToNotifications(_ item: TodoItem) {
        deleteTodo(item)
        let newNotification = NotificationItem(title: item.title, date: Date())
        notifications.insert(newNotification, at: 0)
        showNotificationAlert = true
    }

    private func deleteNotification(_ item: NotificationItem) {
        notifications.removeAll { $0.id == item.id }
    }

    private func updateNotification(_ updated: NotificationItem) {
        guard let index = notifications.firstIndex(where: { $0.id == updated.id }) else { return }
        notifications[index] = updated
    }

    private static var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy/MM/dd h:mma"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        return formatter
    }()

    private static func dateFromComponents(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        Calendar.current.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute)) ?? Date()
    }
}

struct IdeaDetailView: View {
    let ideas: [Idea]
    let index: Int

    @State private var isPlaying: Bool = false

    var body: some View {
        let idea = ideas[index]

        VStack(spacing: 20) {
            RoundedRectangle(cornerRadius: 20)
                .fill(Color.black.opacity(0.12))
                .frame(height: 240)
                .overlay(
                    Image(systemName: "play.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.white)
                )

            Button {
                isPlaying.toggle()
            } label: {
                Label(isPlaying ? "Pause" : "Play", systemImage: isPlaying ? "pause.circle" : "play.circle")
            }
            .buttonStyle(.borderedProminent)

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
        .gesture(
            DragGesture(minimumDistance: 20)
                .onEnded { value in
                    if value.translation.height < -30 {
                        goNext()
                    } else if value.translation.height > 30 {
                        goPrevious()
                    }
                }
        )
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
