import SwiftUI

/// Reply to a story/comment, or edit one of your own comments.
struct ComposeView: View {
    let target: ComposeTarget
    var onPosted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @State private var form: HNForm?
    @State private var loadError: (any Error)?
    @State private var postError: (any Error)?
    @State private var isPosting = false
    @State private var showingHelp = false
    @FocusState private var focused: Bool

    private var isEdit: Bool {
        if case .edit = target.mode { true } else { false }
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                if let context = target.context {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 4) {
                            if let author = target.contextAuthor {
                                Text(author).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                            }
                            Text(context)
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding()
                    }
                    .frame(maxHeight: 160)
                    .background(.quaternary.opacity(0.4))
                    Divider()
                }

                TextEditor(text: $text)
                    .focused($focused)
                    .font(.body)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 12)
                    .overlay(alignment: .topLeading) {
                        if text.isEmpty {
                            Text(isEdit ? "Edit your comment" : "Write a reply")
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 17)
                                .padding(.vertical, 8)
                                .allowsHitTesting(false)
                        }
                    }
                    .disabled(form == nil)
            }
            .overlay {
                if form == nil && loadError == nil { ProgressView() }
                if let loadError {
                    ErrorView(error: loadError) { Task { await loadForm() } }
                        .background(.background)
                }
            }
            .navigationTitle(isEdit ? "Edit Comment" : "Reply")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isPosting {
                        ProgressView()
                    } else {
                        Button(isEdit ? "Save" : "Post", systemImage: "arrow.up") { Task { await post() } }
                            .buttonStyle(.glassProminent)
                            .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || form == nil)
                    }
                }
                ToolbarItem(placement: .bottomBar) {
                    Button("Formatting", systemImage: "textformat") { showingHelp = true }
                }
            }
            .alert("Couldn't Post", isPresented: Binding(get: { postError != nil }, set: { if !$0 { postError = nil } })) {
                Button("OK") {}
            } message: {
                Text(postError?.localizedDescription ?? "")
            }
            .sheet(isPresented: $showingHelp) { FormattingHelp() }
        }
        .interactiveDismissDisabled(!text.isEmpty && !isEdit)
        .task { await loadForm() }
    }

    private func loadForm() async {
        loadError = nil
        do {
            switch target.mode {
            case .reply(let parentID):
                form = try await HNClient.shared.replyForm(for: parentID)
            case .edit(let commentID):
                let editForm = try await HNClient.shared.editForm(for: commentID)
                text = editForm.textareaValue ?? ""
                form = editForm
            }
            focused = true
        } catch {
            loadError = error
        }
    }

    private func post() async {
        guard let form else { return }
        isPosting = true
        defer { isPosting = false }
        do {
            switch target.mode {
            case .reply: try await HNClient.shared.postComment(form: form, text: text)
            case .edit: try await HNClient.shared.submitEdit(form: form, text: text)
            }
            onPosted(text)
            dismiss()
        } catch {
            postError = error
        }
    }
}

struct FormattingHelp: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                row("Paragraphs", "Leave a blank line between paragraphs.")
                row("Italics", "Surround text with asterisks: *like this*.")
                row("Code", "Indent lines by two or more spaces for a code block.")
                row("Links", "URLs become links automatically.")
                row("Quotes", "HN convention is to start a quoted line with >.")
            }
            .navigationTitle("Formatting")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", systemImage: "checkmark") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium])
    }

    private func row(_ title: String, _ detail: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.headline)
            Text(detail).font(.subheadline).foregroundStyle(.secondary)
        }
    }
}

/// Submit a new story: a URL, or a text post (Ask HN etc.).
struct SubmitView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(Notifier.self) private var notifier
    @State private var title = ""
    @State private var url = ""
    @State private var text = ""
    @State private var isPosting = false
    @State private var error: (any Error)?

    private var canSubmit: Bool {
        !title.trimmingCharacters(in: .whitespaces).isEmpty
            && (!url.trimmingCharacters(in: .whitespaces).isEmpty || !text.trimmingCharacters(in: .whitespaces).isEmpty)
            && title.count <= 80
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $title, axis: .vertical)
                    TextField("URL", text: $url)
                        .keyboardType(.URL)
                        .textContentType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } footer: {
                    Text("\(title.count)/80")
                        .foregroundStyle(title.count > 80 ? .red : .secondary)
                }
                Section {
                    TextField("Text (optional with a URL)", text: $text, axis: .vertical)
                        .lineLimit(6...)
                } footer: {
                    Text("Leave the URL blank to submit a question for discussion. If there's a URL, text is posted as the first comment.")
                }
            }
            .navigationTitle("Submit")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", systemImage: "xmark") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isPosting {
                        ProgressView()
                    } else {
                        Button("Submit", systemImage: "arrow.up") { Task { await submit() } }
                            .buttonStyle(.glassProminent)
                            .disabled(!canSubmit)
                    }
                }
            }
            .alert("Couldn't Submit", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
                Button("OK") {}
            } message: {
                Text(error?.localizedDescription ?? "")
            }
        }
    }

    private func submit() async {
        isPosting = true
        defer { isPosting = false }
        do {
            try await HNClient.shared.submit(title: title, url: url, text: text)
            notifier.show("Submitted", systemImage: "paperplane.fill")
            dismiss()
        } catch {
            self.error = error
        }
    }
}
