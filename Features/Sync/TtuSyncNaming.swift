import Foundation

/// File and folder naming shared with ッツ Ebook Reader's Google Drive sync.
/// These must match the web reader byte for byte, or synced data stops matching.
nonisolated enum TtuSyncNaming {
    static func statisticsFileName(stats: [Statistics]) -> String {
        var readingTime: Double = 0
        var charactersRead: Int = 0
        var minReadingSpeed: Int = 0
        var altMinReadingSpeed: Int = 0
        var maxReadingSpeed: Int = 0
        var weightedSum: Int = 0
        var validReadingDays: Int = 0
        var lastStatisticModified: Int = 0

        for stat in stats {
            readingTime += stat.readingTime
            charactersRead += stat.charactersRead
            minReadingSpeed = minReadingSpeed > 0 ? min(minReadingSpeed, stat.minReadingSpeed) : stat.minReadingSpeed
            altMinReadingSpeed = altMinReadingSpeed > 0 ? min(altMinReadingSpeed, stat.altMinReadingSpeed) : stat.altMinReadingSpeed
            maxReadingSpeed = max(maxReadingSpeed, stat.lastReadingSpeed)
            weightedSum += Int(stat.readingTime) * stat.charactersRead
            lastStatisticModified = max(lastStatisticModified, stat.lastStatisticModified)
            if stat.readingTime > 0 {
                validReadingDays += 1
            }
        }

        let averageReadingTime = validReadingDays > 0 ? ceil(readingTime / Double(validReadingDays)) : 0
        let averageWeightedReadingTime = charactersRead > 0 ? ceil(Double(weightedSum) / Double(charactersRead)) : 0
        let averageCharactersRead = validReadingDays > 0 ? ceil(Double(charactersRead) / Double(validReadingDays)) : 0
        let averageWeightedCharactersRead = readingTime > 0 ? ceil(Double(weightedSum) / Double(readingTime)) : 0
        let lastReadingSpeed = readingTime > 0 ? ceil((3600.0 * Double(charactersRead)) / readingTime) : 0
        let averageReadingSpeed = averageReadingTime > 0 ? ceil((3600 * averageCharactersRead) / averageReadingTime) : 0
        let averageWeightedReadingSpeed = averageWeightedReadingTime > 0 ? ceil((3600 * averageWeightedCharactersRead) / averageWeightedReadingTime) : 0
        return "statistics_1_6_\(lastStatisticModified)_\(charactersRead)_\(readingTime)_\(minReadingSpeed)_\(altMinReadingSpeed)_\(lastReadingSpeed)_\(maxReadingSpeed)_\(averageReadingTime)_\(averageWeightedReadingTime)_\(averageCharactersRead)_\(averageWeightedCharactersRead)_\(averageReadingSpeed)_\(averageWeightedReadingSpeed)_na.json"
    }

    // https://github.com/ttu-ttu/ebook-reader/blob/d7d1dc1fd1151e067db218b8ff7eecf1c14d2276/apps/web/src/lib/data/storage/handler/base-handler.ts#L642
    static func sanitize(_ title: String) -> String {
        var result = title
        if result.hasSuffix(" ") {
            result = String(result.dropLast())
            result += "~ttu-spc~"
        }
        if result.hasSuffix(".") {
            result = String(result.dropLast())
            result += "~ttu-dend~"
        }
        result = result.replacingOccurrences(of: "*", with: "~ttu-star~")
        result = result.replacing(/[\/?\<>\\:*|%"]/) { match in
            match.output.unicodeScalars.map { scalar in
                let value = scalar.value
                return String(format: "%%%02X", value)
            }.joined()
        }

        return result
    }

    static func desanitize(_ title: String) -> String {
        (title.removingPercentEncoding ?? title)
            .replacingOccurrences(of: "~ttu-star~", with: "*")
            .replacingOccurrences(of: "~ttu-dend~", with: ".")
            .replacingOccurrences(of: "~ttu-spc~", with: " ")
    }
}
