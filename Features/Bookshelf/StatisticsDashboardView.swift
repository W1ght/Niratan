//
//  StatisticsDashboardView.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI

private let statisticsDashboardSpacing: CGFloat = 16
private let statisticsBookRankingLimit = 12
private let statisticsTrendChartHeight: CGFloat = 224
private let statisticsTrendChartLabelHeight: CGFloat = 18
private let statisticsTrendChartHorizontalSafeInset: CGFloat = 12
private let statisticsTrendChartScrollIndicatorSafeInset: CGFloat = 18
private let statisticsTrendTooltipWidth: CGFloat = 224
private let statisticsTrendTooltipEstimatedHeight: CGFloat = 184
private let statisticsTrendTooltipGap: CGFloat = 12
private let statisticsTrendHoverDelayNanoseconds: UInt64 = 20_000_000
private let statisticsTrendHoverUpdateInterval: TimeInterval = 1.0 / 24.0
private let statisticsTrendHoverMoveThreshold: CGFloat = 10
private let statisticsInitialSnapshotLoadDelay: TimeInterval = 0.02

private enum StatisticsTrendChartStyle: String, CaseIterable, Identifiable {
    case bar
    case line

    var id: String { rawValue }
}

private enum StatisticsTrendHotspotShape {
    case rectangle
    case circle
}

struct StatisticsDashboardView: View {
    let books: [BookMetadata]
    let shelves: [BookShelf]

    @Environment(UserConfig.self) private var userConfig
    @State private var snapshot = StatisticsDashboardSnapshot(days: [])
    @State private var loadingPlaceholderSnapshot: StatisticsDashboardSnapshot
    @State private var isLoadingSnapshot = true
    @State private var snapshotLoadGeneration = 0
    @State private var selectedMode: StatisticsRangeMode = .year
    @State private var selectedTrendGrain: StatisticsTrendGrain = .day
    @State private var selectedTrendMetric: StatisticsTrendMetric = .characters
    @State private var selectedTrendChartStyle: StatisticsTrendChartStyle = .bar
    @State private var selectedBookRankingMetric: StatisticsBookRankingMetric = .characters
    @State private var visibleBookRankingLimit = statisticsBookRankingLimit
    @State private var selectedAnchor: Date?
    @State private var selectedCalendarDate: Date?
    @State private var hasUserSelectedCalendarDate = false
    @State private var selectedStatisticsBook: BookMetadata?

    init(books: [BookMetadata], shelves: [BookShelf]) {
        self.books = books
        self.shelves = shelves
        let calendar = Calendar.current
        let today = calendar.startOfDay(for: Date())
        let windowRange = StatisticsDateRange.recentYear(endingAt: today, calendar: calendar)
        _loadingPlaceholderSnapshot = State(
            initialValue: StatisticsDashboardPlaceholder.snapshot(
                books: books,
                windowRange: windowRange,
                today: today,
                calendar: calendar
            )
        )
    }

    private var calendar: Calendar { .current }
    private var today: Date {
        StatisticsDayBoundary.reportingDay(
            containing: Date(),
            resetMinutes: userConfig.statisticsResetTime,
            calendar: calendar
        )
    }
    private var isInitialSnapshotLoading: Bool {
        isLoadingSnapshot && snapshot.days.isEmpty
    }
    private var displaySnapshot: StatisticsDashboardSnapshot {
        isInitialSnapshotLoading ? loadingPlaceholderSnapshot : snapshot
    }
    private var targetSettings: StatisticsTargetSettings {
        StatisticsTargetSettings(
            dailyTargetType: userConfig.dailyStatisticsTargetType,
            dailyCharacterTarget: userConfig.dailyStatisticsCharacterTarget,
            dailyDurationTargetMinutes: userConfig.dailyStatisticsDurationTargetMinutes,
            weeklyTargetDays: userConfig.weeklyStatisticsTargetDays
        ).clamped()
    }
    private var windowRange: StatisticsDateRange {
        StatisticsDateRange.recentYear(endingAt: today, calendar: calendar)
    }
    private var anchorDate: Date {
        windowRange.coerce(
            selectedAnchor ?? displaySnapshot.days.last?.date ?? today,
            calendar: calendar
        )
    }
    private var selectedRange: StatisticsDateRange {
        StatisticsDateRange.selectedRange(
            mode: selectedMode,
            anchor: anchorDate,
            window: windowRange,
            calendar: calendar
        )
    }
    private var latestCalendarDate: Date {
        windowRange.coerce(displaySnapshot.days.last?.date ?? today, calendar: calendar)
    }
    private var calendarSelectionDate: Date {
        windowRange.coerce(selectedCalendarDate ?? selectedAnchor ?? latestCalendarDate, calendar: calendar)
    }
    private var calendarSelectionDay: StatisticsDayAggregate? {
        displaySnapshot.days.first { calendar.isDate($0.date, inSameDayAs: calendarSelectionDate) }
    }
    private var todaySummary: StatisticsTodaySummary {
        StatisticsDashboardCalculator.todaySummary(
            snapshot: displaySnapshot,
            today: today,
            settings: targetSettings,
            calendar: calendar
        )
    }
    private var weekSummary: StatisticsWeekSummary {
        StatisticsDashboardCalculator.weekSummary(
            snapshot: displaySnapshot,
            today: today,
            settings: targetSettings,
            calendar: calendar
        )
    }
    private var rangeSummary: StatisticsRangeSummary {
        StatisticsDashboardCalculator.rangeSummary(
            days: displaySnapshot.days,
            range: selectedRange,
            settings: targetSettings,
            calendar: calendar
        )
    }
    private var speedSummary: StatisticsSpeedSummary {
        StatisticsDashboardCalculator.speedSummary(
            days: displaySnapshot.days,
            range: selectedRange,
            calendar: calendar
        )
    }
    private var trendPoints: [StatisticsTrendPoint] {
        StatisticsDashboardCalculator.trendPoints(
            grain: selectedTrendGrain,
            range: selectedRange,
            days: displaySnapshot.days,
            calendar: calendar
        )
    }
    private var shelfComparisonRows: [StatisticsShelfComparisonRow] {
        StatisticsDashboardCalculator.shelfComparisonRows(
            books: displaySnapshot.books,
            shelves: shelves,
            days: displaySnapshot.days,
            range: selectedRange,
            unshelvedName: String(localized: "Unshelved"),
            calendar: calendar
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let contentWidth = max(proxy.size.width - 48, 0)
            ScrollView {
                VStack(alignment: .leading, spacing: statisticsDashboardSpacing) {
                    header
                    corruptStatisticsWarning
                    if isInitialSnapshotLoading {
                        loadingDashboardPlaceholder(width: contentWidth)
                    } else if snapshot.days.isEmpty {
                        emptyDashboardState
                    } else {
                        dashboardLayoutWithLoadingOverlay(width: contentWidth)
                    }
                }
                .frame(width: contentWidth, alignment: .topLeading)
                .padding(24)
            }
            .scrollIndicators(.automatic)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background { NativeGlassPageBackground() }
        .onAppear(perform: reloadSnapshot)
        .onChange(of: books) { _, _ in
            reloadSnapshot()
        }
        .onChange(of: selectedRange) { _, _ in
            visibleBookRankingLimit = statisticsBookRankingLimit
        }
        .onChange(of: selectedBookRankingMetric) { _, _ in
            visibleBookRankingLimit = statisticsBookRankingLimit
        }
        .sheet(item: $selectedStatisticsBook) { book in
            StatisticsBookDetailPanel(book: book, onStatisticsChanged: reloadSnapshot)
                .frame(minWidth: 780, minHeight: 560)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Statistics")
                .font(.largeTitle.weight(.bold))
            Text(selectedRangeTitle)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private var emptyDashboardState: some View {
        VStack(alignment: .leading, spacing: statisticsDashboardSpacing) {
            targetSettingsSection
                .frame(maxWidth: 560, alignment: .topLeading)

            ContentUnavailableView {
                Label("No Reading Records", systemImage: "chart.xyaxis.line")
            } description: {
                Text("Open a book and start reading with statistics enabled.")
            }
            .frame(maxWidth: .infinity, minHeight: 260)
            .nativeGlassCardSurface(cornerRadius: 18)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func loadingDashboardPlaceholder(width: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            dashboardLayout(width: width)
                .redacted(reason: .placeholder)
                .allowsHitTesting(false)
                .accessibilityHidden(true)

            loadingStatusPill
                .padding(12)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func dashboardLayout(width: CGFloat) -> some View {
        VStack(spacing: statisticsDashboardSpacing) {
            fullWidthTrendSection
            dashboardColumns(width: width)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func dashboardLayoutWithLoadingOverlay(width: CGFloat) -> some View {
        ZStack(alignment: .topTrailing) {
            dashboardLayout(width: width)

            if isLoadingSnapshot {
                loadingStatusPill
                    .padding(12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private var loadingStatusPill: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
            Text("Loading Statistics")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .glassEffect(.regular, in: Capsule())
        .help(String(localized: "Scanning local reading records."))
    }

    private var fullWidthTrendSection: some View {
        trendSection
            .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func dashboardColumns(width: CGFloat) -> some View {
        if width >= 1_260 {
            let columnWidth = max((width - statisticsDashboardSpacing * 2) / 3, 260)
            let doubleColumnWidth = columnWidth * 2 + statisticsDashboardSpacing
            HStack(alignment: .top, spacing: statisticsDashboardSpacing) {
                VStack(spacing: statisticsDashboardSpacing) {
                    todaySection
                    targetSettingsSection
                    weekSection
                }
                .frame(width: columnWidth, alignment: .topLeading)

                VStack(spacing: statisticsDashboardSpacing) {
                    shelfComparisonSection
                        .frame(width: doubleColumnWidth, alignment: .topLeading)

                    HStack(alignment: .top, spacing: statisticsDashboardSpacing) {
                        VStack(spacing: statisticsDashboardSpacing) {
                            selectedRangeSection
                            calendarSection
                        }
                        .frame(width: columnWidth, alignment: .topLeading)

                        VStack(spacing: statisticsDashboardSpacing) {
                            speedSummarySection
                            bookRankingSection
                        }
                        .frame(width: columnWidth, alignment: .topLeading)
                    }
                }
                .frame(width: doubleColumnWidth, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else if width >= 840 {
            HStack(alignment: .top, spacing: statisticsDashboardSpacing) {
                VStack(spacing: statisticsDashboardSpacing) {
                    todaySection
                    targetSettingsSection
                    weekSection
                    calendarSection
                    shelfComparisonSection
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)

                VStack(spacing: statisticsDashboardSpacing) {
                    selectedRangeSection
                    speedSummarySection
                    bookRankingSection
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        } else {
            VStack(spacing: statisticsDashboardSpacing) {
                todaySection
                targetSettingsSection
                weekSection
                calendarSection
                selectedRangeSection
                speedSummarySection
                bookRankingSection
                shelfComparisonSection
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    @ViewBuilder
    private var corruptStatisticsWarning: some View {
        if !snapshot.skippedCorruptBookIDs.isEmpty {
            Label("Some statistics are temporarily unavailable.", systemImage: "exclamationmark.triangle")
                .font(.callout.weight(.semibold))
                .foregroundStyle(.orange)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .nativeGlassCardSurface(cornerRadius: 14)
        }
    }

    private var todaySection: some View {
        StatisticsDashboardCard {
            HStack(alignment: .center, spacing: 20) {
                goalRing(percent: todaySummary.targetPercent)
                    .frame(width: 118, height: 118)

                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader(
                        title: "Today",
                        detail: String(
                            format: String(localized: "Goal: %@"),
                            dailyTargetText
                        )
                    )
                    metricGrid([
                        ("Duration", formatDuration(todaySummary.readingTime)),
                        ("Characters", formatCharacters(todaySummary.characters)),
                        ("Speed", formatOptionalSpeed(todaySummary.averageSpeedPerHour)),
                        ("Streak", String(format: String(localized: "%d days"), todaySummary.dailyStreakDays))
                    ])
                }
            }
        }
    }

    private var weekSection: some View {
        StatisticsDashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(
                    title: "This Week",
                    detail: String(format: String(localized: "%d/7 days"), weekSummary.metTargetDays)
                )
                metricGrid([
                    ("Duration", formatDuration(weekSummary.readingTime)),
                    ("Characters", formatCharacters(weekSummary.characters)),
                    ("Avg Characters", formatCharacters(weekSummary.averageCharactersPerElapsedDay)),
                    ("Speed", formatOptionalSpeed(weekSummary.averageSpeedPerHour))
                ])
                HStack(spacing: 8) {
                    ForEach(weekSummary.days, id: \.date) { day in
                        VStack(spacing: 4) {
                            Text(shortWeekday(day.date))
                                .font(.caption2.weight(.bold))
                            Text(day.percent.map { "\($0)%" } ?? "-")
                                .font(.caption2.monospacedDigit())
                        }
                        .foregroundStyle(day.metTarget ? Color.accentColor : .secondary)
                        .frame(maxWidth: .infinity, minHeight: 48)
                        .background {
                            RoundedRectangle(cornerRadius: 10, style: .continuous)
                                .fill(day.metTarget ? Color.accentColor.opacity(0.14) : Color.secondary.opacity(0.08))
                                .overlay {
                                    if day.isToday {
                                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                                            .strokeBorder(Color.accentColor.opacity(0.5), lineWidth: 1.5)
                                    }
                                }
                        }
                    }
                }
            }
        }
    }

    private var calendarSection: some View {
        StatisticsDashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(title: "Reading Calendar", detail: selectedRangeTitle)
                heatmap
                calendarSelectionFooter
            }
        }
    }

    private var heatmap: some View {
        let dates = StatisticsDashboardCalculator.dates(in: windowRange, calendar: calendar)
        let daysByDate = Dictionary(uniqueKeysWithValues: displaySnapshot.days.map { (calendar.startOfDay(for: $0.date), $0) })
        let maxCharacters = max(displaySnapshot.days.map(\.characters).max() ?? 0, 1)
        let rows = Array(repeating: GridItem(.fixed(12), spacing: 4), count: 7)
        return ScrollViewReader { scrollProxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHGrid(rows: rows, spacing: 4) {
                    ForEach(dates, id: \.self) { date in
                        let day = daysByDate[date]
                        let isSelectedDate = calendar.isDate(date, inSameDayAs: calendarSelectionDate)
                        Button {
                            let selectedDate = calendar.startOfDay(for: date)
                            selectedAnchor = selectedDate
                            selectedCalendarDate = selectedDate
                            hasUserSelectedCalendarDate = true
                        } label: {
                            RoundedRectangle(cornerRadius: 3, style: .continuous)
                                .fill(heatColor(characters: day?.characters ?? 0, maxCharacters: maxCharacters))
                                .frame(width: 12, height: 12)
                                .overlay {
                                    if selectedMode != .year, selectedRange.contains(date, calendar: calendar) {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .strokeBorder(Color.accentColor.opacity(0.45), lineWidth: 1)
                                    }
                                }
                                .overlay {
                                    if isSelectedDate {
                                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                                            .strokeBorder(Color.accentColor, lineWidth: 2)
                                    }
                                }
                        }
                        .buttonStyle(.plain)
                        .help("\(formattedFullDate(date)): \(formatCharacters(day?.characters ?? 0))")
                        .accessibilityLabel(Text("\(formattedFullDate(date)), \(formatCharacters(day?.characters ?? 0))"))
                    }
                }
                .padding(10)
            }
            .scrollIndicators(.visible)
            .onAppear {
                scrollHeatmap(to: calendarSelectionDate, with: scrollProxy)
            }
            .onChange(of: calendarSelectionDate) { _, date in
                scrollHeatmap(to: date, with: scrollProxy)
            }
        }
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var calendarSelectionFooter: some View {
        let selectedDay = calendarSelectionDay
        return VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text(String(format: String(localized: "Selected: %@"), formattedFullDate(calendarSelectionDate)))
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Spacer()
                if selectedDay == nil {
                    Text("No reading records")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                calendarSelectionMetric(
                    title: "Characters",
                    value: formatCharacters(selectedDay?.characters ?? 0),
                    systemImage: "textformat"
                )
                calendarSelectionMetric(
                    title: "Duration",
                    value: formatDuration(selectedDay?.readingTime ?? 0),
                    systemImage: "clock"
                )
                calendarSelectionMetric(
                    title: "Books",
                    value: formatCharacters(selectedDay?.activeBookCount ?? 0),
                    systemImage: "books.vertical"
                )
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var targetSettingsSection: some View {
        StatisticsDashboardCard {
            VStack(alignment: .leading, spacing: 0) {
                sectionHeader(title: "Goal", detail: dailyTargetText)
                    .padding(.bottom, 10)

                NativeSettingsRow("Goal Type") {
                    NativeGlassSegmentedPicker(
                        selection: Bindable(userConfig).dailyStatisticsTargetType,
                        values: DailyTargetType.allCases,
                        minSegmentWidth: 86
                    ) { targetType in
                        textOfDailyTargetType(targetType)
                    }
                }

                Divider().opacity(0.55)

                switch userConfig.dailyStatisticsTargetType {
                case .characters:
                    NativeSettingsStepperRow(
                        title: "Character Target",
                        value: "\(userConfig.dailyStatisticsCharacterTarget.formatted(.number.grouping(.automatic)))",
                        range: StatisticsTargetSettings.characterTargetRange,
                        step: StatisticsTargetSettings.characterTargetStep,
                        selection: Bindable(userConfig).dailyStatisticsCharacterTarget
                    )
                case .duration:
                    NativeSettingsStepperRow(
                        title: "Duration Target",
                        value: Duration.seconds(Double(userConfig.dailyStatisticsDurationTargetMinutes * 60)).formatted(.time(pattern: .hourMinute)),
                        range: StatisticsTargetSettings.durationTargetMinutesRange,
                        step: StatisticsTargetSettings.durationTargetMinutesStep,
                        selection: Bindable(userConfig).dailyStatisticsDurationTargetMinutes
                    )
                }

                Divider().opacity(0.55)

                NativeSettingsStepperRow(
                    title: "Weekly Target Days",
                    value: "\(userConfig.weeklyStatisticsTargetDays)",
                    range: StatisticsTargetSettings.weeklyTargetDaysRange,
                    step: 1,
                    selection: Bindable(userConfig).weeklyStatisticsTargetDays
                )

                Text("Goals recalculate historical progress and streaks.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.top, 10)
            }
        }
    }

    private var selectedRangeSection: some View {
        StatisticsDashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(title: "Selected Range", detail: selectedRangeTitle)
                metricGrid([
                    ("Duration", formatDuration(rangeSummary.readingTime)),
                    ("Characters", formatCharacters(rangeSummary.characters)),
                    ("Speed", formatOptionalSpeed(rangeSummary.averageSpeedPerHour)),
                    (selectedMode == .day ? "Goal Progress" : "Days Met", selectedMode == .day ? "\(rangeSummary.targetProgressPercent)%" : String(format: String(localized: "%d days"), rangeSummary.targetDays))
                ])
            }
        }
    }

    private var bookRankingSection: some View {
        let candidateRows = StatisticsDashboardCalculator.bookRankingRows(
            days: displaySnapshot.days,
            range: selectedRange,
            metric: selectedBookRankingMetric,
            limit: visibleBookRankingLimit + 1
        )
        let visibleRows = Array(candidateRows.prefix(visibleBookRankingLimit))

        return StatisticsDashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    sectionHeader(title: "Book Ranking", detail: selectedRangeTitle)
                    Spacer()
                    NativeGlassSegmentedPicker(
                        selection: $selectedBookRankingMetric,
                        values: StatisticsBookRankingMetric.allCases,
                        minSegmentWidth: 58
                    ) { metric in
                        bookRankingMetricText(metric)
                    }
                    .frame(maxWidth: 250)
                }

                VStack(spacing: 10) {
                    if visibleRows.isEmpty {
                        ContentUnavailableView("No reading records", systemImage: "list.number")
                            .frame(minHeight: 150)
                    } else {
                        let maxValue = max(visibleRows.map(bookRankingValue).max() ?? 0, 1)
                        ForEach(visibleRows) { row in
                            bookRankingRow(row, maxValue: maxValue)
                        }

                        if candidateRows.count > visibleRows.count {
                            Button {
                                visibleBookRankingLimit += statisticsBookRankingLimit
                            } label: {
                                Label("More Books", systemImage: "chevron.down")
                                    .frame(maxWidth: .infinity)
                            }
                            .buttonStyle(.glass)
                            .padding(.top, 2)
                        }
                    }
                }
            }
        }
    }

    private var speedSummarySection: some View {
        StatisticsDashboardCard {
            VStack(alignment: .leading, spacing: 14) {
                sectionHeader(title: "Speed Summary", detail: selectedRangeTitle)
                metricGrid([
                    ("Weighted Avg", formatOptionalSpeed(speedSummary.weightedAverageSpeedPerHour)),
                    ("Typical Day", formatOptionalSpeed(speedSummary.medianDaySpeedPerHour)),
                    ("Last 7 Active Days", formatOptionalSpeed(speedSummary.recentActiveDaySpeedPerHour)),
                    ("Change vs First 14", formatSignedPercent(speedSummary.speedChangePercent)),
                    ("Fastest Day", formatSpeedDay(speedSummary.bestDay)),
                    ("Slowest Day", formatSpeedDay(speedSummary.worstDay))
                ])
                Text("Speed ignores reading samples under 1 minute.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var shelfComparisonSection: some View {
        StatisticsDashboardCard {
            VStack(alignment: .leading, spacing: 10) {
                sectionHeader(title: "Shelf Comparison", detail: selectedRangeTitle)
                ScrollView(.horizontal) {
                    VStack(spacing: 0) {
                        shelfComparisonHeader
                        Divider().opacity(0.55)
                        if shelfComparisonRows.isEmpty {
                            ContentUnavailableView("No reading records", systemImage: "folder")
                                .frame(minWidth: 640, minHeight: 96)
                        } else {
                            ForEach(shelfComparisonRows) { row in
                                shelfComparisonRow(row)
                                if row.id != shelfComparisonRows.last?.id {
                                    Divider().opacity(0.45)
                                }
                            }
                        }
                    }
                    .frame(minWidth: 660, alignment: .topLeading)
                }
                .scrollIndicators(.automatic)
            }
        }
    }

    private var trendSection: some View {
        StatisticsDashboardCard {
            VStack(alignment: .leading, spacing: 12) {
                sectionHeader(title: "Range & Trend", detail: selectedRangeTitle)

                ScrollView(.horizontal) {
                    HStack(spacing: 8) {
                        trendControl(title: "Range") {
                            NativeGlassSegmentedPicker(
                                selection: $selectedMode,
                                values: StatisticsRangeMode.allCases,
                                minSegmentWidth: 50
                            ) { mode in
                                rangeModeText(mode)
                            }
                        }
                        trendControl(title: "Time Grain") {
                            NativeGlassSegmentedPicker(
                                selection: $selectedTrendGrain,
                                values: StatisticsTrendGrain.allCases,
                                minSegmentWidth: 50
                            ) { grain in
                                trendGrainText(grain)
                            }
                        }
                        trendControl(title: "Metric") {
                            NativeGlassSegmentedPicker(
                                selection: $selectedTrendMetric,
                                values: StatisticsTrendMetric.allCases,
                                minSegmentWidth: 66
                            ) { metric in
                                trendMetricText(metric)
                            }
                        }
                        trendControl(title: "Style") {
                            NativeGlassSegmentedPicker(
                                selection: $selectedTrendChartStyle,
                                values: StatisticsTrendChartStyle.allCases,
                                minSegmentWidth: 44
                            ) { style in
                                trendChartStyleText(style)
                            }
                        }
                    }
                    .padding(.bottom, 1)
                }
                .scrollIndicators(.never)

                Text("Range filters all dashboard cards. Time Grain changes only the trend chart.")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                trendChart
            }
        }
    }

    @ViewBuilder
    private var trendChart: some View {
        if trendPoints.isEmpty {
            ContentUnavailableView("No trend data", systemImage: "chart.bar")
                .frame(minHeight: 160)
        } else {
            StatisticsTrendChartView(
                trendPoints: trendPoints,
                trendGrain: selectedTrendGrain,
                trendMetric: selectedTrendMetric,
                chartStyle: selectedTrendChartStyle,
                formatTrendValue: formatTrendValue,
                formatCharacters: formatCharacters,
                formatDuration: formatDuration,
                formatOptionalSpeed: formatOptionalSpeed,
                formatAxisValue: formatAxisValue
            )
        }
    }

    private var dailyTargetText: String {
        switch targetSettings.dailyTargetType {
        case .characters:
            String(format: String(localized: "%@ chars"), targetSettings.dailyCharacterTarget.formatted(.number.grouping(.automatic)))
        case .duration:
            formatDuration(Double(targetSettings.dailyDurationTargetMinutes * 60))
        }
    }

    private var selectedRangeTitle: String {
        switch selectedMode {
        case .year:
            return String(localized: "Recent year")
        case .month:
            let components = calendar.dateComponents([.year, .month], from: selectedRange.start)
            return "\(components.year ?? 0)-\(components.month ?? 0)"
        case .week:
            return "\(monthDay(selectedRange.start))-\(monthDay(selectedRange.end))"
        case .day:
            return formattedDate(selectedRange.start)
        }
    }

    private func sectionHeader(title: LocalizedStringKey, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.headline.weight(.bold))
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func trendControl<Content: View>(
        title: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content()
        }
    }

    private func metricGrid(_ metrics: [(LocalizedStringKey, String)]) -> some View {
        LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
            ForEach(metrics.indices, id: \.self) { index in
                VStack(alignment: .leading, spacing: 8) {
                    Text(metrics[index].0)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(metrics[index].1)
                        .font(.title3.weight(.bold).monospacedDigit())
                        .lineLimit(1)
                        .minimumScaleFactor(0.75)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private func calendarSelectionMetric(
        title: LocalizedStringKey,
        value: String,
        systemImage: String
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: 14)

            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.callout.weight(.bold).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    @ViewBuilder
    private func bookRankingRow(_ row: StatisticsBookRankingRow, maxValue: Double) -> some View {
        if let book = books.first(where: { $0.id == row.id }) {
            Button {
                selectedStatisticsBook = book
            } label: {
                bookRankingRowContent(row, book: book, maxValue: maxValue)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
        } else {
            bookRankingRowContent(row, book: nil, maxValue: maxValue)
        }
    }

    private func bookRankingRowContent(
        _ row: StatisticsBookRankingRow,
        book: BookMetadata?,
        maxValue: Double
    ) -> some View {
        let value = bookRankingValue(row)
        return HStack(spacing: 12) {
            if let book {
                BookCover(book: book, width: 36)
            }

            Text(row.title)
                .font(.callout.weight(.semibold))
                .lineLimit(2)
                .frame(width: 138, alignment: .leading)

            GeometryReader { proxy in
                let width = max(proxy.size.width * CGFloat(value / maxValue), value > 0 ? 2 : 0)
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.secondary.opacity(0.12))
                    Capsule()
                        .fill(Color.accentColor.opacity(0.78))
                        .frame(width: width)
                }
            }
            .frame(height: 9)

            Text(bookRankingValueText(row))
                .font(.callout.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .frame(width: 92, alignment: .trailing)

            if book != nil {
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(minHeight: 54)
        .help("\(row.title): \(bookRankingValueText(row))")
    }

    private var shelfComparisonHeader: some View {
        HStack(spacing: 10) {
            shelfHeaderColumn("Shelf", width: 160, alignment: .leading)
            shelfHeaderColumn("Books", width: 56, alignment: .trailing)
            shelfHeaderColumn("Total Characters", width: 112, alignment: .trailing)
            shelfHeaderColumn("Recorded Characters", width: 118, alignment: .trailing)
            shelfHeaderColumn("Duration", width: 82, alignment: .trailing)
            shelfHeaderColumn("Avg Speed", width: 92, alignment: .trailing)
        }
        .padding(.vertical, 6)
    }

    private func shelfComparisonRow(_ row: StatisticsShelfComparisonRow) -> some View {
        HStack(spacing: 10) {
            shelfValueColumn(row.name, width: 160, alignment: .leading)
            shelfValueColumn(formatCharacters(row.bookCount), width: 56, alignment: .trailing)
            shelfValueColumn(formatCharacters(row.totalCharacters), width: 112, alignment: .trailing)
            shelfValueColumn(formatCharacters(row.recordedCharacters), width: 118, alignment: .trailing)
            shelfValueColumn(formatDuration(row.readingTime), width: 82, alignment: .trailing)
            shelfValueColumn(formatOptionalSpeed(row.averageSpeedPerHour), width: 92, alignment: .trailing)
        }
        .padding(.vertical, 7)
    }

    private func shelfHeaderColumn(
        _ text: LocalizedStringKey,
        width: CGFloat,
        alignment: Alignment
    ) -> some View {
        Text(text)
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: width, alignment: alignment)
    }

    private func shelfValueColumn(
        _ text: String,
        width: CGFloat,
        alignment: Alignment
    ) -> some View {
        Text(text)
            .font(.callout.monospacedDigit())
            .foregroundStyle(.primary)
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .frame(width: width, alignment: alignment)
    }

    private func goalRing(percent: Int) -> some View {
        ZStack {
            Circle()
                .stroke(Color.secondary.opacity(0.14), lineWidth: 13)
            Circle()
                .trim(from: 0, to: min(CGFloat(percent) / 100, 1))
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 13, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 2) {
                Text("\(percent)%")
                    .font(.title2.weight(.bold).monospacedDigit())
                Text("Goal")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func heatColor(characters: Int, maxCharacters: Int) -> Color {
        guard characters > 0 else { return Color.secondary.opacity(0.12) }
        let ratio = min(max(Double(characters) / Double(maxCharacters), 0.18), 1)
        return Color.accentColor.opacity(0.18 + 0.72 * ratio)
    }

    private func rangeModeText(_ mode: StatisticsRangeMode) -> some View {
        switch mode {
        case .year:
            Text("Year")
        case .month:
            Text("Month")
        case .week:
            Text("Week")
        case .day:
            Text("Day")
        }
    }

    private func trendGrainText(_ grain: StatisticsTrendGrain) -> some View {
        switch grain {
        case .day:
            Text("Day")
        case .week:
            Text("Week")
        case .month:
            Text("Month")
        }
    }

    private func bookRankingMetricText(_ metric: StatisticsBookRankingMetric) -> some View {
        switch metric {
        case .characters:
            Text("Characters")
        case .duration:
            Text("Duration")
        case .speed:
            Text("Speed")
        }
    }

    private func textOfDailyTargetType(_ targetType: DailyTargetType) -> some View {
        switch targetType {
        case .characters:
            Text("Characters")
        case .duration:
            Text("Duration")
        }
    }

    private func trendMetricText(_ metric: StatisticsTrendMetric) -> some View {
        switch metric {
        case .characters:
            Text("Characters")
        case .duration:
            Text("Duration")
        case .speed:
            Text("Speed")
        }
    }

    private func trendChartStyleText(_ style: StatisticsTrendChartStyle) -> some View {
        switch style {
        case .bar:
            Image(systemName: "chart.bar.fill")
                .accessibilityLabel(Text("Bar"))
        case .line:
            Image(systemName: "chart.xyaxis.line")
                .accessibilityLabel(Text("Line"))
        }
    }

    private func bookRankingValue(_ row: StatisticsBookRankingRow) -> Double {
        switch selectedBookRankingMetric {
        case .characters:
            Double(row.characters)
        case .duration:
            row.readingTime
        case .speed:
            Double(row.averageSpeedPerHour ?? 0)
        }
    }

    private func bookRankingValueText(_ row: StatisticsBookRankingRow) -> String {
        switch selectedBookRankingMetric {
        case .characters:
            formatCharacters(row.characters)
        case .duration:
            formatDuration(row.readingTime)
        case .speed:
            formatOptionalSpeed(row.averageSpeedPerHour)
        }
    }

    private func formatCharacters(_ characters: Int) -> String {
        characters.formatted(.number.grouping(.automatic))
    }

    private func formatSpeed(_ speed: Int) -> String {
        String(format: String(localized: "%@/h"), speed.formatted(.number.grouping(.automatic)))
    }

    private func formatOptionalSpeed(_ speed: Int?) -> String {
        speed.map(formatSpeed) ?? "-"
    }

    private func formatSignedPercent(_ percent: Int?) -> String {
        guard let percent else { return "-" }
        if percent > 0 {
            return "+\(percent)%"
        }
        return "\(percent)%"
    }

    private func formatSpeedDay(_ day: StatisticsSpeedDay?) -> String {
        guard let day else { return "-" }
        return "\(monthDay(day.date)) · \(formatSpeed(day.speedPerHour))"
    }

    private func formatAxisCharacters(_ characters: Int) -> String {
        characters.formatted(.number.notation(.compactName))
    }

    private func formatAxisValue(_ value: Double) -> String {
        switch selectedTrendMetric {
        case .characters:
            return formatAxisCharacters(Int(value.rounded()))
        case .duration:
            return formatDuration(value)
        case .speed:
            return String(format: String(localized: "%@/h"), formatAxisCharacters(Int(value.rounded())))
        }
    }

    private func formatTrendValue(_ value: Double) -> String {
        switch selectedTrendMetric {
        case .characters:
            return formatCharacters(Int(value.rounded()))
        case .duration:
            return formatDuration(value)
        case .speed:
            return formatSpeed(Int(value.rounded()))
        }
    }

    private func formatDuration(_ seconds: Double) -> String {
        let minutes = max(Int((seconds / 60).rounded()), 0)
        if minutes < 60 {
            return String(format: String(localized: "%dm"), minutes)
        }
        let hours = minutes / 60
        let remainder = minutes % 60
        if remainder == 0 {
            return String(format: String(localized: "%dh"), hours)
        }
        return String(format: String(localized: "%dh %dm"), hours, remainder)
    }

    private func formattedDate(_ date: Date) -> String {
        date.formatted(.dateTime.month(.defaultDigits).day(.defaultDigits))
    }

    private func formattedFullDate(_ date: Date) -> String {
        date.formatted(.dateTime.year().month(.defaultDigits).day(.defaultDigits))
    }

    private func monthDay(_ date: Date) -> String {
        let components = calendar.dateComponents([.month, .day], from: date)
        return "\(components.month ?? 0)/\(components.day ?? 0)"
    }

    private func shortWeekday(_ date: Date) -> String {
        date.formatted(.dateTime.weekday(.narrow))
    }

    private func reloadSnapshot() {
        snapshotLoadGeneration += 1
        let generation = snapshotLoadGeneration
        let shouldDeferInitialLoad = snapshot.days.isEmpty
        let bookInputs = books.map {
            StatisticsBookSnapshotInput(
                id: $0.id,
                title: $0.displayTitle,
                cover: $0.cover,
                folder: $0.folder
            )
        }
        let calendar = calendar
        let windowRange = windowRange
        let today = today
        loadingPlaceholderSnapshot = StatisticsDashboardPlaceholder.snapshot(
            books: books,
            windowRange: windowRange,
            today: today,
            calendar: calendar
        )
        isLoadingSnapshot = true

        func scheduleLoad() {
            let booksDirectory = try? BookStorage.getBooksDirectory()
            DispatchQueue.global(qos: .userInitiated).async {
                let loadedSnapshot: StatisticsDashboardSnapshot
                if let booksDirectory {
                    if let cachedSnapshot = StatisticsDashboardRepository.cachedSnapshot(
                        bookInputs: bookInputs,
                        booksDirectory: booksDirectory
                    ) {
                        DispatchQueue.main.async {
                            guard snapshotLoadGeneration == generation, snapshot.days.isEmpty else { return }
                            applySnapshot(cachedSnapshot)
                        }
                    }

                    loadedSnapshot = StatisticsDashboardRepository.loadSnapshot(
                        bookInputs: bookInputs,
                        booksDirectory: booksDirectory,
                        calendar: calendar
                    )
                    StatisticsDashboardRepository.storeCachedSnapshot(
                        loadedSnapshot,
                        bookInputs: bookInputs,
                        booksDirectory: booksDirectory
                    )
                } else {
                    loadedSnapshot = StatisticsDashboardSnapshot(days: [])
                }

                DispatchQueue.main.async {
                    guard snapshotLoadGeneration == generation else { return }
                    applySnapshot(loadedSnapshot)
                    isLoadingSnapshot = false
                }
            }
        }

        if shouldDeferInitialLoad {
            DispatchQueue.main.asyncAfter(deadline: .now() + statisticsInitialSnapshotLoadDelay) {
                guard snapshotLoadGeneration == generation else { return }
                scheduleLoad()
            }
        } else {
            scheduleLoad()
        }
    }

    private func applySnapshot(_ loadedSnapshot: StatisticsDashboardSnapshot) {
        snapshot = loadedSnapshot
        if selectedAnchor == nil {
            selectedAnchor = snapshot.days.last?.date ?? today
        }
        let latestDate = snapshot.days.last?.date ?? today
        if !hasUserSelectedCalendarDate {
            selectedCalendarDate = latestDate
        } else if let selectedCalendarDate {
            self.selectedCalendarDate = windowRange.coerce(selectedCalendarDate, calendar: calendar)
        }
    }

    private func scrollHeatmap(to date: Date, with proxy: ScrollViewProxy) {
        DispatchQueue.main.async {
            withAnimation(.easeInOut(duration: 0.2)) {
                proxy.scrollTo(calendar.startOfDay(for: date), anchor: .trailing)
            }
        }
    }

}

private struct StatisticsTrendChartView: View {
    let trendPoints: [StatisticsTrendPoint]
    let trendGrain: StatisticsTrendGrain
    let trendMetric: StatisticsTrendMetric
    let chartStyle: StatisticsTrendChartStyle
    let formatTrendValue: (Double) -> String
    let formatCharacters: (Int) -> String
    let formatDuration: (Double) -> String
    let formatOptionalSpeed: (Int?) -> String
    let formatAxisValue: (Double) -> String

    @State private var hoveredTrendPointID: String?
    @State private var hoveredTrendLocation: CGPoint?
    @State private var pendingTrendHoverPointID: String?
    @State private var pendingTrendHoverLocation: CGPoint?
    @State private var trendHoverActivationTask: Task<Void, Never>?
    @State private var lastTrendHoverUpdate = Date.distantPast

    private var chartMaxValue: Double {
        let dataMaxValue = trendPoints.compactMap { $0.value(for: trendMetric) }.max() ?? 0
        return max(dataMaxValue * 1.1, 1)
    }

    private var chartHeight: CGFloat { statisticsTrendChartHeight }

    private var trendBarWidth: CGFloat {
        switch trendGrain {
        case .day:
            12
        case .week:
            22
        case .month:
            28
        }
    }

    private var trendLabelWidth: CGFloat {
        switch trendGrain {
        case .day:
            42
        case .week:
            66
        case .month:
            58
        }
    }

    private var trendSpacing: CGFloat {
        switch trendGrain {
        case .day:
            5
        case .week:
            8
        case .month:
            10
        }
    }

    private var trendEdgeInset: CGFloat {
        max(
            trendLabelWidth / 2 + statisticsTrendChartHorizontalSafeInset,
            trendBarWidth / 2 + statisticsTrendChartHorizontalSafeInset
        )
    }

    var body: some View {
        GeometryReader { proxy in
            let axisWidth: CGFloat = 54
            let chartSpacing: CGFloat = 8
            let availableChartWidth = max(proxy.size.width - axisWidth - chartSpacing, 1)
            let contentWidth = trendContentWidth(availableWidth: availableChartWidth)

            HStack(alignment: .top, spacing: chartSpacing) {
                chartYAxis(maxValue: chartMaxValue, height: chartHeight)
                    .frame(width: axisWidth)

                ScrollView(.horizontal) {
                    VStack(spacing: 6) {
                        ZStack(alignment: .bottomLeading) {
                            chartGridLines(height: chartHeight)
                            switch chartStyle {
                            case .bar:
                                trendBarChart(maxValue: chartMaxValue, chartHeight: chartHeight, contentWidth: contentWidth)
                            case .line:
                                trendLineChart(maxValue: chartMaxValue, chartHeight: chartHeight, contentWidth: contentWidth)
                            }
                            trendChartHoverTrackingLayer(chartHeight: chartHeight, contentWidth: contentWidth)
                            if let hovered = hoveredTrendPoint(in: trendPoints) {
                                trendHoverOverlay(
                                    point: hovered,
                                    maxValue: chartMaxValue,
                                    chartHeight: chartHeight,
                                    contentWidth: contentWidth
                                )
                            }
                        }
                        .frame(width: contentWidth, height: chartHeight, alignment: .bottomLeading)
                        .onHover { hovering in
                            if !hovering {
                                clearTrendHover()
                            }
                        }

                        ZStack(alignment: .topLeading) {
                            ForEach(Array(trendPoints.enumerated()), id: \.element.id) { index, point in
                                if shouldShowTrendLabel(at: index) {
                                    Text(point.label)
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                        .minimumScaleFactor(0.72)
                                        .frame(width: trendLabelWidth)
                                        .position(x: trendXPosition(for: index, contentWidth: contentWidth), y: 8)
                                }
                            }
                        }
                        .frame(width: contentWidth, height: statisticsTrendChartLabelHeight, alignment: .topLeading)
                    }
                    .padding(.bottom, statisticsTrendChartScrollIndicatorSafeInset)
                }
                .scrollIndicators(.automatic)
            }
        }
        .frame(
            minHeight: chartHeight + 6 + statisticsTrendChartLabelHeight + statisticsTrendChartScrollIndicatorSafeInset,
            alignment: .top
        )
    }

    private func trendContentWidth(availableWidth: CGFloat) -> CGFloat {
        let naturalWidth: CGFloat
        if trendPoints.count > 1 {
            naturalWidth = trendEdgeInset * 2 + CGFloat(trendPoints.count - 1) * (trendBarWidth + trendSpacing)
        } else {
            naturalWidth = trendEdgeInset * 2 + trendBarWidth
        }
        return max(naturalWidth, availableWidth, 1)
    }

    private func hoveredTrendPoint(in points: [StatisticsTrendPoint]) -> StatisticsTrendPoint? {
        guard let hoveredTrendPointID else { return nil }
        return points.first { $0.id == hoveredTrendPointID }
    }

    private func trendChartHoverTrackingLayer(chartHeight: CGFloat, contentWidth: CGFloat) -> some View {
        Rectangle()
            .fill(Color.primary.opacity(0.001))
            .frame(width: contentWidth, height: chartHeight)
            .contentShape(Rectangle())
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    updateTrendHover(at: location, contentWidth: contentWidth)
                case .ended:
                    clearTrendHover()
                }
            }
    }

    private func updateTrendHover(at location: CGPoint, contentWidth: CGFloat) {
        guard let point = nearestTrendPoint(to: location.x, contentWidth: contentWidth) else {
            clearTrendHover()
            return
        }

        pendingTrendHoverPointID = point.id
        pendingTrendHoverLocation = location

        guard hoveredTrendPointID != nil else {
            scheduleTrendHoverActivation()
            return
        }

        let now = Date()
        let pointChanged = hoveredTrendPointID != point.id
        let movedFarEnough = hoveredTrendLocation.map { distance(from: $0, to: location) >= statisticsTrendHoverMoveThreshold } ?? true
        let canUpdateAgain = now.timeIntervalSince(lastTrendHoverUpdate) >= statisticsTrendHoverUpdateInterval

        guard pointChanged || movedFarEnough || canUpdateAgain else { return }

        hoveredTrendPointID = point.id
        hoveredTrendLocation = location
        lastTrendHoverUpdate = now
    }

    private func scheduleTrendHoverActivation() {
        guard trendHoverActivationTask == nil else { return }
        trendHoverActivationTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: statisticsTrendHoverDelayNanoseconds)
            guard !Task.isCancelled else { return }
            hoveredTrendPointID = pendingTrendHoverPointID
            hoveredTrendLocation = pendingTrendHoverLocation
            lastTrendHoverUpdate = Date()
            trendHoverActivationTask = nil
        }
    }

    private func clearTrendHover() {
        trendHoverActivationTask?.cancel()
        trendHoverActivationTask = nil
        pendingTrendHoverPointID = nil
        pendingTrendHoverLocation = nil
        hoveredTrendPointID = nil
        hoveredTrendLocation = nil
    }

    private func distance(from lhs: CGPoint, to rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }

    private func trendHoverOverlay(
        point: StatisticsTrendPoint,
        maxValue: Double,
        chartHeight: CGFloat,
        contentWidth: CGFloat
    ) -> some View {
        let index = trendPoints.firstIndex { $0.id == point.id } ?? 0
        let value = point.value(for: trendMetric)
        let x = trendXPosition(for: index, contentWidth: contentWidth)
        let markerY = trendYPosition(value: value, maxValue: maxValue, chartHeight: chartHeight)
        let cursor = hoveredTrendLocation ?? CGPoint(x: x, y: markerY)
        let tooltipPosition = trendTooltipPosition(
            near: cursor,
            contentWidth: contentWidth,
            chartHeight: chartHeight
        )

        return ZStack(alignment: .topLeading) {
            Path { path in
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: chartHeight))
            }
            .stroke(Color.accentColor.opacity(0.28), style: StrokeStyle(lineWidth: 1, dash: [4, 4]))

            Circle()
                .fill(Color.accentColor)
                .frame(width: 7, height: 7)
                .position(x: x, y: markerY)

            trendTooltipCard(point: point, value: value)
                .position(tooltipPosition)
        }
        .frame(width: contentWidth, height: chartHeight, alignment: .topLeading)
        .allowsHitTesting(false)
        .transition(.opacity)
    }

    private func nearestTrendPoint(to x: CGFloat, contentWidth: CGFloat) -> StatisticsTrendPoint? {
        guard !trendPoints.isEmpty else { return nil }
        guard trendPoints.count > 1 else { return trendPoints.first }
        let usableWidth = max(contentWidth - trendEdgeInset * 2, 1)
        let step = usableWidth / CGFloat(trendPoints.count - 1)
        let rawIndex = (x - trendEdgeInset) / step
        let index = min(max(Int(rawIndex.rounded()), 0), trendPoints.count - 1)
        return trendPoints[index]
    }

    private func trendTooltipPosition(
        near cursor: CGPoint,
        contentWidth: CGFloat,
        chartHeight: CGFloat
    ) -> CGPoint {
        let halfWidth = statisticsTrendTooltipWidth / 2
        let halfHeight = statisticsTrendTooltipEstimatedHeight / 2
        let preferredRight = cursor.x + statisticsTrendTooltipGap + halfWidth
        let preferredLeft = cursor.x - statisticsTrendTooltipGap - halfWidth
        let canFitRight = preferredRight + halfWidth <= contentWidth
        let rawX = canFitRight ? preferredRight : preferredLeft
        let clampedX = min(max(rawX, halfWidth), max(halfWidth, contentWidth - halfWidth))

        let preferredTop = cursor.y - statisticsTrendTooltipGap - halfHeight
        let preferredBottom = cursor.y + statisticsTrendTooltipGap + halfHeight
        let canFitTop = preferredTop - halfHeight >= 0
        let rawY = canFitTop ? preferredTop : preferredBottom
        let clampedY = min(max(rawY, halfHeight), max(halfHeight, chartHeight - halfHeight))
        return CGPoint(x: clampedX, y: clampedY)
    }

    private func trendTooltipCard(point: StatisticsTrendPoint, value: Double?) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(point.id)
                .font(.caption.weight(.bold).monospacedDigit())
                .lineLimit(1)

            trendTooltipRow("Metric", value.map(formatTrendValue) ?? "-")
            trendTooltipRow("Characters", formatCharacters(point.characters))
            trendTooltipRow("Duration", formatDuration(point.readingTime))
            trendTooltipRow("Speed", formatOptionalSpeed(point.averageSpeedPerHour))

            if !point.bookBreakdown.isEmpty {
                Divider().opacity(0.5)
                Text("Books")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(point.bookBreakdown.prefix(3)) { book in
                    trendTooltipBookRow(book)
                }
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(width: 224, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 12))
    }

    private func trendTooltipRow(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text(value)
                .font(.caption.weight(.bold).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.75)
        }
    }

    private func trendTooltipBookRow(_ book: StatisticsTrendBookBreakdown) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(book.title)
                .font(.caption2.weight(.semibold))
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(formatCharacters(book.characters))
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
    }

    @ViewBuilder
    private func trendChartHotspot(
        point: StatisticsTrendPoint,
        value: Double?,
        x: CGFloat,
        y: CGFloat,
        width: CGFloat,
        height: CGFloat,
        shape: StatisticsTrendHotspotShape,
        isActive: Bool
    ) -> some View {
        let activeFill = Color.accentColor.opacity(0.10)
        let inactiveFill = Color.primary.opacity(0.001)
        switch shape {
        case .rectangle:
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(isActive ? activeFill : inactiveFill)
                .frame(width: width, height: height)
                .contentShape(Rectangle())
                .position(x: x, y: y)
                .accessibilityLabel(Text(trendPointAccessibilityText(point, value: value)))
        case .circle:
            Circle()
                .fill(isActive ? activeFill : inactiveFill)
                .frame(width: width, height: height)
                .contentShape(Circle())
                .position(x: x, y: y)
                .accessibilityLabel(Text(trendPointAccessibilityText(point, value: value)))
        }
    }

    private func trendBarChart(maxValue: Double, chartHeight: CGFloat, contentWidth: CGFloat) -> some View {
        ZStack(alignment: .bottomLeading) {
            ForEach(Array(trendPoints.enumerated()), id: \.element.id) { index, point in
                trendBarColumn(index: index, point: point, maxValue: maxValue, chartHeight: chartHeight, contentWidth: contentWidth)
            }
        }
        .frame(width: contentWidth, height: chartHeight, alignment: .bottomLeading)
    }

    @ViewBuilder
    private func trendBarColumn(
        index: Int,
        point: StatisticsTrendPoint,
        maxValue: Double,
        chartHeight: CGFloat,
        contentWidth: CGFloat
    ) -> some View {
        let value = point.value(for: trendMetric)
        let x = trendXPosition(for: index, contentWidth: contentWidth)
        let isHovered = hoveredTrendPointID == point.id

        trendChartHotspot(
            point: point,
            value: value,
            x: x,
            y: chartHeight / 2,
            width: max(trendBarWidth + 12, 22),
            height: chartHeight,
            shape: .rectangle,
            isActive: isHovered
        )

        if let value {
            let barHeight = max(CGFloat(value / maxValue) * chartHeight, value > 0 ? 8 : 2)
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(Color.accentColor.opacity(isHovered ? 1 : 0.86))
                .frame(width: trendBarWidth, height: barHeight)
                .position(x: x, y: chartHeight - barHeight / 2)
                .help(trendPointHelp(point, value: value))
        } else {
            Text("-")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: trendBarWidth, height: 14)
                .position(x: x, y: chartHeight - 7)
                .help(trendPointHelp(point, value: nil))
        }
    }

    private func trendLineChart(maxValue: Double, chartHeight: CGFloat, contentWidth: CGFloat) -> some View {
        let segments = trendLineSegments(maxValue: maxValue, chartHeight: chartHeight, contentWidth: contentWidth)
        let points = segments.flatMap { $0 }
        return ZStack(alignment: .topLeading) {
            ForEach(segments.indices, id: \.self) { index in
                Path { path in
                    for (pointIndex, point) in segments[index].enumerated() {
                        if pointIndex == 0 {
                            path.move(to: point.location)
                        } else {
                            path.addLine(to: point.location)
                        }
                    }
                }
                .stroke(Color.accentColor, style: StrokeStyle(lineWidth: 2.5, lineCap: .round, lineJoin: .round))
            }

            ForEach(points) { point in
                trendChartHotspot(
                    point: point.trendPoint,
                    value: point.value,
                    x: point.location.x,
                    y: chartHeight / 2,
                    width: max(trendBarWidth + 12, 22),
                    height: chartHeight,
                    shape: .rectangle,
                    isActive: hoveredTrendPointID == point.trendPoint.id
                )

                Circle()
                    .fill(Color.accentColor)
                    .frame(width: hoveredTrendPointID == point.trendPoint.id ? 9 : 7, height: hoveredTrendPointID == point.trendPoint.id ? 9 : 7)
                    .position(point.location)
                    .help(trendPointHelp(point.trendPoint, value: point.value))
            }
        }
        .frame(width: contentWidth, height: chartHeight, alignment: .topLeading)
    }

    private func trendLineSegments(maxValue: Double, chartHeight: CGFloat, contentWidth: CGFloat) -> [[StatisticsTrendLinePoint]] {
        var segments: [[StatisticsTrendLinePoint]] = []
        var current: [StatisticsTrendLinePoint] = []
        for (index, point) in trendPoints.enumerated() {
            guard let linePoint = trendLinePoint(
                for: index,
                point: point,
                maxValue: maxValue,
                chartHeight: chartHeight,
                contentWidth: contentWidth
            ) else {
                if trendMetric != .speed, !current.isEmpty {
                    segments.append(current)
                    current = []
                }
                continue
            }
            current.append(linePoint)
        }
        if !current.isEmpty {
            segments.append(current)
        }
        return segments
    }

    private func trendLinePoint(
        for index: Int,
        point: StatisticsTrendPoint,
        maxValue: Double,
        chartHeight: CGFloat,
        contentWidth: CGFloat
    ) -> StatisticsTrendLinePoint? {
        guard let value = point.value(for: trendMetric) else { return nil }
        let x = trendXPosition(for: index, contentWidth: contentWidth)
        let y = trendYPosition(value: value, maxValue: maxValue, chartHeight: chartHeight)
        return StatisticsTrendLinePoint(
            trendPoint: point,
            value: value,
            location: CGPoint(x: x, y: min(max(y, 3.5), chartHeight - 3.5))
        )
    }

    private func trendXPosition(for index: Int, contentWidth: CGFloat) -> CGFloat {
        guard trendPoints.count > 1 else { return contentWidth / 2 }
        let usableWidth = max(contentWidth - trendEdgeInset * 2, 1)
        return trendEdgeInset + CGFloat(index) * (usableWidth / CGFloat(trendPoints.count - 1))
    }

    private func trendYPosition(value: Double?, maxValue: Double, chartHeight: CGFloat) -> CGFloat {
        guard let value else { return chartHeight - 7 }
        return chartHeight - CGFloat(value / maxValue) * chartHeight
    }

    private func trendPointHelp(_ point: StatisticsTrendPoint, value: Double?) -> String {
        "\(point.id): \(value.map(formatTrendValue) ?? "-") · \(formatCharacters(point.characters)), \(formatDuration(point.readingTime))"
    }

    private func trendPointAccessibilityText(_ point: StatisticsTrendPoint, value: Double?) -> String {
        [
            point.id,
            String(format: String(localized: "Metric: %@"), value.map(formatTrendValue) ?? "-"),
            String(format: String(localized: "Characters: %@"), formatCharacters(point.characters)),
            String(format: String(localized: "Duration: %@"), formatDuration(point.readingTime)),
            String(format: String(localized: "Speed: %@"), formatOptionalSpeed(point.averageSpeedPerHour))
        ].joined(separator: ", ")
    }

    private func shouldShowTrendLabel(at index: Int) -> Bool {
        guard trendPoints.count > 14 else { return true }
        let stride = max(Int(ceil(Double(trendPoints.count) / 12.0)), 1)
        return index.isMultiple(of: stride) || index == trendPoints.count - 1
    }

    private func chartYAxis(maxValue: Double, height: CGFloat) -> some View {
        VStack(alignment: .trailing) {
            Text(formatAxisValue(maxValue))
            Spacer()
            Text(formatAxisValue(maxValue / 2))
            Spacer()
            Text("0")
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(width: 54, height: height, alignment: .trailing)
    }

    private func chartGridLines(height: CGFloat) -> some View {
        VStack {
            ForEach(0..<3, id: \.self) { index in
                Rectangle()
                    .fill(Color.secondary.opacity(index == 2 ? 0.22 : 0.12))
                    .frame(height: 1)
                if index != 2 {
                    Spacer()
                }
            }
        }
        .frame(height: height)
    }
}

private enum StatisticsDashboardPlaceholder {
    private static let activityOffsets = [330, 304, 278, 251, 226, 203, 181, 158, 137, 116, 96, 77, 59, 42, 28, 17, 9, 4, 1, 0]
    private static let fallbackBookIDs: [UUID] = (1...statisticsBookRankingLimit).compactMap {
        UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", $0))
    }

    static func snapshot(
        books: [BookMetadata],
        windowRange: StatisticsDateRange,
        today: Date,
        calendar: Calendar
    ) -> StatisticsDashboardSnapshot {
        let records = placeholderRecords(from: books)
        let activeRecords = Array(records.prefix(min(records.count, 6)))
        let days = activityOffsets.enumerated().compactMap { index, offset -> StatisticsDayAggregate? in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today)
                    .map(calendar.startOfDay(for:)),
                  windowRange.contains(date, calendar: calendar),
                  !activeRecords.isEmpty else {
                return nil
            }

            let totalCharacters = 2_400 + ((index * 3_371) % 18_000)
            let speed = 7_200 + (index % 5) * 1_150
            let readingTime = Double(totalCharacters) / Double(speed) * 3_600
            let primary = activeRecords[index % activeRecords.count]
            let secondary = activeRecords[(index + 1) % activeRecords.count]
            let primaryCharacters = activeRecords.count > 1 && !index.isMultiple(of: 4)
                ? Int(Double(totalCharacters) * 0.66)
                : totalCharacters
            let primaryTime = readingTime * (Double(primaryCharacters) / Double(totalCharacters))
            var contributions = [
                contribution(
                    record: primary,
                    characters: primaryCharacters,
                    readingTime: primaryTime
                )
            ]

            if secondary.id != primary.id, primaryCharacters < totalCharacters {
                contributions.append(
                    contribution(
                        record: secondary,
                        characters: totalCharacters - primaryCharacters,
                        readingTime: readingTime - primaryTime
                    )
                )
            }

            return StatisticsDayAggregate(
                date: date,
                characters: contributions.reduce(0) { $0 + $1.characters },
                readingTime: contributions.reduce(0) { $0 + $1.readingTime },
                bookContributions: contributions
            )
        }
        .sorted { $0.date < $1.date }

        return StatisticsDashboardSnapshot(days: days, books: records)
    }

    private static func placeholderRecords(from books: [BookMetadata]) -> [StatisticsBookRecord] {
        var usedIDs = Set<UUID>()
        var records = books.prefix(statisticsBookRankingLimit).enumerated().map { index, book in
            usedIDs.insert(book.id)
            return StatisticsBookRecord(
                id: book.id,
                title: book.displayTitle,
                coverPath: nil,
                totalCharacters: 80_000 + index * 23_000
            )
        }

        for (index, id) in fallbackBookIDs.enumerated() where records.count < statisticsBookRankingLimit && !usedIDs.contains(id) {
            records.append(
                StatisticsBookRecord(
                    id: id,
                    title: String(localized: "Loading Statistics"),
                    coverPath: nil,
                    totalCharacters: 70_000 + index * 19_000
                )
            )
        }

        return records
    }

    private static func contribution(
        record: StatisticsBookRecord,
        characters: Int,
        readingTime: Double
    ) -> StatisticsBookContribution {
        StatisticsBookContribution(
            bookID: record.id,
            title: record.title,
            coverPath: record.coverPath,
            characters: characters,
            readingTime: readingTime
        )
    }
}

private struct StatisticsBookDetailPanel: View {
    let book: BookMetadata
    let onStatisticsChanged: () -> Void

    @Environment(ReaderWindowCoordinator.self) private var readerWindowCoordinator
    @Environment(UserConfig.self) private var userConfig
    @Environment(\.dismiss) private var dismiss
    @State private var records: ReadingSessionRecords = [:]
    @State private var selectedDateKey: String?
    @State private var selectedSessionID: String?
    @State private var draftCharacters = 0
    @State private var draftHours = 0
    @State private var draftMinutes = 0
    @State private var showingDeleteSessionConfirmation = false
    @State private var showingDeleteDayConfirmation = false
    @State private var showingDeleteAllConfirmation = false
    @State private var saveError: String?

    private var resetMinutes: Int {
        StatisticsDayBoundary.normalizedResetMinutes(userConfig.statisticsResetTime)
    }

    private var days: [ReadingSessionDay] {
        ReadingSessionLog.days(records, resetMinutes: resetMinutes)
            .filter { $0.total.hasActivity }
    }

    private var selectedDay: ReadingSessionDay? {
        guard let selectedDateKey else { return nil }
        return days.first { $0.dateKey == selectedDateKey }
    }

    private var selectedSession: ReadingSessionEntry? {
        guard let selectedSessionID else { return nil }
        return selectedDay?.sessions.first { $0.id == selectedSessionID }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(22)

            Divider()

            HStack(alignment: .top, spacing: 18) {
                daysList
                    .frame(width: 300)

                sessionsPane
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
            .padding(22)
        }
        .background { NativeGlassPageBackground() }
        .onAppear(perform: prepareAndLoad)
        .confirmationDialog(
            "Delete This Session",
            isPresented: $showingDeleteSessionConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: deleteSelectedSession)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete the selected reading session? This cannot be undone.")
        }
        .confirmationDialog(
            "Delete This Day",
            isPresented: $showingDeleteDayConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive, action: deleteSelectedDay)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete the selected day's statistics? This cannot be undone.")
        }
        .confirmationDialog(
            "Delete All Statistics",
            isPresented: $showingDeleteAllConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete All Statistics", role: .destructive, action: deleteAllStatistics)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Delete all statistics for this book? This cannot be undone.")
        }
        .alert("Unable to Save Statistics", isPresented: saveErrorIsPresented) {
            Button("OK") {}
        } message: {
            Text(saveError ?? "")
        }
    }

    private var header: some View {
        HStack(spacing: 16) {
            BookCover(book: book, width: 72)

            VStack(alignment: .leading, spacing: 5) {
                Text(book.displayTitle)
                    .font(.title2.weight(.bold))
                    .lineLimit(2)
                Text("Statistics")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            NativeGlassCircleButton(systemName: "xmark", diameter: 36, fontSize: 14) {
                dismiss()
            }
            .help("Close")
        }
    }

    private var daysList: some View {
        NativeSettingsSectionCard("Days") {
            if days.isEmpty {
                ContentUnavailableView("No reading records", systemImage: "calendar.badge.clock")
                    .frame(maxWidth: .infinity, minHeight: 230)
                    .padding(.horizontal, 12)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(days) { day in
                            Button {
                                select(day)
                            } label: {
                                dayRow(day)
                            }
                            .buttonStyle(.plain)

                            if day.dateKey != days.last?.dateKey {
                                Divider()
                                    .padding(.horizontal, 14)
                            }
                        }
                    }
                }
                .frame(minHeight: 300)
            }
        }
    }

    @ViewBuilder
    private var sessionsPane: some View {
        if let day = selectedDay {
            VStack(alignment: .leading, spacing: 18) {
                NativeSettingsSectionCard {
                    Text(formattedDateKey(day.dateKey))
                } content: {
                    ScrollView {
                        LazyVStack(spacing: 0) {
                            ForEach(day.sessions) { entry in
                                Button {
                                    select(entry)
                                } label: {
                                    sessionRow(entry)
                                }
                                .buttonStyle(.plain)

                                if entry.id != day.sessions.last?.id {
                                    Divider().padding(.horizontal, 14)
                                }
                            }
                        }
                    }
                    .frame(maxHeight: 220)
                }

                if let session = selectedSession {
                    sessionEditor(session)
                }

                Spacer(minLength: 0)

                HStack {
                    Button("Delete This Day", role: .destructive) {
                        showingDeleteDayConfirmation = true
                    }
                    .buttonStyle(.glass)

                    Spacer()

                    Button("Delete All Statistics", role: .destructive) {
                        showingDeleteAllConfirmation = true
                    }
                    .buttonStyle(.glass)
                }
            }
        } else {
            VStack(spacing: 14) {
                ContentUnavailableView {
                    Label("Statistics", systemImage: "calendar")
                } description: {
                    Text("Select a day to edit its reading sessions.")
                }

                if !days.isEmpty {
                    Button("Delete All Statistics", role: .destructive) {
                        showingDeleteAllConfirmation = true
                    }
                    .buttonStyle(.glass)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .nativeGlassCardSurface(cornerRadius: 18)
        }
    }

    private func sessionEditor(_ entry: ReadingSessionEntry) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            NativeSettingsSectionCard {
                Text(sessionTimeRange(entry.session))
            } content: {
                NativeSettingsRow {
                    Text("Characters Read:")
                } accessory: {
                    TextField("0", value: $draftCharacters, format: .number)
                        .multilineTextAlignment(.trailing)
                        .nativeSettingsTextField()
                        .frame(width: 170)
                }

                Divider().padding(.leading, 16)

                NativeSettingsRow {
                    Text("Reading Time:")
                } accessory: {
                    HStack(spacing: 8) {
                        TextField("0", value: $draftHours, format: .number)
                            .multilineTextAlignment(.trailing)
                            .nativeSettingsTextField()
                            .frame(width: 72)
                        Text("Hours")
                            .foregroundStyle(.secondary)
                        TextField("0", value: $draftMinutes, format: .number)
                            .multilineTextAlignment(.trailing)
                            .nativeSettingsTextField()
                            .frame(width: 72)
                        Text("Minutes")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            HStack {
                Button("Delete Session", role: .destructive) {
                    showingDeleteSessionConfirmation = true
                }
                .buttonStyle(.glass)

                Spacer()

                Button("Save", systemImage: "checkmark", action: saveSelectedSession)
                    .buttonStyle(.glassProminent)
            }
        }
    }

    private func dayRow(_ day: ReadingSessionDay) -> some View {
        let isSelected = selectedDateKey == day.dateKey
        let total = day.total
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(formattedDateKey(day.dateKey))
                    .font(.body.weight(.semibold))
                Text(total.charactersRead.formatted(.number.grouping(.automatic)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 4) {
                Text(formatDuration(total.readingTime))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text("\(day.sessions.count) sessions")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }

            Image(systemName: "chevron.right")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            isSelected ? Color.accentColor.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 11, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    private func sessionRow(_ entry: ReadingSessionEntry) -> some View {
        let isSelected = selectedSessionID == entry.id
        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(sessionTimeRange(entry.session))
                    .font(.body.monospacedDigit())
                Text(entry.session.charactersRead.formatted(.number.grouping(.automatic)))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                Text(formatDuration(entry.session.readingTime))
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(verbatim: "\(entry.session.readingSpeed.formatted(.number.grouping(.automatic))) / h")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(
            isSelected ? Color.accentColor.opacity(0.13) : Color.clear,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .contentShape(Rectangle())
    }

    private var saveErrorIsPresented: Binding<Bool> {
        Binding(
            get: { saveError != nil },
            set: { if !$0 { saveError = nil } }
        )
    }

    private func prepareAndLoad() {
        activeReaderModel?.prepareForExternalStatisticsMutation()
        loadRecords(preferredDateKey: nil, preferredSessionID: nil)
    }

    private func loadRecords(preferredDateKey: String?, preferredSessionID: String?) {
        do {
            records = StatisticsStorage.load(root: try bookRoot(), resetMinutes: resetMinutes)
            let days = days
            let day = preferredDateKey.flatMap { key in days.first { $0.dateKey == key } } ?? days.last
            if let day {
                select(day, preferredSessionID: preferredSessionID)
            } else {
                selectedDateKey = nil
                selectedSessionID = nil
            }
        } catch {
            saveError = error.localizedDescription
        }
    }

    private func select(_ day: ReadingSessionDay, preferredSessionID: String? = nil) {
        selectedDateKey = day.dateKey
        let session = preferredSessionID.flatMap { id in day.sessions.first { $0.id == id } }
            ?? (day.sessions.count == 1 ? day.sessions.first : nil)
        if let session {
            select(session)
        } else {
            selectedSessionID = nil
        }
    }

    private func select(_ entry: ReadingSessionEntry) {
        selectedSessionID = entry.id
        draftCharacters = entry.session.charactersRead
        let totalMinutes = max(Int((entry.session.readingTime / 60).rounded()), 0)
        draftHours = totalMinutes / 60
        draftMinutes = totalMinutes % 60
    }

    private func saveSelectedSession() {
        guard let entry = selectedSession else { return }
        let totalMinutes = max(draftHours, 0) * 60 + min(max(draftMinutes, 0), 59)
        // Keep second-level precision when only the character count changed.
        let readingTime = totalMinutes == Int((entry.session.readingTime / 60).rounded())
            ? entry.session.readingTime
            : Double(totalMinutes * 60)
        let characters = max(draftCharacters, 0)
        mutate(preferredDateKey: selectedDateKey, preferredSessionID: entry.id) { current in
            ReadingSessionLog.editing(
                id: entry.id,
                charactersRead: characters,
                readingTime: readingTime,
                in: current
            )
        }
    }

    private func deleteSelectedSession() {
        guard let id = selectedSessionID else { return }
        mutate(preferredDateKey: selectedDateKey, preferredSessionID: nil) { current in
            ReadingSessionLog.deleting(ids: [id], from: current)
        }
    }

    private func deleteSelectedDay() {
        guard let day = selectedDay else { return }
        mutate(preferredDateKey: nil, preferredSessionID: nil) { current in
            ReadingSessionLog.deleting(ids: day.sessions.map(\.id), from: current)
        }
    }

    private func deleteAllStatistics() {
        mutate(preferredDateKey: nil, preferredSessionID: nil) { current in
            ReadingSessionLog.deleting(ids: ReadingSessionLog.entries(current).map(\.id), from: current)
        }
    }

    private func mutate(
        preferredDateKey: String?,
        preferredSessionID: String?,
        transform: (ReadingSessionRecords) -> ReadingSessionRecords
    ) {
        let model = activeReaderModel
        model?.prepareForExternalStatisticsMutation()

        do {
            let root = try bookRoot()
            let current = StatisticsStorage.load(root: root, resetMinutes: resetMinutes)
            let updated = transform(current)
            if updated != current {
                try StatisticsStorage.save(updated, root: root, resetMinutes: resetMinutes)
            }
            model?.reloadStatisticsAfterExternalMutation()
            loadRecords(preferredDateKey: preferredDateKey, preferredSessionID: preferredSessionID)
            onStatisticsChanged()
        } catch {
            model?.reloadStatisticsAfterExternalMutation()
            saveError = error.localizedDescription
        }
    }

    private var activeReaderModel: NativeReaderModel? {
        guard readerWindowCoordinator.currentBook?.id == book.id else { return nil }
        return readerWindowCoordinator.currentModel
    }

    private func bookRoot() throws -> URL {
        try BookStorage.getBooksDirectory().appendingPathComponent(book.folder)
    }

    private func sessionTimeRange(_ session: ReadingSession) -> String {
        let start = session.startDate.formatted(date: .omitted, time: .shortened)
        let end = StatisticsClock.date(max(session.endedAt, session.startedAt)).formatted(date: .omitted, time: .shortened)
        return "\(start) – \(end)"
    }

    private func formattedDateKey(_ dateKey: String) -> String {
        let parser = DateFormatter()
        parser.calendar = Calendar(identifier: .gregorian)
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: dateKey) else { return dateKey }
        return date.formatted(.dateTime.year().month().day())
    }

    private func formatDuration(_ seconds: Double) -> String {
        let totalMinutes = max(Int((seconds / 60).rounded()), 0)
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours == 0 {
            return String(format: String(localized: "%d minutes"), minutes)
        }
        return String(format: String(localized: "%d hours %d minutes"), hours, minutes)
    }
}

private struct StatisticsDashboardCard<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        content()
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .nativeGlassCardSurface(cornerRadius: 18)
    }
}

private struct StatisticsTrendLinePoint: Identifiable {
    let trendPoint: StatisticsTrendPoint
    let value: Double
    let location: CGPoint

    var id: String { trendPoint.id }
}

private struct NativeSettingsStepperRow: View {
    let title: LocalizedStringKey
    let value: String
    let range: ClosedRange<Int>
    let step: Int
    @Binding var selection: Int

    var body: some View {
        NativeSettingsRow(title) {
            Text(verbatim: value)
                .fontWeight(.semibold)
                .monospacedDigit()
            Stepper(value: clampedSelection, in: range, step: step) {
                Text(title)
            }
            .labelsHidden()
            .fixedSize()
        }
    }

    private var clampedSelection: Binding<Int> {
        Binding {
            min(max(selection, range.lowerBound), range.upperBound)
        } set: { newValue in
            selection = min(max(newValue, range.lowerBound), range.upperBound)
        }
    }
}
