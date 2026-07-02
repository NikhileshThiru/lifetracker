import SwiftUI
import LifeTrackerCore

/// Rename, recolor, merge, or archive the dynamic categories the parser creates.
struct CategoryManagerView: View {
    @Environment(AppEnvironment.self) private var env
    @State private var categories: [LifeTrackerCore.Category] = []
    @State private var editing: LifeTrackerCore.Category?

    var body: some View {
        List {
            ForEach(categories) { cat in
                Button { editing = cat } label: {
                    HStack(spacing: 12) {
                        Circle()
                            .fill(Color.category(cat.colorHex))
                            .frame(width: 12, height: 12)
                        Text(cat.name)
                            .foregroundStyle(Theme.textPrimary)
                        Spacer()
                        Text(cat.kind)
                            .font(.caption)
                            .foregroundStyle(Theme.textSecondary)
                    }
                }
                .listRowBackground(Theme.surface)
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.bg)
        .navigationTitle("Categories")
        .overlay {
            if categories.isEmpty {
                ContentUnavailableView(
                    "No categories yet",
                    systemImage: "tag",
                    description: Text("Categories appear as you log activities.")
                )
            }
        }
        .task { reload() }
        .sheet(item: $editing) { cat in
            CategoryEditSheet(category: cat, others: categories.filter { $0.id != cat.id }) {
                reload()
                CaptureLauncher.shared.changeToken = UUID()   // colors/names feed every screen
            }
            .environment(env)
        }
    }

    private func reload() {
        categories = (try? CategoryRepository(env.database.dbWriter).live()) ?? []
    }
}

private struct CategoryEditSheet: View {
    @Environment(AppEnvironment.self) private var env
    @Environment(\.dismiss) private var dismiss

    let category: LifeTrackerCore.Category
    let others: [LifeTrackerCore.Category]
    var onSaved: () -> Void

    @State private var name: String
    @State private var colorHex: String
    @State private var confirmMergeInto: LifeTrackerCore.Category?

    private static let palette = [
        "#5E5CE6", "#0A84FF", "#64D2FF", "#30D158", "#FFD60A", "#FF9F0A",
        "#FF6482", "#FF453A", "#BF5AF2", "#AC8E68", "#8E8E93", "#98989D",
    ]

    init(category: LifeTrackerCore.Category, others: [LifeTrackerCore.Category], onSaved: @escaping () -> Void) {
        self.category = category
        self.others = others
        self.onSaved = onSaved
        _name = State(initialValue: category.name)
        _colorHex = State(initialValue: category.colorHex ?? Self.palette[0])
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                }
                Section("Color") {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 6), spacing: 12) {
                        ForEach(Self.palette, id: \.self) { hex in
                            let selected = hex.caseInsensitiveCompare(colorHex) == .orderedSame
                            Circle()
                                .fill(Color.category(hex))
                                .frame(width: 32, height: 32)
                                .overlay {
                                    if selected {
                                        Image(systemName: "checkmark")
                                            .font(.caption.bold())
                                            .foregroundStyle(.white)
                                    }
                                }
                                .contentShape(Circle())
                                .onTapGesture { colorHex = hex }
                                .accessibilityLabel("Color \(hex)")
                                .accessibilityAddTraits(selected ? [.isSelected, .isButton] : .isButton)
                        }
                    }
                    .padding(.vertical, 4)
                }
                if !others.isEmpty {
                    Section {
                        Menu {
                            ForEach(others) { other in
                                Button(other.name) { confirmMergeInto = other }
                            }
                        } label: {
                            Label("Merge into another category", systemImage: "arrow.triangle.merge")
                        }
                    } footer: {
                        Text("Moves every \"\(category.name)\" activity to the chosen category and archives \"\(category.name)\". This can't be undone from the app — merge deliberately.")
                    }
                }
                Section {
                    Button("Archive", role: .destructive) { archive() }
                } footer: {
                    Text("Archived categories keep their history but stop appearing in pickers and stats.")
                }
            }
            .navigationTitle("Edit category")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            }
        }
        .preferredColorScheme(.dark)
        .confirmationDialog(
            "Merge \"\(category.name)\" into \"\(confirmMergeInto?.name ?? "")\"?",
            isPresented: Binding(get: { confirmMergeInto != nil },
                                 set: { if !$0 { confirmMergeInto = nil } }),
            titleVisibility: .visible,
            presenting: confirmMergeInto
        ) { target in
            Button("Merge", role: .destructive) { merge(into: target) }
            Button("Cancel", role: .cancel) { confirmMergeInto = nil }
        }
    }

    private func save() {
        var updated = category
        updated.name = name.trimmingCharacters(in: .whitespaces)
        updated.colorHex = colorHex
        try? CategoryRepository(env.database.dbWriter).update(updated, now: env.currentTime())
        onSaved()
        dismiss()
    }

    private func merge(into target: LifeTrackerCore.Category) {
        _ = try? EditService(env.database.dbWriter)
            .mergeCategory(sourceId: category.id, into: target.id, now: env.currentTime())
        onSaved()
        dismiss()
    }

    private func archive() {
        var updated = category
        updated.isArchived = true
        try? CategoryRepository(env.database.dbWriter).update(updated, now: env.currentTime())
        onSaved()
        dismiss()
    }
}
