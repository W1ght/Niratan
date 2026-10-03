// test-skip: manual screenshot comparison tool (needs before/after PNG arguments)
import AppKit
import Foundation

struct VisualScore {
    let region: CGRect
    let density: Double
    let sampledPixels: Int
}

extension VisualScore: Comparable {
    static func < (lhs: VisualScore, rhs: VisualScore) -> Bool {
        lhs.density < rhs.density
    }
}

let minimumImprovement = 0.08
let minimumAbsoluteGain = 0.006

func loadBitmap(_ path: String) -> NSBitmapImageRep {
    guard
        let image = NSImage(contentsOfFile: path),
        let tiff = image.tiffRepresentation,
        let bitmap = NSBitmapImageRep(data: tiff)
    else {
        fputs("Failed to load screenshot: \(path)\n", stderr)
        exit(1)
    }
    return bitmap
}

func rowTwoRightSpan(of bitmap: NSBitmapImageRep) -> CGRect {
    let width = CGFloat(bitmap.pixelsWide)
    let height = CGFloat(bitmap.pixelsHigh)
    return CGRect(
        x: width * 0.42,
        y: height * 0.43,
        width: width * 0.54,
        height: height * 0.27
    )
}

func rightLowerFollowup(of bitmap: NSBitmapImageRep) -> CGRect {
    let width = CGFloat(bitmap.pixelsWide)
    let height = CGFloat(bitmap.pixelsHigh)
    return CGRect(
        x: width * 0.42,
        y: height * 0.56,
        width: width * 0.54,
        height: height * 0.20
    )
}

func mediumLeftFollowup(of bitmap: NSBitmapImageRep) -> CGRect {
    let width = CGFloat(bitmap.pixelsWide)
    let height = CGFloat(bitmap.pixelsHigh)
    return CGRect(
        x: width * 0.18,
        y: height * 0.68,
        width: width * 0.42,
        height: height * 0.16
    )
}

func visualDensity(in bitmap: NSBitmapImageRep, region: CGRect, sampleStride: Int = 4) -> VisualScore {
    var inkPixels = 0
    var sampledPixels = 0
    let minX = max(Int(region.minX), 0)
    let maxX = min(Int(region.maxX), bitmap.pixelsWide - 1)
    let minY = max(Int(region.minY), 0)
    let maxY = min(Int(region.maxY), bitmap.pixelsHigh - 1)

    for y in stride(from: minY, through: maxY, by: sampleStride) {
        for x in stride(from: minX, through: maxX, by: sampleStride) {
            guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB) else {
                continue
            }
            let red = color.redComponent
            let green = color.greenComponent
            let blue = color.blueComponent
            let brightness = (red + green + blue) / 3
            let chroma = max(red, green, blue) - min(red, green, blue)
            let isInk = brightness < 0.92 || chroma > 0.045
            sampledPixels += 1
            if isInk {
                inkPixels += 1
            }
        }
    }

    guard sampledPixels > 0 else {
        fputs("Visual utilization region had no sampled pixels.\n", stderr)
        exit(1)
    }
    return VisualScore(region: region, density: Double(inkPixels) / Double(sampledPixels), sampledPixels: sampledPixels)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    fputs("Usage: swift script/test_statistics_dashboard_visual_utilization.swift <wide-right|medium-left> <before.png> <after.png>\n", stderr)
    exit(1)
}

let mode = arguments[1]
let beforeBitmap = loadBitmap(arguments[2])
let afterBitmap = loadBitmap(arguments[3])

let checkedRegions: [(name: String, before: CGRect, after: CGRect)]
switch mode {
case "wide-right":
    checkedRegions = [
        ("rowTwoRightSpan", rowTwoRightSpan(of: beforeBitmap), rowTwoRightSpan(of: afterBitmap)),
        ("rightLowerFollowup", rightLowerFollowup(of: beforeBitmap), rightLowerFollowup(of: afterBitmap))
    ]
case "medium-left":
    checkedRegions = [
        ("mediumLeftFollowup", mediumLeftFollowup(of: beforeBitmap), mediumLeftFollowup(of: afterBitmap))
    ]
default:
    fputs("Unknown visual utilization mode: \(mode)\n", stderr)
    exit(1)
}

var summaries: [String] = []
var finalSampleCount = 0
for checkedRegion in checkedRegions {
    let beforeScore = visualDensity(in: beforeBitmap, region: checkedRegion.before)
    let afterScore = visualDensity(in: afterBitmap, region: checkedRegion.after)
    let relativeGain = (afterScore.density - beforeScore.density) / max(beforeScore.density, 0.0001)
    finalSampleCount += afterScore.sampledPixels

    guard afterScore > beforeScore else {
        fputs("Expected after screenshot to use \(checkedRegion.name) better. before=\(beforeScore.density) after=\(afterScore.density)\n", stderr)
        exit(1)
    }

    guard afterScore.density - beforeScore.density >= minimumAbsoluteGain, relativeGain >= minimumImprovement else {
        fputs("Visual utilization improvement too small in \(checkedRegion.name). before=\(beforeScore.density) after=\(afterScore.density) relativeGain=\(relativeGain)\n", stderr)
        exit(1)
    }

    summaries.append(
        "\(checkedRegion.name): before=\(String(format: "%.4f", beforeScore.density)) after=\(String(format: "%.4f", afterScore.density)) gain=\(String(format: "%.1f%%", relativeGain * 100))"
    )
}

print(
    "statistics dashboard visual utilization passed: \(summaries.joined(separator: "; ")) beforeSize=\(beforeBitmap.pixelsWide)x\(beforeBitmap.pixelsHigh) afterSize=\(afterBitmap.pixelsWide)x\(afterBitmap.pixelsHigh) samples=\(finalSampleCount)"
)
