import TaskFerryCore
import SwiftUI

struct ContentView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            StepBar()
            Divider()
            Group {
                switch model.step {
                case .connect: ConnectView()
                case .choose: ChooseView()
                case .preview: PreviewView()
                case .migrate: MigrateView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            FooterBar()
        }
        .frame(minWidth: 780, minHeight: 560)
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil },
            set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}

// MARK: Chrome

struct StepBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            ForEach(AppModel.Step.allCases) { step in
                Button {
                    model.step = step
                } label: {
                    HStack(spacing: 6) {
                        Text("\(step.rawValue + 1)")
                            .font(.caption.weight(.semibold))
                            .frame(width: 20, height: 20)
                            .background(Circle().fill(step == model.step ? Color.accentColor : Color.secondary.opacity(0.25)))
                            .foregroundStyle(step == model.step ? Color.white : Color.primary)
                        Text(step.title)
                            .fontWeight(step == model.step ? .semibold : .regular)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 5)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(!model.canEnter(step))
                if step != AppModel.Step.allCases.last {
                    Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                }
            }
            Spacer()
            if let busy = model.busy {
                ProgressView().controlSize(.small)
                Text(busy).font(.callout).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct FooterBar: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack {
            Text(model.nextBlocker ?? "Apple Reminders is only changed if you ask to mark migrated reminders as completed.")
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            if let previous = AppModel.Step(rawValue: model.step.rawValue - 1) {
                Button("Back") { model.step = previous }
                    .disabled(model.isRunning)
            }
            if let next = AppModel.Step(rawValue: model.step.rawValue + 1) {
                Button("Continue") { model.step = next }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!model.canEnter(next))
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

struct Badge: View {
    let text: String
    let highlighted: Bool

    var body: some View {
        Text(text)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(highlighted ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.15)))
            .foregroundStyle(highlighted ? Color.accentColor : Color.secondary)
    }
}

// MARK: 1. Connect

struct ConnectView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox("Apple Reminders") {
                    VStack(alignment: .leading, spacing: 8) {
                        switch model.access {
                        case .granted:
                            Label("Connected: \(model.reminders.count) open reminders in \(model.lists.count) lists", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(.green)
                        case .unknown:
                            Text("The app needs to read your reminders. The only change it can make is marking migrated reminders as completed, and only when you ask.")
                            Button("Allow access to Reminders") { Task { await model.requestAccess() } }
                        case .denied:
                            Label("Access to Reminders is turned off for this app.", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("Turn it on in System Settings → Privacy & Security → Reminders, then come back.")
                                .foregroundStyle(.secondary)
                            Button("Check again") { model.refreshAccess(); Task { await model.loadReminders() } }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                GroupBox("Todoist") {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Paste your API token. You can find it in Todoist under Settings → Integrations → Developer.")
                        HStack {
                            SecureField("API token", text: $model.token)
                                .textFieldStyle(.roundedBorder)
                                .frame(maxWidth: 380)
                                .onSubmit { Task { await model.checkToken() } }
                            Button("Connect") { Task { await model.checkToken() } }
                                .disabled(model.token.trimmingCharacters(in: .whitespaces).isEmpty || model.tokenState == .checking)
                            if model.tokenState == .ok {
                                Button("Forget token") { model.forgetToken() }
                            }
                        }
                        switch model.tokenState {
                        case .empty:
                            Text("You can preview without a token, but you need one to migrate.").foregroundStyle(.secondary)
                        case .checking:
                            HStack { ProgressView().controlSize(.small); Text("Checking…") }
                        case .ok:
                            Label("Connected to Todoist", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                        case .failed(let message):
                            Label(message, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                        }
                        Text("The token is stored in your Mac's Keychain and sent only to api.todoist.com.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                }

                if let problem = model.mappingProblem {
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
            }
            .padding(20)
        }
    }
}

// MARK: 2. Choose lists

struct ChooseView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("\(model.selected.count) of \(model.lists.count) lists selected · \(model.selectedReminderCount) open reminders")
                    .font(.headline)
                Spacer()
                Button("Select all") { model.selected = Set(model.lists.map(\.id)) }
                Button("Select none") { model.selected = [] }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            List {
                ForEach(model.listGroups) { group in
                    Section {
                        ForEach(group.lists) { list in
                            Toggle(isOn: Binding(
                                get: { model.selected.contains(list.id) },
                                set: { on in if on { model.selected.insert(list.id) } else { model.selected.remove(list.id) } })) {
                                HStack {
                                    Text(list.title)
                                    if model.supplement.isInboxList(list.title) && group.name == nil {
                                        Badge(text: "goes to Todoist Inbox", highlighted: false)
                                    }
                                    Spacer()
                                    Text("\(model.openCount(list))").foregroundStyle(.secondary).monospacedDigit()
                                }
                            }
                        }
                    } header: {
                        if let name = group.name {
                            Toggle(isOn: Binding(
                                get: { model.isGroupSelected(group) },
                                set: { model.setGroup(group, selected: $0) })) {
                                Label(name, systemImage: "folder").font(.headline)
                            }
                        } else {
                            Text("Not in a group").font(.headline)
                        }
                    }
                }
            }
            .listStyle(.inset)

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Put everything inside one Todoist project (optional):")
                    TextField("e.g. Apple Reminders", text: $model.containerProject)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 260)
                    Spacer()
                }
                HStack {
                    Text(model.hasMapping
                         ? "Groups, sections, subtasks and link previews come from your mapping file."
                         : "Apple does not let apps read list groups, sections, subtasks or link previews. Add a mapping file to carry them over.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button(model.hasMapping ? "Show mapping file" : "Open mapping folder") { model.revealMappingFolder() }
                        .controlSize(.small)
                    Spacer()
                }
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
        }
    }
}

// MARK: 3. Preview

struct PreviewView: View {
    @EnvironmentObject var model: AppModel
    @State private var showWarnings = true

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    if let plan = model.plan {
                        if let c = model.createCounts {
                            Text("Will create \(c.projects) projects, \(c.sections) sections, \(c.tasks) tasks and \(c.alerts) alerts")
                                .font(.headline)
                            let existing = plan.tasks.count - c.tasks
                            if existing > 0 {
                                Text("\(existing) task\(existing == 1 ? " is" : "s are") already in Todoist and will be left alone.")
                                    .foregroundStyle(.secondary)
                            }
                        } else {
                            Text("Plan: \(plan.projects.count) projects, \(plan.sections.count) sections, \(plan.tasks.count) tasks, \(plan.alertCount) alerts")
                                .font(.headline)
                            Text("Connect Todoist in step 1 to see what already exists there.").foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Building the preview…").font(.headline)
                    }
                }
                Spacer()
                Button("Refresh") { Task { await model.buildPreview() } }
                    .disabled(model.busy != nil)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            if let plan = model.plan, !plan.warnings.isEmpty {
                DisclosureGroup(isExpanded: $showWarnings) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(plan.warnings) { w in
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(w.list) · \(w.subject)").font(.callout.weight(.medium)).lineLimit(1)
                                    Text(w.message).font(.callout).foregroundStyle(.secondary)
                                }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(maxHeight: 130)
                } label: {
                    Label("\(plan.warnings.count) thing\(plan.warnings.count == 1 ? "" : "s") to know before migrating", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 8)
            }

            Divider()
            List(model.previewRows) { row in
                HStack(spacing: 8) {
                    Image(systemName: icon(row.kind))
                        .foregroundStyle(row.kind == .task ? Color.secondary : Color.accentColor)
                        .frame(width: 16)
                    Text(row.title)
                        .fontWeight(row.kind == .task ? .regular : .semibold)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if !row.detail.isEmpty {
                        Text(row.detail).font(.callout).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    if !row.badge.isEmpty { Badge(text: row.badge, highlighted: row.isNew) }
                }
                .padding(.leading, CGFloat(row.indent) * 18)
            }
            .listStyle(.inset)
        }
        .task { await model.buildPreview() }
    }

    private func icon(_ kind: PreviewRow.Kind) -> String {
        switch kind {
        case .project: return "folder"
        case .section: return "rectangle.split.3x1"
        case .task: return "circle"
        }
    }
}

// MARK: 4. Migrate

struct MigrateView: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmReset = false
    @State private var confirmComplete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    if let c = model.createCounts {
                        if c.projects + c.sections + c.tasks + c.alerts == 0 {
                            Text("Everything in this selection is already in Todoist.").font(.headline)
                        } else {
                            Text("Ready to create \(c.projects) projects, \(c.sections) sections, \(c.tasks) tasks and \(c.alerts) alerts in Todoist.")
                                .font(.headline)
                        }
                    } else {
                        Text("Ready to migrate.").font(.headline)
                    }
                    Text("Your reminders stay in Apple Reminders. If the run is interrupted, start it again: it continues where it stopped and creates no duplicates.")
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                if model.isRunning {
                    Button("Stop") { model.stop() }
                } else {
                    Button(model.summary == nil ? "Start migration" : "Run again") { model.start() }
                        .buttonStyle(.borderedProminent)
                        .disabled(model.plan == nil || model.tokenState != .ok)
                }
            }

            if let p = model.progress {
                VStack(alignment: .leading, spacing: 4) {
                    ProgressView(value: Double(p.done), total: Double(max(p.total, 1)))
                    Text("\(p.done) of \(p.total) · \(p.message)").font(.callout).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            if let s = model.summary {
                GroupBox("Result") {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Created \(s.projectsCreated) projects, \(s.sectionsCreated) sections, \(s.tasksCreated) tasks and \(s.remindersCreated) alerts.")
                        if s.tasksAdopted + s.tasksSkipped > 0 {
                            Text("\(s.tasksAdopted + s.tasksSkipped) tasks were already there and were left alone.").foregroundStyle(.secondary)
                        }
                        if s.alertsSkippedAsPast > 0 {
                            Text("\(s.alertsSkippedAsPast) alert\(s.alertsSkippedAsPast == 1 ? " was" : "s were") for a time that has already passed and \(s.alertsSkippedAsPast == 1 ? "was" : "were") not created.")
                                .foregroundStyle(.secondary)
                        }
                        ForEach(s.warnings, id: \.self) { w in
                            Label(w, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }

            if let r = model.report {
                GroupBox("Check against Todoist") {
                    VStack(alignment: .leading, spacing: 6) {
                        if r.issues.isEmpty {
                            Label("All \(r.checked) tasks in Todoist match your reminders.", systemImage: "checkmark.seal.fill")
                                .foregroundStyle(.green)
                        } else {
                            Label("\(r.matching) of \(r.checked) tasks match. \(r.issues.count) difference\(r.issues.count == 1 ? "" : "s") found:", systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            ScrollView {
                                VStack(alignment: .leading, spacing: 6) {
                                    ForEach(r.issues) { issue in
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text("\(issue.task) · \(issue.field)").font(.callout.weight(.medium)).lineLimit(1)
                                            Text("expected \(issue.expected) · found \(issue.actual)").font(.callout).foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .frame(maxHeight: 150)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
                }
            }

            GroupBox("Activity") {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(model.log.enumerated()), id: \.offset) { index, line in
                                Text(line).font(.system(.callout, design: .monospaced)).id(index)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(6)
                    }
                    .onChange(of: model.log.count) { _, count in
                        if count > 0 { proxy.scrollTo(count - 1, anchor: .bottom) }
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            HStack {
                Button("Check against Todoist") { Task { await model.verifyNow() } }
                    .disabled(model.isRunning || model.plan == nil || model.tokenState != .ok)
                let completable = model.completableIds.count
                if completable > 0 {
                    Button("Mark \(completable) migrated reminder\(completable == 1 ? "" : "s") as completed in Reminders…") { confirmComplete = true }
                        .disabled(model.isRunning)
                        .confirmationDialog("Mark \(completable) reminder\(completable == 1 ? "" : "s") as completed in Apple Reminders?", isPresented: $confirmComplete) {
                            Button("Mark as completed") { Task { await model.completeMigratedInReminders() } }
                            Button("Cancel", role: .cancel) {}
                        } message: {
                            Text("Only reminders that were migrated and matched Todoist in the last check are affected. Nothing is deleted, and you can untick them in Reminders to undo this.")
                        }
                } else if let done = model.completedInReminders {
                    Text("Marked \(done) as completed in Reminders.").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Reset migration history…") { confirmReset = true }
                    .disabled(model.isRunning)
            }
        }
        .padding(20)
        .confirmationDialog("Reset migration history?", isPresented: $confirmReset) {
            Button("Reset history", role: .destructive) { Task { await model.resetHistory() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The app forgets which reminders it has already migrated. Nothing is removed from Todoist or Reminders. Tasks you have completed in Todoist since migrating would be created again on the next run.")
        }
    }
}
