import PresenterCore
import SwiftUI

/// The Animation tab, kept simple: for the selected objects, how they come
/// in, when, how they go out, and how fast. It edits the same steps the
/// timeline does (one "in" and one "out" per object), so anything built in
/// the timeline still plays; the timeline stays one click away for the rest.
struct SimpleAnimationPanel: View {
    @Bindable var model: SlideEditorModel

    enum InEffect: String, CaseIterable, Identifiable {
        case none, fade, slide, zoom, wipe, blur, type
        var id: String { rawValue }
        var title: String {
            switch self {
            case .none: "None"
            case .fade: "Fade"
            case .slide: "Slide"
            case .zoom: "Zoom"
            case .wipe: "Wipe"
            case .blur: "Blur"
            case .type: "Type"
            }
        }
        var animation: StepAnimation? {
            switch self {
            case .none: nil
            case .fade: .fade
            case .slide: .move
            case .zoom: .scale
            case .wipe: .wipe
            case .blur: .blur
            case .type: .type
            }
        }
        static func of(_ animation: StepAnimation) -> InEffect {
            allCases.first { $0.animation == animation } ?? .fade
        }
        var hasEdge: Bool { self == .slide || self == .wipe }
    }

    enum Start: String, CaseIterable, Identifiable {
        case withSlide, onClick, afterPrevious
        var id: String { rawValue }
        var title: String {
            switch self {
            case .withSlide: "With the slide"
            case .onClick: "On click"
            case .afterPrevious: "After the previous one"
            }
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if objectIDs.isEmpty {
                    Text("Select an object on the slide to animate it.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    slideSummary
                } else {
                    comesIn
                    goesOut
                    speed
                }
                Divider()
                HStack {
                    Button("Preview", systemImage: "play.fill") { model.playAnimationPreview() }
                        .disabled(model.stepEntries.isEmpty)
                    Spacer()
                    Button("Advanced Timeline…") { model.editorMode = .animate }
                        .buttonStyle(.link)
                }
            }
            .padding(12)
        }
    }

    // MARK: The selection

    private var objectIDs: [String] {
        (model.currentSlide?.objects ?? []).map(\.id).filter { model.selectedObjectIDs.contains($0) }
    }

    private func steps(of objectID: String) -> [AnimationStep] {
        model.object(id: objectID)?.animationSteps ?? []
    }

    private func inStep(_ objectID: String) -> AnimationStep? {
        steps(of: objectID).first { $0.kind == .in && ($0.ranges ?? []).isEmpty }
    }

    private func outStep(_ objectID: String) -> AnimationStep? {
        steps(of: objectID).first { $0.kind == .out && ($0.ranges ?? []).isEmpty }
    }

    private var isText: Bool {
        objectIDs.allSatisfy { model.object(id: $0)?.objectKind == .text }
    }

    // MARK: Comes in

    private var comesIn: some View {
        let first = objectIDs.first.flatMap(inStep)
        let effect = first.map { InEffect.of($0.animation) } ?? InEffect.none
        return section("Comes In") {
            Picker("Effect", selection: Binding(get: { effect }, set: { setIn($0) })) {
                ForEach(InEffect.allCases.filter { $0 != .type || isText }) { Text($0.title).tag($0) }
            }
            if let first, effect.hasEdge {
                edgePicker(first.edge ?? .left) { edge in
                    forEachStep(inStep) { model.updateAnimationStep($0.id) { $0.edge = edge } }
                }
            }
            if let first {
                Picker("Starts", selection: Binding(get: { start(of: first) }, set: { setStart($0) })) {
                    ForEach(Start.allCases) { Text($0.title).tag($0) }
                }
            }
        }
    }

    private func setIn(_ effect: InEffect) {
        guard let animation = effect.animation else {
            forEachStep(inStep) { model.removeAnimationStep($0.id) }
            return
        }
        let missing = objectIDs.filter { inStep($0) == nil }
        forEachStep(inStep) { model.replaceStepEffect($0.id, kind: .in, animation: animation) }
        guard !missing.isEmpty else { return }
        // New ones come in with the slide unless something on it already waits for a click.
        withSelection(missing) {
            let ids = model.addAnimationStep(kind: .in, animation: animation, trigger: .withPrevious)
            if let id = ids.first, model.stepEntries.first?.step.id != id {
                model.moveAnimationStep(id: id, beforeID: model.stepEntries.first?.step.id)
            }
        }
    }

    private func start(of step: AnimationStep) -> Start {
        switch step.trigger {
        case .onClick: .onClick
        case .afterPrevious: .afterPrevious
        default: .withSlide
        }
    }

    private func setStart(_ start: Start) {
        forEachStep(inStep) { step in
            switch start {
            case .onClick:
                model.updateAnimationStep(step.id) { $0.trigger = .onClick }
            case .afterPrevious:
                model.updateAnimationStep(step.id) { $0.trigger = .afterPrevious }
            case .withSlide:
                // Everything before the first click plays as the slide goes live.
                model.updateAnimationStep(step.id) { $0.trigger = .withPrevious }
                model.moveAnimationStep(id: step.id, beforeID: model.stepEntries.first?.step.id)
            }
        }
    }

    // MARK: Goes out

    private var goesOut: some View {
        let first = objectIDs.first.flatMap(outStep)
        let effect = first.map { InEffect.of($0.animation) } ?? InEffect.none
        return section("Goes Out") {
            Picker("Effect", selection: Binding(get: { effect }, set: { setOut($0) })) {
                ForEach(InEffect.allCases.filter { $0 != .type }) { Text($0.title).tag($0) }
            }
            if let first, effect.hasEdge {
                edgePicker(first.edge ?? .left) { edge in
                    forEachStep(outStep) { model.updateAnimationStep($0.id) { $0.edge = edge } }
                }
            }
            Text("On the last click, before the next slide.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func setOut(_ effect: InEffect) {
        guard let animation = effect.animation else {
            forEachStep(outStep) { model.removeAnimationStep($0.id) }
            return
        }
        let missing = objectIDs.filter { outStep($0) == nil }
        forEachStep(outStep) { model.replaceStepEffect($0.id, kind: .out, animation: animation) }
        guard !missing.isEmpty else { return }
        withSelection(missing) {
            model.addAnimationStep(kind: .out, animation: animation, trigger: .onDismiss)
        }
    }

    // MARK: Speed

    private var speed: some View {
        let all = objectIDs.flatMap { [inStep($0), outStep($0)].compactMap { $0 } }
        let current = all.first.map { SlideEditorModel.AnimationSpeed.of($0.durationSeconds) } ?? .normal
        return section("Speed") {
            Picker("Speed", selection: Binding(get: { current }, set: { setSpeed($0) })) {
                Text("Quick").tag(SlideEditorModel.AnimationSpeed.quick)
                Text("Normal").tag(SlideEditorModel.AnimationSpeed.normal)
                Text("Slow").tag(SlideEditorModel.AnimationSpeed.slow)
                if current == .custom { Text("Custom").tag(SlideEditorModel.AnimationSpeed.custom) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .disabled(all.isEmpty)
        }
    }

    private func setSpeed(_ speed: SlideEditorModel.AnimationSpeed) {
        guard let seconds = speed.seconds else { return }
        forEachStep(inStep) { model.updateAnimationStep($0.id) { $0.durationSeconds = seconds } }
        forEachStep(outStep) { model.updateAnimationStep($0.id) { $0.durationSeconds = seconds } }
    }

    // MARK: Nothing selected: what's animated on this slide

    @ViewBuilder
    private var slideSummary: some View {
        let entries = model.stepEntries
        if entries.isEmpty {
            Text("Nothing on this slide is animated.")
                .font(.caption)
                .foregroundStyle(.tertiary)
        } else {
            section("On This Slide") {
                ForEach(entries, id: \.step.id) { entry in
                    Button {
                        model.selectObject(id: entry.objectID)
                    } label: {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.stepTargetLabel(entry)).font(.callout)
                            Text(model.animationSentence(entry.step))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Helpers

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.subheadline.weight(.semibold))
            content()
        }
    }

    private func edgePicker(_ edge: AnimationEdge, set: @escaping (AnimationEdge) -> Void) -> some View {
        Picker("From", selection: Binding(get: { edge }, set: set)) {
            Image(systemName: "arrow.right").help("From the left").tag(AnimationEdge.left)
            Image(systemName: "arrow.left").help("From the right").tag(AnimationEdge.right)
            Image(systemName: "arrow.down").help("From the top").tag(AnimationEdge.top)
            Image(systemName: "arrow.up").help("From the bottom").tag(AnimationEdge.bottom)
        }
        .pickerStyle(.segmented)
    }

    /// Runs `body` on the matching step of every selected object.
    private func forEachStep(_ find: (String) -> AnimationStep?, _ body: (AnimationStep) -> Void) {
        for id in objectIDs { if let step = find(id) { body(step) } }
    }

    /// Adding steps acts on the editor's selection, so narrow it to the
    /// objects that need one, then put it back.
    private func withSelection(_ ids: [String], _ body: () -> Void) {
        let saved = model.selectedObjectIDs
        model.setSelection(Set(ids))
        body()
        model.setSelection(saved)
    }
}
