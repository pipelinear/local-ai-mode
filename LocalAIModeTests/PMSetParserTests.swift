import XCTest
@testable import Local_AI_Mode

final class PMSetParserTests: XCTestCase {
    let modern = """
    Battery Power:
     Sleep On Power Button 1
     powermode            1
     displaysleep         3
    AC Power:
     Sleep On Power Button 1
     powermode            0
     displaysleep         10
    """

    func testParsesPerSourcePowerMode() {
        let s = PMSetParser.parsePowerModes(modern)
        XCTAssertEqual(s, [PowerModeSetting(key: "powermode", source: .battery, value: 1),
                           PowerModeSetting(key: "powermode", source: .ac, value: 0)])
    }

    func testParsesLegacyKey() {
        let s = PMSetParser.parsePowerModes("AC Power:\n lowpowermode         1\n")
        XCTAssertEqual(s, [PowerModeSetting(key: "lowpowermode", source: .ac, value: 1)])
    }

    func testDisableOnlyTouchesLowPowerSources() {
        let cmds = PMSetParser.commandsToDisableLowPower(PMSetParser.parsePowerModes(modern))
        XCTAssertEqual(cmds, ["/usr/bin/pmset -b powermode 0"])
    }

    func testHighPowerModeIsNotChanged() {
        let s = [PowerModeSetting(key: "powermode", source: .ac, value: 2)]
        XCTAssertTrue(PMSetParser.commandsToDisableLowPower(s).isEmpty)
    }

    func testRestoreWritesOriginalValues() {
        let cmds = PMSetParser.commandsToRestore(PMSetParser.parsePowerModes(modern))
        XCTAssertEqual(cmds, ["/usr/bin/pmset -b powermode 1", "/usr/bin/pmset -c powermode 0"])
    }
}
