import Foundation

/// What the main window's activity bar says: files being imported and the
/// plan being loaded into memory, each on its own line so one never hides
/// the other. The view only draws `lines`; the stages, the counting, two
/// imports running at once and how long a summary stays are decided here,
/// where they can be tested without the app.
///
/// Every call that can start or end something takes the time, so the
/// summaries' lifetimes are plain arithmetic.
public struct ActivityBoard: Equatable, Sendable {

    /// One import, from the drop to its last slide.
    public struct Ticket: Hashable, Sendable {
        let id: Int
    }

    public enum ImportStage: Equatable, Sendable {
        /// Finding the files: folders opened, lower thirds paired.
        case preparing
        /// Copying files into the library, one at a time.
        case files
        /// A Keynote deck or a PDF, which has no count of its own.
        case document(name: String)
        /// Turning what was imported into slides.
        case makingSlides
    }

    public enum Tone: Sendable, Equatable {
        case working
        case done
        case problem
    }

    public struct Line: Equatable, Sendable, Identifiable {
        public enum Kind: String, Sendable {
            case importing
            case plan
        }
        public var kind: Kind
        public var title: String
        /// The file being imported, when there is one.
        public var detail: String?
        /// How far along, 0 to 1; nil while it can't be counted.
        public var fraction: Double?
        public var tone: Tone

        public var id: String { kind.rawValue }
        /// A finished line can be closed before its time is up.
        public var isSummary: Bool { tone != .working }
    }

    /// How long a summary stays: a plain "done" briefly; anything left out,
    /// skipped or failed long enough to read in the middle of a service.
    public static let doneShown: TimeInterval = 5
    public static let problemShown: TimeInterval = 20

    private struct Job: Equatable, Sendable {
        var order: Int
        var stage: ImportStage
        var done = 0
        var total = 0
        var fileName = ""
        /// What earlier batches on the same ticket counted.
        var baseDone = 0
        var baseTotal = 0
        /// When its count last moved, so two imports show the newer file.
        var touched = 0
        var notes: [String] = []
        var problem = false
    }

    private struct Summary: Equatable, Sendable {
        var text: String
        var problem: Bool
        var until: Date
    }

    private struct PlanLoad: Equatable, Sendable {
        var done: Int
        var total: Int
    }

    private var counter = 0
    private var jobs: [Int: Job] = [:]
    /// What imports that finished while another still ran said, shown
    /// together once the last one ends.
    private var finishedNotes: [String] = []
    private var finishedProblem = false
    private var importSummary: Summary?
    private var plan: PlanLoad?
    private var planSummary: Summary?

    public init() {}

    // MARK: Imports

    /// An import starts. A summary still showing from the last one goes:
    /// the bar is about this one now.
    public mutating func beginImport(_ stage: ImportStage = .preparing) -> Ticket {
        counter += 1
        jobs[counter] = Job(order: counter, stage: stage)
        importSummary = nil
        return Ticket(id: counter)
    }

    public mutating func setStage(_ stage: ImportStage, of ticket: Ticket) {
        jobs[ticket.id]?.stage = stage
    }

    /// The importer's progress: how many files are done, of how many, and
    /// the one it is on. A ticket can import more than one batch (a PDF's
    /// pages, then the files dropped beside it); each batch adds to its
    /// count rather than starting it again.
    public mutating func noteFiles(done: Int, total: Int, fileName: String, of ticket: Ticket) {
        guard var job = jobs[ticket.id] else { return }
        counter += 1
        // A batch starts at 0; one after a finished batch adds to it.
        if done == 0, job.total > 0, job.done == job.total {
            job.baseDone = job.done
            job.baseTotal = job.total
        }
        job.stage = .files
        job.done = job.baseDone + done
        job.total = job.baseTotal + total
        job.fileName = fileName
        job.touched = counter
        jobs[ticket.id] = job
    }

    /// What the import made, for the summary when it ends. `problem` keeps
    /// it up longer: something was skipped, flagged or failed.
    public mutating func note(_ text: String, problem: Bool = false, of ticket: Ticket) {
        guard !text.isEmpty else { return }
        jobs[ticket.id]?.notes.append(text)
        if problem { jobs[ticket.id]?.problem = true }
    }

    /// The import is over. When it was the last one running, what all of
    /// them said shows for a while.
    public mutating func endImport(_ ticket: Ticket, at now: Date) {
        guard let job = jobs.removeValue(forKey: ticket.id) else { return }
        finishedNotes += job.notes
        finishedProblem = finishedProblem || job.problem
        guard jobs.isEmpty else { return }
        if !finishedNotes.isEmpty {
            importSummary = Summary(
                text: finishedNotes.joined(separator: " · "), problem: finishedProblem,
                until: now.addingTimeInterval(finishedProblem ? Self.problemShown : Self.doneShown))
        }
        finishedNotes = []
        finishedProblem = false
    }

    public var isImporting: Bool { !jobs.isEmpty }

    // MARK: The plan

    /// A pass over the plan starts; `total` is how many files it has to
    /// read. A pass that overtakes another simply starts again.
    public mutating func beginPlanLoad(total: Int) {
        plan = PlanLoad(done: 0, total: total)
        planSummary = nil
    }

    public mutating func notePlanLoad(done: Int, total: Int) {
        guard plan != nil else { return }
        plan = PlanLoad(done: done, total: total)
    }

    /// The pass finished. `leftOut` pictures didn't fit in the memory set
    /// aside for them; the summary says so, and stays up longer.
    public mutating func endPlanLoad(files: Int, leftOut: Int, at now: Date) {
        plan = nil
        let text: String
        if leftOut > 0 {
            text = "Plan in memory, except \(leftOut) picture\(leftOut == 1 ? "" : "s"): not enough memory set aside. They load when shown."
        } else {
            text = files == 1 ? "Plan in memory: 1 file" : "Plan in memory: \(files) files"
        }
        planSummary = Summary(
            text: text, problem: leftOut > 0,
            until: now.addingTimeInterval(leftOut > 0 ? Self.problemShown : Self.doneShown))
    }

    /// The pass stopped without finishing: no plan any more, or a newer
    /// pass is about to take over.
    public mutating func cancelPlanLoad() {
        plan = nil
    }

    /// macOS asked for memory back and the plan was let go of.
    public mutating func notePlanReleased(at now: Date) {
        plan = nil
        planSummary = Summary(
            text: "Plan let go of: the Mac is short of memory. It loads again when there is room.",
            problem: true, until: now.addingTimeInterval(Self.problemShown))
    }

    public var isLoadingPlan: Bool { plan != nil }

    // MARK: Showing

    /// The bar's lines, imports first. Empty when there's nothing to say.
    public var lines: [Line] {
        [importLine, planLine].compactMap { $0 }
    }

    private var importLine: Line? {
        if jobs.isEmpty {
            return importSummary.map {
                Line(kind: .importing, title: $0.text, tone: $0.problem ? .problem : .done)
            }
        }
        let running = jobs.values.sorted { $0.order < $1.order }
        let counted = running.filter { $0.total > 0 }
        if running.contains(where: { $0.stage == .files }), !counted.isEmpty {
            let done = counted.reduce(0) { $0 + $1.done }
            let total = counted.reduce(0) { $0 + $1.total }
            let current = counted.max { $0.touched < $1.touched }
            return Line(
                kind: .importing,
                title: "Importing \(min(done + 1, total)) of \(total)",
                detail: current?.fileName,
                fraction: Double(done) / Double(max(total, 1)),
                tone: .working)
        }
        for job in running {
            if case .document(let name) = job.stage {
                return Line(kind: .importing, title: "Importing \u{201C}\(name)\u{201D}", tone: .working)
            }
        }
        if running.contains(where: { $0.stage == .preparing }) {
            return Line(kind: .importing, title: "Getting files ready", tone: .working)
        }
        return Line(kind: .importing, title: "Making slides", tone: .working)
    }

    private var planLine: Line? {
        if let plan {
            let total = max(plan.total, 1)
            return Line(
                kind: .plan, title: "Loading the plan into memory \(min(plan.done, plan.total)) of \(plan.total)",
                fraction: Double(min(plan.done, total)) / Double(total), tone: .working)
        }
        return planSummary.map { Line(kind: .plan, title: $0.text, tone: $0.problem ? .problem : .done) }
    }

    // MARK: Summaries going away

    /// When the next summary is due to go; nil when none is showing.
    public var nextExpiry: Date? {
        [jobs.isEmpty ? importSummary?.until : nil, plan == nil ? planSummary?.until : nil]
            .compactMap { $0 }.min()
    }

    /// Takes down the summaries whose time is up.
    public mutating func expire(at now: Date) {
        if let until = importSummary?.until, until <= now { importSummary = nil }
        if let until = planSummary?.until, until <= now { planSummary = nil }
    }

    /// The operator closed a summary.
    public mutating func dismiss(_ kind: Line.Kind) {
        switch kind {
        case .importing: importSummary = nil
        case .plan: planSummary = nil
        }
    }
}
