import Foundation
import CoreGraphics

@main
enum ViewerGeometryTests {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        if !condition() { throw Failure(description: message) }
    }

    static func near(_ actual: CGFloat, _ expected: CGFloat, tolerance: CGFloat = 0.000_001) -> Bool {
        abs(actual - expected) <= tolerance
    }

    static func contained(_ frame: CGRect, in bounds: CGRect) -> Bool {
        frame.minX >= bounds.minX - 0.000_001 && frame.maxX <= bounds.maxX + 0.000_001 &&
        frame.minY >= bounds.minY - 0.000_001 && frame.maxY <= bounds.maxY + 0.000_001
    }

    static func main() throws {
        let phone = CGSize(width: 1284, height: 2778)
        let screen = CGRect(x: 0, y: 70, width: 1512, height: 884)
        let portrait = ViewerGeometry.heightFittedFrame(available: screen, source: phone, centerX: 756)
        try require(near(portrait.height, screen.height), "Portrait must fill available height")
        try require(near(portrait.width / portrait.height, phone.width / phone.height), "Phone aspect must be preserved")
        try require(near(portrait.midX, 756), "Portrait should keep requested horizontal center")
        try require(near(portrait.minY, screen.minY), "Full-height portrait must align with usable screen bottom")
        try require(contained(portrait, in: screen), "Portrait must stay in screen")

        let secondary = CGRect(x: -1920, y: -140, width: 1920, height: 1040)
        let onSecondary = ViewerGeometry.heightFittedFrame(available: secondary, source: phone, centerX: -1120)
        try require(near(onSecondary.midX, -1120), "Negative-coordinate monitor center must remain valid")
        try require(near(onSecondary.height, secondary.height), "Secondary screen should also use full height")
        try require(contained(onSecondary, in: secondary), "Secondary monitor frame must stay inside that monitor")

        let landscape = ViewerGeometry.heightFittedFrame(
            available: CGRect(x: 100, y: 50, width: 1000, height: 900),
            source: CGSize(width: 2778, height: 1284), centerX: 600)
        try require(near(landscape.width, 1000), "Landscape must be width limited")
        try require(near(landscape.width / landscape.height, 2778.0 / 1284.0), "Landscape aspect must be preserved")
        try require(near(landscape.maxY, 950), "Width-limited phone should remain top aligned")

        let narrow = CGRect(x: 35, y: 20, width: 200, height: 1000)
        let onNarrow = ViewerGeometry.heightFittedFrame(available: narrow, source: phone, centerX: 100)
        try require(near(onNarrow.width, narrow.width), "Very narrow display must limit width")
        try require(contained(onNarrow, in: narrow), "Narrow display must not crop the phone")

        let clampedLeft = ViewerGeometry.heightFittedFrame(available: screen, source: phone, centerX: -10_000)
        let clampedRight = ViewerGeometry.heightFittedFrame(available: screen, source: phone, centerX: 10_000)
        try require(near(clampedLeft.minX, screen.minX), "Center left of display must clamp to left edge")
        try require(near(clampedRight.maxX, screen.maxX), "Center right of display must clamp to right edge")

        for invalidSource in [CGSize.zero, CGSize(width: CGFloat.nan, height: 100),
                              CGSize(width: 100, height: CGFloat.infinity), CGSize(width: -1, height: 100)] {
            let result = ViewerGeometry.heightFittedFrame(available: screen, source: invalidSource, centerX: .nan)
            try require(contained(result, in: screen), "Invalid source must produce visible finite fallback")
            try require(near(result.height, screen.height), "Invalid source should use portrait fallback")
            try require(result.width > 0 && result.width.isFinite, "Fallback width must be finite and positive")
        }

        for invalidBounds in [CGRect.zero, CGRect(x: CGFloat.nan, y: 0, width: 100, height: 100),
                              CGRect(x: 0, y: 0, width: CGFloat.infinity, height: 100)] {
            let result = ViewerGeometry.heightFittedFrame(available: invalidBounds, source: phone, centerX: .infinity)
            try require(result.origin.x.isFinite && result.origin.y.isFinite &&
                        result.width.isFinite && result.height.isFinite && result.width > 0 && result.height > 0,
                        "Invalid display geometry must have a safe finite fallback")
        }
        print("ViewerGeometry: 13 scenarios passed")
    }
}
