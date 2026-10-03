// test-sources: Features/Manga/MangaMokuroParser.swift Models/Manga.swift
import Foundation

@main
private enum MangaMokuroParserTests {
    static func main() throws {
        let data = Data(
            """
            {
              "title": "Fixture",
              "volume": "1",
              "pages": [
                {
                  "img_path": "images/001.jpg",
                  "img_width": 1000,
                  "img_height": 2000,
                  "blocks": []
                },
                {
                  "img_path": "images/002.jpg",
                  "img_width": 1000,
                  "img_height": 2000,
                  "blocks": [
                    {
                      "box": [800, 200, 900, 1000],
                      "vertical": true,
                      "lines": ["日本", "語"],
                      "lines_coords": [
                        [[850, 200], [900, 200], [900, 600], [850, 600]],
                        [[800, 200], [850, 200], [850, 400], [800, 400]]
                      ]
                    }
                  ]
                }
              ]
            }
            """.utf8
        )
        let regions = try MangaMokuroParser.regions(
            in: data,
            pagePath: "chapter/002.JPG",
            pageIndex: 0
        )
        require(regions?.count == 3, "Mokuro page matching should prefer the image filename")
        let resolved = regions ?? []
        require(
            resolved.allSatisfy { $0.sentence == "日本語" },
            "Mokuro lookup and mining must carry the complete text block"
        )
        require(resolved.allSatisfy(\.isVertical), "Mokuro vertical metadata must drive popup orientation")
        require(Set(resolved.map(\.blockID)).count == 1, "one Mokuro block must remain one hover block")
        require(Set(resolved.map(\.lineID)).count == 2, "Mokuro line coordinates must remain distinct")
        require(
            resolved.allSatisfy {
                $0.normalizedBounds.minX >= 0
                    && $0.normalizedBounds.minY >= 0
                    && $0.normalizedBounds.maxX <= 1
                    && $0.normalizedBounds.maxY <= 1
            },
            "Mokuro pixel coordinates must map into normalized page geometry"
        )

        let missing = try MangaMokuroParser.regions(
            in: data,
            pagePath: "missing.jpg",
            pageIndex: 99
        )
        require(missing == nil, "unmatched Mokuro pages must not claim unrelated image pages")

        if CommandLine.arguments.count == 3 {
            let realData = try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))
            let realRegions = try MangaMokuroParser.regions(
                in: realData,
                pagePath: CommandLine.arguments[2],
                pageIndex: 0
            )
            require(
                realRegions?.isEmpty == false,
                "the supplied real Mokuro page must expose local hover regions"
            )
            print("Real Mokuro page parsed: \(realRegions?.count ?? 0) character regions")
        }

        print("Manga Mokuro parser tests passed")
    }

    private static func require(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            fputs("FAIL: \(message)\n", stderr)
            exit(1)
        }
    }
}
