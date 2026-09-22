import SwiftUI
import Charts
import StrandDesign
import WhoopStore
import WhoopProtocol

/// Medications tab — dose logging for the session plus a vital-response preview from real nightly metrics.
/// Nothing is persisted yet; added medications reset on relaunch. The response chart reads Repository
/// daily rows around each medication's start date.
struct MedicationsView: View {
    @EnvironmentObject var repo: Repository

    /// One scheduled dose row in today's plan. `due` marks the dose currently actionable
    /// (shows the "Log dose" affordance); `taken` marks it logged.
    private struct ScheduledDose: Identifiable {
        let id = UUID()
        var time: String
        var name: String
        var detail: String
        var startDate: Date
        var trackVitals: Bool
        var taken: Bool
        var due: Bool
    }

    /// The vital the response chart plots. Deltas below the chart summarise all three at once.
    private enum VitalMetric: String, CaseIterable {
        case restingHR = "Resting HR"
        case hrv = "HRV"
        case sleep = "Sleep"
    }

    private struct VitalPoint: Identifiable {
        let id = UUID()
        let dayKey: String
        let date: Date
        let value: Double
    }

    @State private var doses: [ScheduledDose] = []
    @State private var selectedMedication = ""
    @State private var selectedMetric: VitalMetric = .restingHR
    @State private var showAddSheet = false

    private var medicationNames: [String] {
        Array(Set(doses.map(\.name))).sorted()
    }

    private var trackedMedications: [String] {
        Array(Set(doses.filter(\.trackVitals).map(\.name))).sorted()
    }

    private static let dayKeyParser: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    var body: some View {
        ScreenScaffold(
            title: "Medications",
            subtitle: "Log doses and see how your vitals respond.",
            topBackground: liquidScaffoldSky()
        ) {
            VStack(alignment: .leading, spacing: NoopMetrics.sectionSpacing) {
                scheduleCard
                if PhoneComputeRuntime.isFinalHosted {
                    CanonicalPhysiologySection(families: ["insights", "illness"])
                } else if !trackedMedications.isEmpty {
                    vitalResponseCard
                }
            }
        }
        .sheet(isPresented: $showAddSheet) {
            addMedicationSheet
                #if os(iOS)
                .noopSheetPresentation(largeFirst: true)
                #endif
                #if os(macOS)
                .frame(minWidth: NoopMetrics.editorSheetMinWidth, minHeight: NoopMetrics.editorSheetMinHeight)
                #endif
        }
        .onChangeCompat(of: medicationNames) { names in
            if selectedMedication.isEmpty || !names.contains(selectedMedication) {
                selectedMedication = names.first ?? ""
            }
        }
    }

    // MARK: - Schedule card

    private var scheduleCard: some View {
        StrandCard(padding: NoopMetrics.space5) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(todayOverline).strandOverline()
                    HStack(spacing: NoopMetrics.space2 + 2) {
                        Image(systemName: "pills")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text("Schedule")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                Text("Tap a dose when you take it. Times come from each medication's plan.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                if doses.isEmpty {
                    emptyScheduleState
                } else {
                    doseProgress

                    VStack(spacing: 0) {
                        ForEach($doses) { $dose in
                            doseRow(dose: dose) {
                                withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
                                    dose.taken = true
                                    dose.due = false
                                }
                            }
                            if dose.id != doses.last?.id {
                                Rectangle().fill(StrandPalette.hairline).frame(height: 1)
                            }
                        }
                    }
                }

                NoopButton("Add medication", systemImage: "plus", kind: .secondary, fullWidth: true) {
                    showAddSheet = true
                }
            }
        }
    }

    private var emptyScheduleState: some View {
        VStack(spacing: NoopMetrics.space3) {
            Image(systemName: "pills")
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(StrandPalette.textTertiary)
                .accessibilityHidden(true)
            Text("No medications yet")
                .font(StrandFont.headline)
                .foregroundStyle(StrandPalette.textPrimary)
            Text("Add a medication to build today's schedule and optionally track how your vitals respond.")
                .font(StrandFont.footnote)
                .foregroundStyle(StrandPalette.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, NoopMetrics.space3)
        }
        .frame(maxWidth: .infinity)
        .padding(.horizontal, NoopMetrics.space2)
        .padding(.vertical, NoopMetrics.space4)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }

    private var takenCount: Int { doses.filter(\.taken).count }

    private var doseProgress: some View {
        VStack(alignment: .leading, spacing: NoopMetrics.space2) {
            HStack {
                Text("Doses logged")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                Spacer(minLength: 0)
                Text("\(takenCount) of \(doses.count)")
                    .font(StrandFont.captionNumber)
                    .foregroundStyle(StrandPalette.textPrimary)
            }
            PipBar(value: Double(takenCount), range: 0...Double(max(doses.count, 1)),
                   segments: max(doses.count, 1), tint: StrandPalette.accent)
                .accessibilityHidden(true)
        }
    }

    private func doseRow(dose: ScheduledDose, onLog: @escaping () -> Void) -> some View {
        HStack(spacing: NoopMetrics.space3) {
            Text(dose.time)
                .font(StrandFont.captionNumber)
                .foregroundStyle(StrandPalette.textSecondary)
                .frame(width: 62, alignment: .leading)
            VStack(alignment: .leading, spacing: 1) {
                Text(dose.name)
                    .font(StrandFont.headline)
                    .foregroundStyle(dose.taken ? StrandPalette.textSecondary : StrandPalette.textPrimary)
                Text(dose.detail)
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Spacer(minLength: 0)
            if dose.taken {
                Label("Taken", systemImage: "checkmark.circle.fill")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.accent)
            } else if dose.due {
                Button(action: onLog) {
                    Text("Log dose")
                        .font(StrandFont.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(StrandPalette.accent)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(StrandPalette.accent.opacity(0.12), in: Capsule())
                        .overlay(Capsule().strokeBorder(StrandPalette.accent.opacity(0.4), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Log \(dose.name) as taken"))
            } else {
                Label(dose.time, systemImage: "circle")
                    .font(StrandFont.caption)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
        }
        .padding(.vertical, NoopMetrics.space3 - 1)
    }

    private var todayOverline: String {
        let formatted = DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .none)
        return String(localized: "Today") + " · " + formatted
    }

    // MARK: - Vital response card

    private var vitalResponseCard: some View {
        StrandCard(padding: NoopMetrics.space5) {
            VStack(alignment: .leading, spacing: NoopMetrics.space4) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Vitals").strandOverline()
                    HStack(spacing: NoopMetrics.space2 + 2) {
                        Image(systemName: "waveform.path.ecg")
                            .foregroundStyle(StrandPalette.liquidHeart)
                            .accessibilityHidden(true)
                        Text("Vital response")
                            .font(StrandFont.title2)
                            .foregroundStyle(StrandPalette.textPrimary)
                    }
                }
                Text("Resting heart rate, HRV and sleep in the 7 days before vs after a start date.")
                    .font(StrandFont.subhead)
                    .foregroundStyle(StrandPalette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                medicationChips

                if vitalPoints.isEmpty {
                    Text("Not enough nights yet to compare before and after the start date.")
                        .font(StrandFont.subhead)
                        .foregroundStyle(StrandPalette.textTertiary)
                        .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
                } else {
                    SegmentedPillControl(VitalMetric.allCases, selection: $selectedMetric,
                                         fillsAvailableWidth: true) { $0.rawValue }

                    vitalChart

                    deltaTiles
                }

                Text("7-day averages before vs after the start date. Correlation, not causation — not medical advice.")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var medicationChips: some View {
        HStack(spacing: NoopMetrics.space2) {
            ForEach(trackedMedications, id: \.self) { med in
                let selected = med == selectedMedication
                Button {
                    withAnimation(.timingCurve(0.22, 1, 0.36, 1, duration: 0.24)) {
                        selectedMedication = med
                    }
                } label: {
                    Text(med)
                        .font(StrandFont.captionNumber)
                        .foregroundStyle(selected ? StrandPalette.accent : StrandPalette.textSecondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 7)
                        .background(selected ? StrandPalette.accent.opacity(0.12) : StrandPalette.surfaceInset,
                                    in: Capsule())
                        .overlay(Capsule().strokeBorder(selected ? StrandPalette.accent.opacity(0.4)
                                                                 : StrandPalette.hairline, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: Vital chart (Repository-backed before/after series)

    private var selectedStartDate: Date? {
        guard !selectedMedication.isEmpty else { return nil }
        return doses.filter { $0.name == selectedMedication && $0.trackVitals }
            .map(\.startDate)
            .min()
    }

    private func vitalValue(for metric: VitalMetric, day: DailyMetric) -> Double? {
        switch metric {
        case .restingHR:
            return day.restingHr.map(Double.init)
        case .hrv:
            return day.avgHrv
        case .sleep:
            if let efficiency = day.efficiency { return efficiency * 100 }
            return day.totalSleepMin
        }
    }

    private func metricPoints(for metric: VitalMetric) -> [VitalPoint] {
        guard let start = selectedStartDate else { return [] }
        let cal = Calendar.current
        let startDay = cal.startOfDay(for: start)
        let windowStart = cal.date(byAdding: .day, value: -13, to: startDay) ?? startDay
        let windowEnd = cal.date(byAdding: .day, value: 13, to: startDay) ?? startDay
        let fromKey = Repository.localDayKey(windowStart)
        let toKey = Repository.localDayKey(windowEnd)
        let rows = repo.days.filter { $0.day >= fromKey && $0.day <= toKey }
        return rows.compactMap { row -> VitalPoint? in
            guard let value = vitalValue(for: metric, day: row) else { return nil }
            guard let date = Self.dayKeyParser.date(from: row.day) else { return nil }
            return VitalPoint(dayKey: row.day, date: date, value: value)
        }.sorted { $0.dayKey < $1.dayKey }
    }

    private var vitalPoints: [VitalPoint] {
        let points = metricPoints(for: selectedMetric)
        return points.count >= 4 ? points : []
    }

    private var startMarkerDate: Date? {
        selectedStartDate
    }

    private func beforeAverage(for metric: VitalMetric) -> Double? {
        average(for: metric, beforeStart: true)
    }

    private func afterAverage(for metric: VitalMetric) -> Double? {
        average(for: metric, beforeStart: false)
    }

    private var metricColor: Color {
        switch selectedMetric {
        case .restingHR: StrandPalette.liquidHeart
        case .hrv: StrandPalette.metricPurple
        case .sleep: StrandPalette.sleepDeep
        }
    }

    private var vitalChart: some View {
        let points = vitalPoints
        let values = points.map(\.value)
        let yDomain = (values.min()! - 4)...(values.max()! + 4)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline) {
                Text(selectedMetric.rawValue)
                    .font(StrandFont.subhead)
                    .fontWeight(.semibold)
                    .foregroundStyle(metricColor)
                Spacer(minLength: 0)
                Text("Around start date")
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
            }
            Chart {
                if let before = beforeAverage(for: selectedMetric) {
                    RuleMark(y: .value("Before avg", before))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                        .foregroundStyle(StrandPalette.textTertiary.opacity(0.8))
                }
                if let after = afterAverage(for: selectedMetric) {
                    RuleMark(y: .value("After avg", after))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [2, 4]))
                        .foregroundStyle(StrandPalette.textTertiary.opacity(0.8))
                }
                if let marker = startMarkerDate {
                    RuleMark(x: .value("Started", marker))
                        .lineStyle(StrokeStyle(lineWidth: 1.2, dash: [5, 4]))
                        .foregroundStyle(StrandPalette.accent)
                        .annotation(position: .top, alignment: .center) {
                            Text("Started")
                                .font(StrandFont.overlineScaled(9))
                                .tracking(0.5)
                                .textCase(.uppercase)
                                .foregroundStyle(StrandPalette.accent)
                        }
                }
                ForEach(points) { point in
                    AreaMark(x: .value("Day", point.date), y: .value("Value", point.value))
                        .interpolationMethod(.catmullRom)
                        .foregroundStyle(LinearGradient(
                            colors: [metricColor.opacity(0.18), Color.clear],
                            startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Day", point.date), y: .value("Value", point.value))
                        .interpolationMethod(.catmullRom)
                        .lineStyle(StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .foregroundStyle(metricColor)
                }
            }
            .chartYScale(domain: yDomain)
            .chartPlotStyle { plotArea in plotArea.clipped() }
            .chartXAxis {
                AxisMarks(values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                    AxisValueLabel(format: .dateTime.month(.abbreviated).day())
                        .foregroundStyle(StrandPalette.textTertiary)
                        .font(StrandFont.footnote)
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 4)) { _ in
                    AxisGridLine().foregroundStyle(StrandPalette.hairline.opacity(0.4))
                    AxisValueLabel()
                        .foregroundStyle(StrandPalette.textTertiary)
                        .font(StrandFont.footnote)
                }
            }
            .frame(height: 160)
            .accessibilityLabel(Text("\(selectedMetric.rawValue) trend around the medication start date"))
        }
    }

    private var deltaTiles: some View {
        HStack(spacing: NoopMetrics.space2) {
            deltaTile(label: "Resting HR", value: deltaText(metric: .restingHR, unit: "bpm"),
                      color: StrandPalette.liquidHeart)
            deltaTile(label: "HRV", value: deltaText(metric: .hrv, unit: "ms"),
                      color: StrandPalette.metricPurple)
            deltaTile(label: "Sleep", value: deltaText(metric: .sleep, unit: sleepDeltaUnit),
                      color: StrandPalette.sleepDeep)
        }
    }

    private var sleepDeltaUnit: String {
        guard let start = selectedStartDate else { return "min" }
        let startKey = Repository.localDayKey(start)
        let row = repo.days.first(where: { $0.day == startKey })
        if let efficiency = row?.efficiency { return "%" }
        return "min"
    }

    private func deltaText(metric: VitalMetric, unit: String) -> String {
        guard let before = average(for: metric, beforeStart: true),
              let after = average(for: metric, beforeStart: false) else { return "—" }
        let delta = after - before
        let sign = delta >= 0 ? "+" : "−"
        return "\(sign)\(Int(abs(delta).rounded())) \(unit)"
    }

    private func average(for metric: VitalMetric, beforeStart: Bool) -> Double? {
        guard PhoneComputeRuntime.permitsLocal("MedicationsView.physiological_response") else { return nil }
        PhoneComputeRuntime.entered("MedicationsView.physiological_response")
        guard let start = selectedStartDate else { return nil }
        let startKey = Repository.localDayKey(start)
        let slice = metricPoints(for: metric).filter {
            beforeStart ? $0.dayKey < startKey : $0.dayKey >= startKey
        }
        let values = beforeStart ? slice.suffix(7).map(\.value) : slice.prefix(7).map(\.value)
        guard values.count >= 3 else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private func deltaTile(label: LocalizedStringKey, value: String, color: Color) -> some View {
        VStack(spacing: 3) {
            Text(label).strandOverline()
            Text(value)
                .font(StrandFont.number(16))
                .foregroundStyle(color)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, NoopMetrics.space2 + 1)
        .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    // MARK: - Add medication sheet

    @State private var draftName = ""
    @State private var draftDose = ""
    @State private var draftTimes = ["8:00 AM"]
    @State private var draftStartDate = Date()
    @State private var draftReminders = true
    @State private var draftTrackVitals = true

    private var addMedicationSheet: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: NoopMetrics.space4) {
            HStack {
                Text("Add medication")
                    .font(StrandFont.title2)
                    .foregroundStyle(StrandPalette.textPrimary)
                Spacer(minLength: 0)
                Button {
                    showAddSheet = false
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(StrandPalette.textSecondary)
                        .frame(width: 30, height: 30)
                        .background(StrandPalette.surfaceInset, in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("Close"))
            }

            formField(label: String(localized: "Name"), text: $draftName, prompt: "Medication name")
            formField(label: String(localized: "Dose"), text: $draftDose, prompt: "25 mg")

            VStack(alignment: .leading, spacing: 6) {
                Text("Schedule").strandOverline()
                ForEach(Array(draftTimes.enumerated()), id: \.offset) { index, time in
                    HStack(spacing: NoopMetrics.space2 + 2) {
                        Image(systemName: "clock")
                            .foregroundStyle(StrandPalette.accent)
                            .accessibilityHidden(true)
                        Text(time)
                            .font(StrandFont.mono(13))
                            .foregroundStyle(StrandPalette.textPrimary)
                        Spacer(minLength: 0)
                        if draftTimes.count > 1 {
                            Button {
                                draftTimes.remove(at: index)
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundStyle(StrandPalette.textTertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(Text("Remove \(time)"))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                    )
                }
                Button {
                    draftTimes.append(draftTimes.count % 2 == 0 ? "8:00 AM" : "9:30 PM")
                } label: {
                    Label("Add a time", systemImage: "plus")
                        .font(StrandFont.subhead)
                        .fontWeight(.semibold)
                        .foregroundStyle(StrandPalette.accent)
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Start date").strandOverline()
                DatePicker("Start date", selection: $draftStartDate, displayedComponents: .date)
                    .labelsHidden()
                    .datePickerStyle(.compact)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                    )
            }

            formToggle(title: String(localized: "Dose reminders"),
                       detail: String(localized: "Notify when a dose is due."),
                       isOn: $draftReminders)
            formToggle(title: String(localized: "Track vital response"),
                       detail: String(localized: "Compare HR, HRV and sleep before vs after the start date."),
                       isOn: $draftTrackVitals)

            NoopButton("Save medication", kind: .primary, fullWidth: true) {
                saveDraft()
            }
            .disabled(draftName.trimmingCharacters(in: .whitespaces).isEmpty)
            NoopButton("Cancel", kind: .tertiary, fullWidth: true) {
                showAddSheet = false
            }
        }
        .padding(NoopMetrics.space5)
        }
        .background(StrandPalette.surfaceBase.ignoresSafeArea())
    }

    private func formField(label: String, text: Binding<String>, prompt: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label).strandOverline()
            TextField(prompt, text: text)
                .textFieldStyle(.plain)
                .font(StrandFont.mono(13))
                .foregroundStyle(StrandPalette.textPrimary)
                .padding(.horizontal, 12)
                .padding(.vertical, 9)
                .background(StrandPalette.surfaceInset, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .strokeBorder(StrandPalette.hairline, lineWidth: 1)
                )
        }
    }

    private func formToggle(title: String, detail: String, isOn: Binding<Bool>) -> some View {
        HStack(alignment: .center, spacing: NoopMetrics.space4) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(StrandFont.body)
                    .foregroundStyle(StrandPalette.textPrimary)
                Text(detail)
                    .font(StrandFont.footnote)
                    .foregroundStyle(StrandPalette.textTertiary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .tint(StrandPalette.accent)
        }
    }

    /// Session-only save: keeps the new medication in memory for the session so the schedule and
    /// the chip row react, then resets the draft.
    private func saveDraft() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        let detail = draftDose.trimmingCharacters(in: .whitespaces)
        for time in draftTimes {
            doses.append(ScheduledDose(time: time, name: name,
                                       detail: detail.isEmpty ? "—" : detail,
                                       startDate: draftStartDate,
                                       trackVitals: draftTrackVitals,
                                       taken: false, due: false))
        }
        doses.sort { $0.time < $1.time }
        if selectedMedication.isEmpty { selectedMedication = name }
        draftName = ""; draftDose = ""; draftTimes = ["8:00 AM"]
        draftStartDate = Date(); draftReminders = true; draftTrackVitals = true
        showAddSheet = false
    }
}
