import Foundation

extension WholeDaySwiftParityExporter {
    static func kernelRecipes() throws -> [Recipe] {
        var recipes = try firstRecipes()
        let dayStart = try Recipe(id: "bounds").bounds()["dayLo"]!
        var dense = Recipe(id: "dense-night-v1")
        appendRestingBlock(to: &dense, start: dayStart + 3_600, seconds: 3 * 3_600)
        recipes.append(dense)
        recipes.append(Recipe(id: "dense-night-v2", stagerV2: true, raw: dense.raw))
        recipes.append(Recipe(id: "dense-night-v1-deep-hrv", deepOnly: true, raw: dense.raw))
        recipes.append(Recipe(id: "dense-night-v2-no-deep-hrv", stagerV2: true, deepOnly: true, raw: dense.raw))
        var noRR = Recipe(id: "dense-night-v1-no-rr-deep-hrv", deepOnly: true, raw: dense.raw)
        noRR.raw["rr"] = []
        recipes.append(noRR)

        var gap = Recipe(id: "whoop5-hr-only-raw-gap", raw: recipes[4].raw)
        let missing = (dayStart + 7 * 3_600)..<(dayStart + 7 * 3_600 + 1_800)
        for stream in ["hr", "rr"] {
            gap.raw[stream] = gap.raw[stream]!.filter { !missing.contains($0["ts"] as! Int) }
        }
        recipes.append(gap)

        var split = Recipe(id: "fragmented-main-night-and-nap", stagerV2: true)
        appendRestingBlock(to: &split, start: dayStart - 3_600, seconds: 3 * 3_600)
        appendRestingBlock(to: &split, start: dayStart + 2 * 3_600 + 2_700, seconds: 3 * 3_600)
        appendRestingBlock(to: &split, start: dayStart + 14 * 3_600, seconds: 2 * 3_600, bpm: 42)
        for i in 0..<2_700 {
            let ts = dayStart + 2 * 3_600 + i
            split.append("hr", ["ts": ts, "bpm": 80 + (i / 60) % 5])
            split.append("gravity", ["ts": ts, "x": Double(i % 2) * 0.5, "y": 0.0, "z": 1.0])
        }
        for offset in stride(from: 8 * 3_600, to: 14 * 3_600, by: 5) {
            split.append("hr", ["ts": dayStart + offset, "bpm": 78 + (offset / 60) % 5])
        }
        split.append("events", ["ts": dayStart + 2 * 3_600, "kind": "WRIST_OFF(10)", "payloadJSON": "{}"])
        split.append("events", ["ts": dayStart + 2 * 3_600 + 2_700, "kind": "WRIST_ON(11)", "payloadJSON": "{}"])
        recipes.append(split)

        var exercise = Recipe(id: "dense-night-v2-and-workout", stagerV2: true, raw: dense.raw)
        for i in 0..<(30 * 60) {
            let ts = dayStart + 17 * 3_600 + i
            exercise.append("hr", ["ts": ts, "bpm": 145 + (i / 60) % 7])
            exercise.append("gravity", ["ts": ts, "x": Double(i % 2) * 0.5, "y": 0.0, "z": 1.0])
            if i % 10 == 0 { exercise.append("steps", ["ts": ts, "counter": 100 + i * 2]) }
        }
        recipes.append(exercise)
        return recipes
    }

    private static func appendRestingBlock(to recipe: inout Recipe, start: Int, seconds: Int, bpm: Int = 52) {
        for i in 0..<seconds {
            let ts = start + i
            recipe.append("hr", ["ts": ts, "bpm": bpm + (i / 60) % 3])
            recipe.append("gravity", ["ts": ts, "x": 0.0, "y": 0.0, "z": 1.0])
            recipe.append("rr", ["ts": ts, "rrMs": 1000 + [0, 40, 0, -40][i % 4],
                                 "seq": 0, "ord": 0, "srcChannel": 5])
            recipe.append("resp", ["ts": ts, "raw": 1000 + [0, 100, 0, -100][i % 4]])
            if i % 60 == 0 {
                recipe.append("bandState", ["ts": ts, "state": 1, "rawByte": 1])
                recipe.append("skinTemp", ["ts": ts, "raw": 826])
                recipe.append("spo2", ["ts": ts, "red": 1000, "ir": 1200])
            }
        }
    }
}
