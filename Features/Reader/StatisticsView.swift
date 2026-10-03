//
//  StatisticsView.swift
//  Niratan
//
//  Copyright © 2026 Manhhao.
//  SPDX-License-Identifier: GPL-3.0-or-later
//

import SwiftUI
import EPUBKit


struct ReaderStatisticsContentView: View {
    let sessionStatistics: ReadingTotal
    let todaysStatistics: ReadingTotal
    let allTimeStatistics: ReadingTotal
    let bookCharacterCount: Int
    let currentCharacter: Int
    let chapterCharactersRemaining: Int
    let contentLanguage: ContentLanguageProfile
    let isTracking: Bool
    let onStart: () -> Void
    let onStop: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            NativeReaderInspectorHeader(title: "Statistics", onClose: onClose) {
                NativeGlassCircleButton(
                    systemName: isTracking ? "pause.fill" : "play.fill",
                    diameter: 28,
                    fontSize: 11
                ) {
                    isTracking ? onStop() : onStart()
                }
                .help(isTracking ? Text("Pause Tracking") : Text("Start Tracking"))
                .accessibilityLabel(isTracking ? Text("Pause Tracking") : Text("Start Tracking"))
            }

            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 20) {
                    sessionHero
                    bookProgress
                    historyTable
                }
                .padding(.horizontal, 18)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.automatic)
        }
    }

    private var sessionHero: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Circle()
                    .fill(isTracking ? Color.green : Color.secondary)
                    .frame(width: 7, height: 7)
                Text(isTracking ? "Tracking" : "Paused")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(isTracking ? Color.primary : Color.secondary)
                Spacer(minLength: 0)
                Text("Session")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 0) {
                Text(count(sessionStatistics.charactersRead))
                    .font(.system(size: 40, weight: .bold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                    .contentTransition(.numericText())
                Text(countLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 0) {
                heroMetric(value: speed(sessionStatistics), label: "Reading Speed")
                Divider().frame(height: 28)
                heroMetric(value: duration(sessionStatistics.readingTime), label: "Reading Time")
                    .padding(.leading, 14)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.accentColor.opacity(isTracking ? 0.12 : 0.06))
        }
    }

    private func heroMetric(value: String, label: LocalizedStringKey) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(value)
                .font(.headline.monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(label)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var bookProgress: some View {
        let fraction = bookCharacterCount > 0
            ? min(max(Double(currentCharacter) / Double(bookCharacterCount), 0), 1)
            : 0
        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                NativeReaderInspectorSectionTitle("Book Progress")
                Text(fraction.formatted(.percent.precision(.fractionLength(1))))
                    .font(.caption.weight(.semibold).monospacedDigit())
            }
            ProgressView(value: fraction)
                .controlSize(.small)
            remainingRow(icon: "book", label: "Time to finish Book", seconds: timeToFinishBook)
            remainingRow(icon: "bookmark", label: "Time to finish Chapter", seconds: timeToFinishChapter)
        }
    }

    private func remainingRow(icon: String, label: LocalizedStringKey, seconds: Double) -> some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            Text(label)
                .font(.callout)
            Spacer(minLength: 8)
            Text(seconds > 0 ? duration(seconds) : "—")
                .font(.callout.monospacedDigit())
                .foregroundStyle(seconds > 0 ? .primary : .secondary)
        }
    }

    private var historyTable: some View {
        VStack(alignment: .leading, spacing: 6) {
            NativeReaderInspectorSectionTitle("History")
            Grid(alignment: .trailing, horizontalSpacing: 12, verticalSpacing: 8) {
                GridRow {
                    Text(verbatim: "")
                        .gridColumnAlignment(.leading)
                    Text(countLabel)
                    Text("Reading Speed")
                    Text("Reading Time")
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                Divider().gridCellUnsizedAxes(.horizontal)
                historyRow("Today", statistics: todaysStatistics)
                historyRow("All Time", statistics: allTimeStatistics)
            }
        }
    }

    private func historyRow(_ title: LocalizedStringKey, statistics: ReadingTotal) -> some View {
        GridRow {
            Text(title)
                .font(.callout.weight(.medium))
                .gridColumnAlignment(.leading)
            Text(count(statistics.charactersRead))
            Text(speed(statistics))
            Text(duration(statistics.readingTime))
        }
        .font(.callout.monospacedDigit())
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }

    private func count(_ rawCharacters: Int) -> String {
        contentLanguage.displayCount(forRawCharacters: rawCharacters).formatted(.number)
    }

    private func speed(_ statistics: ReadingTotal) -> String {
        "\(contentLanguage.displayCount(forRawCharacters: statistics.readingSpeed).formatted(.number))/h"
    }

    private func duration(_ seconds: Double) -> String {
        Duration.seconds(seconds).formatted(.time(pattern: .hourMinuteSecond))
    }

    private var countLabel: LocalizedStringKey {
        contentLanguage == .english ? "Approximate Words Read" : "Characters Read"
    }

    private var timeToFinishBook: Double {
        guard sessionStatistics.readingSpeed > 0 else { return 0 }
        return Double(max(bookCharacterCount - currentCharacter, 0)) / (Double(sessionStatistics.readingSpeed) / 3600.0)
    }

    private var timeToFinishChapter: Double {
        guard sessionStatistics.readingSpeed > 0 else { return 0 }
        return Double(max(chapterCharactersRemaining, 0)) / (Double(sessionStatistics.readingSpeed) / 3600.0)
    }
}
