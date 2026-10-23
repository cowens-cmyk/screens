import AppKit
import PresenterCore
import SwiftUI
import UniformTypeIdentifiers

/// Window › Assistant: a chat with Claude that can change plans and slides.
struct AssistantView: View {
    let session: AssistantSession

    @AppStorage(AssistantModel.defaultsKey) private var modelRaw = AssistantModel.opus.rawValue
    @State private var draft = ""
    @State private var picking: Picking?
    @State private var askingSong = false
    @State private var songName = ""
    @FocusState private var composerFocused: Bool

    private enum Picking: Identifiable {
        case attach, announcementCards
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if !session.hasKey { keyNotice }
            jobs
            Divider()
            transcript
            Divider()
            composer
        }
        .frame(minWidth: 380, minHeight: 460)
        .onAppear { session.refreshKey() }
        // Coming back from Settings with a key added.
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            if !session.hasKey { session.refreshKey() }
        }
        .fileImporter(
            isPresented: Binding(get: { picking != nil }, set: { if !$0 { picking = nil } }),
            allowedContentTypes: AssistantAttachments.allowedTypes, allowsMultipleSelection: true
        ) { result in
            let purpose = picking
            picking = nil
            guard case .success(let urls) = result, !urls.isEmpty else { return }
            Task {
                _ = await session.attach(urls)
                if purpose == .announcementCards { session.run(.announcementsFromCards) }
            }
        }
    }

    // MARK: Parts

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundStyle(.secondary)
            Text("Assistant").font(.headline)
            Text(AssistantModel.stored(modelRaw).title).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Button {
                session.newConversation()
            } label: {
                Label("New Conversation", systemImage: "square.and.pencil")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .disabled(session.isRunning || session.lines.isEmpty)
            .help("New conversation")
            Button {
                AssistantPreferences.openSettings()
            } label: {
                Label("Assistant Settings", systemImage: "gearshape")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .help("API key and model")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var keyNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("The Assistant needs an Anthropic API key.").font(.callout.weight(.semibold))
            Text("Add it in \(AssistantPreferences.keyLocation). Sermon import uses the same key.")
                .font(.caption).foregroundStyle(.secondary)
            Button("Open Settings") { AssistantPreferences.openSettings() }
                .controlSize(.small)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(Color.orange.opacity(0.12))
    }

    private var jobs: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 170), spacing: 8, alignment: .leading)], alignment: .leading, spacing: 6) {
            Button {
                session.run(.buildSunday)
            } label: {
                Label(AssistantPrompt.Job.buildSunday.title, systemImage: AssistantPrompt.Job.buildSunday.systemImage)
            }
            .help("Get the next plan ready: songs, message, countdown, pre-service and schedule. Attach the message notes first if you have them.")
            Menu {
                Button("Every Song in the Next Plan") { session.run(.checkSongLyrics(song: nil)) }
                Button("One Song…") { askingSong = true }
            } label: {
                Label(AssistantPrompt.Job.checkSongLyrics(song: nil).title,
                      systemImage: AssistantPrompt.Job.checkSongLyrics(song: nil).systemImage)
            }
            .fixedSize()
            .help("Compare song slides with the lyrics in Shepherd")
            .popover(isPresented: $askingSong, arrowEdge: .bottom) { songPrompt }
            Button {
                session.run(.updatePreService)
            } label: {
                Label(AssistantPrompt.Job.updatePreService.title, systemImage: AssistantPrompt.Job.updatePreService.systemImage)
            }
            Button {
                picking = .announcementCards
            } label: {
                Label(AssistantPrompt.Job.announcementsFromCards.title,
                      systemImage: AssistantPrompt.Job.announcementsFromCards.systemImage)
            }
        }
        .controlSize(.small)
        .disabled(session.isRunning || !session.hasKey)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var songPrompt: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Which song?").font(.headline)
            TextField("Song title", text: $songName)
                .textFieldStyle(.roundedBorder)
                .frame(width: 240)
                .onSubmit(checkSong)
            HStack {
                Spacer()
                Button("Cancel") { askingSong = false }
                Button("Check", action: checkSong)
                    .keyboardShortcut(.defaultAction)
                    .disabled(songName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(12)
    }

    private func checkSong() {
        let name = songName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !session.isRunning else { return }
        askingSong = false
        songName = ""
        session.run(.checkSongLyrics(song: name))
    }

    private var transcript: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if session.lines.isEmpty { emptyState }
                    ForEach(session.lines) { line in
                        AssistantLineView(line: line, session: session).id(line.id)
                    }
                    if session.isRunning && !session.awaitingDecision {
                        HStack(spacing: 6) {
                            ProgressView().controlSize(.small)
                            Text("Working…").font(.caption).foregroundStyle(.secondary)
                        }
                        .id("working")
                    }
                }
                .padding(12)
            }
            .onChange(of: session.lines.last?.text) {
                withAnimation(.easeOut(duration: 0.15)) {
                    if session.isRunning && !session.awaitingDecision {
                        proxy.scrollTo("working", anchor: .bottom)
                    } else if let last = session.lines.last?.id {
                        proxy.scrollTo(last, anchor: .bottom)
                    }
                }
            }
            .onChange(of: session.lines.count) {
                proxy.scrollTo(session.lines.last?.id, anchor: .bottom)
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Ask how to do something in Screens, or ask for a change.")
            Text("For example: \"Add a slide to Announcements for the Fall Festival\", \"Schedule Sunday's plan for 9 and 11\", or \"How do I send a message to the stage?\"")
                .foregroundStyle(.secondary)
            Text("Deleting slides, removing plan items, scheduling and fixing lyrics ask you first.")
                .foregroundStyle(.secondary)
        }
        .font(.callout)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !session.pendingAttachments.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(session.pendingAttachments) { attachment in
                            HStack(spacing: 4) {
                                Image(systemName: "photo")
                                Text(attachment.label).lineLimit(1)
                                Button {
                                    session.removeAttachment(attachment.id)
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(.borderless)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.quaternary, in: Capsule())
                        }
                    }
                }
            }
            HStack(alignment: .bottom, spacing: 8) {
                Button {
                    picking = .attach
                } label: {
                    Image(systemName: "paperclip")
                }
                .buttonStyle(.borderless)
                .help("Attach PDFs or images")
                .disabled(session.isRunning)

                TextField("Message the Assistant", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .focused($composerFocused)
                    .onSubmit(send)
                    .padding(6)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 6))

                if session.isRunning {
                    Button("Stop") { session.stop() }
                        .keyboardShortcut(.escape, modifiers: [])
                } else {
                    Button("Send", action: send)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                  && session.pendingAttachments.isEmpty)
                }
            }
        }
        .padding(10)
        .onAppear { composerFocused = true }
    }

    private func send() {
        guard !session.isRunning else { return }
        session.send(draft)
        if session.isRunning { draft = "" }
    }
}

/// One line of the transcript.
private struct AssistantLineView: View {
    let line: AssistantSession.Line
    let session: AssistantSession

    var body: some View {
        switch line.kind {
        case .user(let attachments):
            VStack(alignment: .trailing, spacing: 4) {
                if !line.text.isEmpty {
                    Text(line.text).textSelection(.enabled)
                }
                ForEach(attachments, id: \.self) { name in
                    Label(name, systemImage: "photo").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(8)
            .background(Color.accentColor.opacity(0.18), in: RoundedRectangle(cornerRadius: 8))
            .frame(maxWidth: .infinity, alignment: .trailing)
        case .reply:
            Text(Self.markdown(line.text))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .progress:
            Text(line.text)
                .font(.caption).italic()
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .activity(let failed):
            Label(line.text, systemImage: failed ? "exclamationmark.circle" : "checkmark.circle")
                .font(.caption)
                .foregroundStyle(failed ? Color.orange : Color.secondary)
                .lineLimit(3)
        case .confirmation(let title, let approved):
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.callout.weight(.semibold))
                if !line.text.isEmpty {
                    Text(line.text).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                switch approved {
                case nil:
                    HStack {
                        Button("Cancel") { session.decide(false) }
                        Button("Approve") { session.decide(true) }
                            .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                case true?:
                    Label("Approved", systemImage: "checkmark").font(.caption).foregroundStyle(.secondary)
                case false?:
                    Label("Cancelled", systemImage: "xmark").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
        case .notice:
            Text(line.text).font(.caption).foregroundStyle(.secondary)
        case .error:
            Label(line.text, systemImage: "exclamationmark.triangle")
                .font(.callout)
                .foregroundStyle(.orange)
                .textSelection(.enabled)
        }
    }

    static func markdown(_ text: String) -> AttributedString {
        (try? AttributedString(
            markdown: text,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace, failurePolicy: .returnPartiallyParsedIfPossible)))
            ?? AttributedString(text)
    }
}
