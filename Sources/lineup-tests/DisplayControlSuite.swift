import AppCore
import DisplayControlCore
import Foundation

func runDisplayControlTests() throws {
    let first = UUID()
    let second = UUID()
    let brightness = DisplayControlLevel(current: 50, maximum: 100)!
    let volume = DisplayControlLevel(current: 25, maximum: 100)!
    func monitor(_ stableID: String, _ connection: UUID) -> DisplayControlMonitor {
        DisplayControlMonitor(stableID: stableID, connection: connection, name: stableID,
                              brightness: .init(availability: .supported, level: brightness),
                              volume: .init(availability: .supported, level: volume))
    }
    var session = DisplayControlSession()
    session.start()
    session.replaceDisplays([monitor("desk", first), monitor("side", second)])
    check(session.target(.pointer, pointerConnection: second)?.stableID == "side",
          "media keys target the exact connection under the pointer")
    check(session.target(.display("desk"), pointerConnection: second)?.connection == first,
          "an explicit key target takes precedence over the pointer")
    check(session.target(.display("missing"), pointerConnection: second) == nil,
          "a disconnected saved target never falls back to the pointer display")
    check(session.target(.pointer, pointerConnection: nil) == nil,
          "a missing pointer display never falls back to the first monitor")
    session.replaceDisplays([monitor("same", first), monitor("same", second)])
    check(session.target(.display("same"), pointerConnection: first) == nil
            && session.target(.pointer, pointerConnection: second)?.connection == second,
          "duplicate identities refuse saved routing while exact pointer routing remains safe")
    session.replaceDisplays([monitor("desk", first), monitor("side", first)])
    check(!session.enqueue(connection: first, control: .brightness, normalizedValue: 0.8)
            && session.target(.pointer, pointerConnection: first) == nil,
          "duplicate connection tokens cannot authorize a write to an ambiguous monitor")

    var unavailable = monitor("desk", first)
    unavailable.volume = .init(availability: .unsupported("No monitor speakers"), level: volume)
    unavailable.brightness = .init(availability: .supported, error: "Read failed")
    session.replaceDisplays([unavailable, monitor("side", second)])
    check(session.monitors[0].volume.level == nil
            && !session.enqueue(connection: first, control: .volume, normalizedValue: 0.5),
          "unsupported controls never expose a level or authorize writes")
    check(!session.adjust(connection: first, control: .brightness, delta: 0.05)
            && !session.enqueue(connection: first, control: .brightness, normalizedValue: 0.5),
          "an unreadable control cannot invent a starting level or hardware range")
    check(session.enqueue(connection: second, control: .brightness, normalizedValue: 0.6),
          "one unsupported connection does not block another monitor")

    session.replaceDisplays([monitor("desk", first), monitor("side", second)])
    check(!session.enqueue(connection: first, control: .brightness, normalizedValue: .nan),
          "nonfinite slider input never reaches a hardware write")
    _ = session.enqueue(connection: first, control: .brightness, normalizedValue: 0.6)
    _ = session.enqueue(connection: first, control: .brightness, normalizedValue: 0.7)
    _ = session.enqueue(connection: first, control: .brightness, normalizedValue: 0.7)
    let command = session.nextCommand()!
    check(command.connection == first && command.control == .brightness && command.value == 70
            && session.nextCommand() == nil,
          "slider writes coalesce to the newest value without duplicate hardware work")
    _ = session.adjust(connection: first, control: .brightness, delta: 0.05)
    _ = session.adjust(connection: first, control: .brightness, delta: 0.05)
    check(session.requestedLevel(connection: first, control: .brightness) == 0.8
            && session.monitors[0].brightness.level?.current == 50,
          "repeated keys accumulate pending requests without claiming a confirmed level")
    check(session.finish(command, outcome: .confirmed(.init(current: 69, maximum: 100)!)),
          "the real readback, including a monitor adjustment, confirms a completed write")
    check(!session.finish(command, outcome: .failed("duplicate callback"))
            && session.monitors[0].brightness.level?.current == 69,
          "duplicate callbacks cannot overwrite a confirmed reading")
    let repeated = session.nextCommand()!
    check(repeated.value == 80 && session.canSend(repeated),
          "an in-flight control releases only its newest accumulated request")
    _ = session.finish(repeated, outcome: .sent)
    check(session.monitors[0].brightness.level == nil,
          "an accepted write without a readback never fabricates a confirmed level")
    let currentGeneration = session.generation
    check(session.applyReading(brightness, connection: first, control: .brightness,
                               generation: currentGeneration),
          "a later real read restores an unreadable control")

    _ = session.enqueue(connection: first, control: .brightness, normalizedValue: 0.7)
    let failed = session.nextCommand()!
    _ = session.enqueue(connection: first, control: .brightness, normalizedValue: 0.9)
    _ = session.enqueue(connection: first, control: .volume, normalizedValue: 0.3)
    _ = session.enqueue(connection: second, control: .brightness, normalizedValue: 0.6)
    _ = session.finish(failed, outcome: .failed("Monitor disconnected"))
    let unaffectedVolume = session.nextCommand()!
    let unaffectedDisplay = session.nextCommand()!
    check(session.monitors[0].brightness.level == nil
            && session.monitors[0].brightness.error == "Monitor disconnected"
            && unaffectedVolume.control == .volume && unaffectedVolume.connection == first
            && unaffectedDisplay.connection == second && session.nextCommand() == nil,
          "a failed control clears its pending writes while other controls and displays continue")
    _ = session.finish(unaffectedVolume, outcome: .confirmed(volume))
    _ = session.finish(unaffectedDisplay, outcome: .confirmed(brightness))
    _ = session.applyReading(brightness, connection: first, control: .brightness,
                             generation: session.generation)
    _ = session.enqueue(connection: first, control: .brightness, normalizedValue: 0.7)
    let unreadable = session.nextCommand()!
    _ = session.enqueue(connection: first, control: .brightness, normalizedValue: 0.9)
    _ = session.applyReadFailure("Read timed out", connection: first, control: .brightness,
                                 generation: session.generation)
    check(!session.canSend(unreadable) && session.nextCommand() == nil
            && session.monitors[0].brightness.level == nil
            && session.monitors[0].volume.level == volume
            && session.monitors[1].brightness.level == brightness,
          "a failed refresh revokes outstanding writes only for its unreadable control")
    _ = session.applyReading(brightness, connection: first, control: .brightness,
                             generation: session.generation)
    _ = session.enqueue(connection: first, control: .brightness, normalizedValue: 0.8)
    let stale = session.nextCommand()!
    let oldGeneration = session.generation
    session.replaceDisplays([monitor("replacement", first), monitor("side", second)])
    check(!session.canSend(stale) && !session.finish(stale, outcome: .failed("late failure"))
            && !session.applyReading(.init(current: 90, maximum: 100)!, connection: first,
                                     control: .brightness, generation: oldGeneration)
            && !session.applyReadFailure("obsolete read failure", connection: first,
                                         control: .brightness, generation: oldGeneration)
            && session.monitors[0].brightness.level?.current == 50,
          "rediscovery invalidates writes and callbacks even when a transport reuses its token")
    _ = session.enqueue(connection: second, control: .volume, normalizedValue: 0.4)
    let stopping = session.nextCommand()!
    _ = session.enqueue(connection: first, control: .brightness, normalizedValue: 0.9)
    session.stop()
    check(!session.canSend(stopping) && session.nextCommand() == nil
            && !session.finish(stopping, outcome: .confirmed(volume))
            && !session.enqueue(connection: first, control: .brightness, normalizedValue: 0.8),
          "shutdown invalidates queued work and prevents new or late monitor commands")
    session.start()
    session.replaceDisplays([monitor("desk", first)])
    check(session.nextCommand() == nil && session.monitors[0].brightness.level?.current == 50,
          "startup reads current levels without replaying previous requests")

    session.replaceDisplays([monitor("desk", first), monitor("side", second)])
    _ = session.enqueue(connection: first, control: .brightness, normalizedValue: 0.7)
    let rerouted = session.nextCommand()!
    _ = session.enqueue(connection: first, control: .brightness, normalizedValue: 0.9)
    _ = session.enqueue(connection: first, control: .volume, normalizedValue: 0.3)
    _ = session.enqueue(connection: second, control: .brightness, normalizedValue: 0.8)
    let beforeRouting = session.generation
    session.cancelPendingCommands()
    check(session.monitors.map(\.connection) == [first, second]
            && session.monitors.map(\.stableID) == ["desk", "side"]
            && session.monitors[0].brightness.level == nil
            && session.monitors[0].volume.level == volume
            && session.monitors[1].brightness.level == brightness,
          "routing cancellation keeps identities and clears only a possibly executing control's reading")
    check(!session.canSend(rerouted) && session.nextCommand() == nil
            && !session.finish(rerouted, outcome: .confirmed(brightness))
            && !session.applyReading(brightness, connection: first, control: .brightness,
                                     generation: beforeRouting)
            && !session.adjust(connection: first, control: .brightness, delta: 0.05),
          "routing edits revoke commands and callbacks until an affected control is read again")
    _ = session.applyReading(.init(current: 68, maximum: 100)!, connection: first,
                             control: .brightness, generation: session.generation)
    _ = session.adjust(connection: first, control: .brightness, delta: 0.05)
    check(session.nextCommand()?.value == 73,
          "an adjustment after routing cancellation starts at the freshly observed hardware level")

    var handoffSession = DisplayControlSession()
    handoffSession.start()
    handoffSession.replaceDisplays([monitor("desk", first)])
    _ = handoffSession.enqueue(connection: first, control: .brightness, normalizedValue: 0.6)
    let keyboardBeforeHandoff = handoffSession.nextCommand()!
    let beforeHandoffGeneration = handoffSession.generation
    handoffSession.cancelPendingCommands()
    check(handoffSession.enqueueAfterReading(connection: first, control: .brightness, normalizedValue: 0.2)
            && handoffSession.hasDeferredRequests && handoffSession.monitors[0].brightness.level == nil
            && handoffSession.requestedLevel(connection: first, control: .brightness) == 0.2
            && handoffSession.nextCommand() == nil,
          "one manual slider click survives keyboard cancellation without claiming a level or sending before a read")
    _ = handoffSession.enqueueAfterReading(connection: first, control: .brightness, normalizedValue: 0.35)
    check(!handoffSession.finish(keyboardBeforeHandoff, outcome: .confirmed(brightness))
            && !handoffSession.applyReading(brightness, connection: first, control: .brightness,
                                            generation: beforeHandoffGeneration)
            && handoffSession.requestedLevel(connection: first, control: .brightness) == 0.35,
          "late keyboard callbacks cannot replace the latest manual intent waiting for a fresh range")
    _ = handoffSession.applyReading(.init(current: 120, maximum: 200)!, connection: first,
                                    control: .brightness, generation: handoffSession.generation)
    let manualAfterHandoff = handoffSession.nextCommand()!
    check(!handoffSession.hasDeferredRequests && manualAfterHandoff.value == 70
            && manualAfterHandoff.maximum == 200 && handoffSession.nextCommand() == nil
            && handoffSession.monitors[0].brightness.level?.current == 120,
          "a fresh read sends only the latest manual value using its actual maximum and retains the confirmed reading")
    _ = handoffSession.finish(manualAfterHandoff, outcome: .sent)
    _ = handoffSession.enqueueAfterReading(connection: first, control: .brightness, normalizedValue: 0.4)
    _ = handoffSession.applyReadFailure("Read timed out", connection: first, control: .brightness,
                                        generation: handoffSession.generation)
    _ = handoffSession.applyReading(.init(current: 120, maximum: 200)!, connection: first,
                                    control: .brightness, generation: handoffSession.generation)
    check(!handoffSession.hasDeferredRequests && handoffSession.nextCommand() == nil,
          "a failed handoff read cancels manual intent instead of blindly replaying it after recovery")
    check(handoffSession.enqueueAfterReading(connection: first, control: .brightness, normalizedValue: 0.8)
            && !handoffSession.hasDeferredRequests && handoffSession.nextCommand()?.value == 160,
          "manual controls with a known reading continue to enqueue immediately")
    handoffSession.cancelPendingCommands()
    _ = handoffSession.enqueueAfterReading(connection: first, control: .brightness, normalizedValue: 0.5)
    let deferredGeneration = handoffSession.generation
    handoffSession.replaceDisplays([monitor("replacement", first)])
    check(!handoffSession.hasDeferredRequests && handoffSession.nextCommand() == nil
            && !handoffSession.applyReading(brightness, connection: first, control: .brightness,
                                            generation: deferredGeneration),
          "reconnection drops deferred manual intent even when the previous connection token is reused")

    var synchronizedSession = DisplayControlSession()
    synchronizedSession.start()
    var calibratedReference = monitor("desk", first)
    calibratedReference.brightness.level = .init(current: 25, maximum: 100)!
    let unsupportedConnection = UUID(), unreadableConnection = UUID(), excludedConnection = UUID()
    var unsupportedBrightness = monitor("unsupported", unsupportedConnection)
    unsupportedBrightness.brightness = .init(availability: .unsupported("No DDC brightness"))
    var unreadableBrightness = monitor("unreadable", unreadableConnection)
    unreadableBrightness.brightness = .init(availability: .supported, error: "Read timed out")
    synchronizedSession.replaceDisplays([calibratedReference, monitor("side", second),
        unsupportedBrightness, unreadableBrightness, monitor("excluded", excludedConnection)])
    let allowedConnections: Set<UUID> = [first, second, unsupportedConnection, unreadableConnection]
    let limits: [UUID: Double] = [first: 0.5, second: 0.8]
    var synchronizedGroup = synchronizedSession.brightnessGroup(reference: first, synchronized: true,
                                         allowedConnections: allowedConnections, brightnessLimits: limits)!
    check(synchronizedGroup.connections == [first, second] && synchronizedGroup.logicalLevel == 0.5
            && synchronizedSession.nextCommand() == nil,
          "sync uses the calibrated reference and only readable allowed displays without startup writes")
    check(synchronizedSession.brightnessGroup(reference: unreadableConnection, synchronized: true,
                allowedConnections: allowedConnections, brightnessLimits: limits) == nil
            && synchronizedSession.brightnessGroup(reference: excludedConnection, synchronized: true,
                allowedConnections: allowedConnections, brightnessLimits: limits) == nil,
          "sync never substitutes another display for an unreadable or excluded reference")
    check(synchronizedSession.adjustBrightness(&synchronizedGroup, delta: 0.25,
                                               brightnessLimits: limits) == [first, second],
          "a synchronized step is accepted separately by both eligible display connections")
    let referenceCommand = synchronizedSession.nextCommand()!
    let sideCommand = synchronizedSession.nextCommand()!
    check(referenceCommand.connection == first && referenceCommand.value == 38
            && sideCommand.connection == second && sideCommand.value == 60
            && synchronizedGroup.logicalLevel == 0.75
            && synchronizedSession.monitors[0].brightness.level?.current == 25
            && synchronizedSession.monitors[1].brightness.level?.current == 50,
          "one logical step maps through each brightness limit while confirmed values remain real reads")
    _ = synchronizedSession.finish(referenceCommand, outcome: .failed("Reference connection failed"))
    _ = synchronizedSession.finish(sideCommand, outcome: .confirmed(.init(current: 60, maximum: 100)!))
    check(synchronizedSession.adjustBrightness(&synchronizedGroup, delta: 0.0625,
                                               brightnessLimits: limits) == [second]
            && synchronizedSession.nextCommand()?.value == 65,
          "one failed sync member cannot block another member or replace the group's original intent")
    synchronizedSession.replaceDisplays([monitor("replacement", first), monitor("side", second)])
    check(synchronizedSession.adjustBrightness(&synchronizedGroup, delta: 0.25,
                                               brightnessLimits: limits).isEmpty
            && synchronizedSession.nextCommand() == nil,
          "reconnection invalidates the held sync group even if a connection token is reused")

    var singleGroup = synchronizedSession.brightnessGroup(reference: first, synchronized: false,
                                     allowedConnections: [first, second], brightnessLimits: [first: 0.05],
                                     brightnessMinimums: [first: 0.03])!
    _ = synchronizedSession.adjustBrightness(&singleGroup, delta: 0.125,
                                             brightnessLimits: [first: 0.05, second: 0.5],
                                             brightnessMinimums: [first: 0.03])
    check(singleGroup.connections == [first] && synchronizedSession.nextCommand()?.value == 63
            && synchronizedSession.nextCommand() == nil,
          "single-display keys ignore calibration and never enqueue another monitor")

    let intervalMiddle = DisplayBrightnessMath.hardwareLevel(logicalLevel: 0.5,
                                  brightnessLimit: 0.8, brightnessMinimum: 0.1)!
    let inverseMiddle = DisplayBrightnessMath.logicalLevel(hardwareLevel: 0.45,
                                  brightnessLimit: 0.8, brightnessMinimum: 0.1)!
    check(abs(intervalMiddle - 0.45) < 0.000001 && abs(inverseMiddle - 0.5) < 0.000001
            && DisplayBrightnessMath.hardwareLevel(logicalLevel: 0, brightnessLimit: 0.8, brightnessMinimum: 0.1) == 0.1
            && DisplayBrightnessMath.hardwareLevel(logicalLevel: 1, brightnessLimit: 0.8, brightnessMinimum: 0.1) == 0.8
            && DisplayBrightnessMath.logicalLevel(hardwareLevel: 0, brightnessLimit: 0.8, brightnessMinimum: 0.1) == 0
            && DisplayBrightnessMath.logicalLevel(hardwareLevel: 1, brightnessLimit: 0.8, brightnessMinimum: 0.1) == 1,
          "a ten-to-eighty-percent interval maps shared midpoint to forty-five and clamps its endpoints")
    for (minimum, maximum) in [(0.2, 0.1), (0.1, 0.1), (-0.01, 0.8),
                                (Double.nan, 0.8), (0.1, Double.infinity), (0.01, 0.04)] {
        check(DisplayBrightnessMath.hardwareLevel(logicalLevel: 0.5, brightnessLimit: maximum,
                                                   brightnessMinimum: minimum) == nil
                && DisplayBrightnessMath.logicalLevel(hardwareLevel: 0.5, brightnessLimit: maximum,
                                                       brightnessMinimum: minimum) == nil,
              "unordered, nonfinite and out-of-range calibration cannot produce a brightness request")
    }
    var intervalSession = DisplayControlSession()
    intervalSession.start()
    var intervalReference = monitor("desk", first)
    intervalReference.brightness.level = .init(current: 45, maximum: 100)!
    intervalSession.replaceDisplays([intervalReference, monitor("side", second)])
    var intervalGroup = intervalSession.brightnessGroup(reference: first, synchronized: true,
        allowedConnections: [first, second], brightnessLimits: [first: 0.8], brightnessMinimums: [first: 0.1])!
    _ = intervalSession.adjustBrightness(&intervalGroup, delta: -0.5,
        brightnessLimits: [first: 0.8], brightnessMinimums: [first: 0.1])
    let minimumCommands = [intervalSession.nextCommand()!, intervalSession.nextCommand()!]
    let minimumValues = Dictionary(uniqueKeysWithValues: minimumCommands.map { ($0.connection, $0.value) })
    check(intervalGroup.logicalLevel == 0 && minimumValues[first] == 10 && minimumValues[second] == 0,
          "sync reads the reference's inverse interval and applies each display's own minimum")
    for command in minimumCommands {
        _ = intervalSession.finish(command, outcome: .confirmed(.init(current: command.connection == first ? 10 : 0,
                                                                     maximum: 100)!))
    }
    _ = intervalSession.adjustBrightness(&intervalGroup, delta: 1,
        brightnessLimits: [first: 0.8], brightnessMinimums: [first: 0.1])
    let intervalMaximumCommands = [intervalSession.nextCommand()!, intervalSession.nextCommand()!]
    let intervalMaximumValues = Dictionary(uniqueKeysWithValues: intervalMaximumCommands.map { ($0.connection, $0.value) })
    check(intervalMaximumValues[first] == 80 && intervalMaximumValues[second] == 100,
          "the same sync group reaches each configured maximum without reusing another display's interval")

    var fineSession = DisplayControlSession()
    fineSession.start()
    var zeroReference = monitor("desk", first), zeroSide = monitor("side", second)
    zeroReference.brightness.level = .init(current: 0, maximum: 100)!
    zeroSide.brightness.level = .init(current: 0, maximum: 100)!
    fineSession.replaceDisplays([zeroReference, zeroSide])
    let fineLimits: [UUID: Double] = [first: 0.05]
    var fineGroup = fineSession.brightnessGroup(reference: first, synchronized: true,
                                  allowedConnections: [first, second], brightnessLimits: fineLimits)!
    for _ in 0..<16 {
        _ = fineSession.adjustBrightness(&fineGroup, delta: DisplayMediaKeyAdjustment.fine.step,
                                          brightnessLimits: fineLimits)
    }
    let fineCommands = [fineSession.nextCommand()!, fineSession.nextCommand()!]
    let fineValues = Dictionary(uniqueKeysWithValues: fineCommands.map { ($0.connection, $0.value) })
    check(fineGroup.logicalLevel == 0.25 && fineValues[first] == 1 && fineValues[second] == 25,
          "fine repeats accumulate below one hardware step even with a five-percent brightness limit")
    for command in fineCommands {
        _ = fineSession.finish(command, outcome: .confirmed(.init(current: command.connection == first ? 1 : 25,
                                                                 maximum: 100)!))
    }
    for _ in 0..<48 {
        _ = fineSession.adjustBrightness(&fineGroup, delta: DisplayMediaKeyAdjustment.fine.step,
                                          brightnessLimits: fineLimits)
    }
    let maximumCommands = [fineSession.nextCommand()!, fineSession.nextCommand()!]
    let maximumValues = Dictionary(uniqueKeysWithValues: maximumCommands.map { ($0.connection, $0.value) })
    check(fineGroup.logicalLevel == 1 && maximumValues[first] == 5 && maximumValues[second] == 100,
          "held fine steps reach the logical maximum without rounding drift or exceeding display limits")
    fineSession.cancelPendingCommands()
    check(fineSession.adjustBrightness(&fineGroup, delta: -0.1, brightnessLimits: fineLimits).isEmpty,
          "routing or manual-control cancellation invalidates a group's unrounded logical intent")
    check(DisplayBrightnessMath.hardwareLevel(logicalLevel: 0.5, brightnessLimit: .nan) == nil
            && DisplayBrightnessMath.logicalLevel(hardwareLevel: 0.5, brightnessLimit: 0) == nil,
          "invalid calibration cannot create a logical or hardware brightness request")

    var blackoutSession = DisplayControlSession()
    blackoutSession.start()
    blackoutSession.replaceDisplays([intervalReference, monitor("side", second),
                                    unsupportedBrightness, unreadableBrightness])
    let blackoutLimits: [UUID: Double] = [first: 0.8]
    let blackoutMinimums: [UUID: Double] = [first: 0.1]
    var blackoutGroup = blackoutSession.brightnessGroup(reference: first, synchronized: true,
        allowedConnections: allowedConnections, brightnessLimits: blackoutLimits,
        brightnessMinimums: blackoutMinimums)!
    _ = blackoutSession.adjustBrightness(&blackoutGroup, delta: -0.5,
        brightnessLimits: blackoutLimits, brightnessMinimums: blackoutMinimums,
        blackScreenBelowMinimum: true)
    let blackoutFloorCommands = [blackoutSession.nextCommand()!, blackoutSession.nextCommand()!]
    check(blackoutGroup.logicalLevel == 0 && blackoutSession.blackedOutConnections.isEmpty
            && blackoutFloorCommands.map(\.value) == [10, 0]
            && blackoutSession.monitors[0].brightness.level?.current == 45,
          "reaching zero sends each physical minimum without blacking out or inventing readback")
    for command in blackoutFloorCommands {
        _ = blackoutSession.finish(command, outcome: .confirmed(.init(current: command.value, maximum: 100)!))
    }
    _ = blackoutSession.adjustBrightness(&blackoutGroup, delta: -DisplayMediaKeyAdjustment.fine.step,
        brightnessLimits: blackoutLimits, brightnessMinimums: blackoutMinimums)
    check(blackoutSession.blackedOutConnections.isEmpty && blackoutSession.nextCommand() == nil,
          "the default brightness behavior keeps displays visible on extra decreases at the floor")
    let blackedOut = blackoutSession.adjustBrightness(&blackoutGroup, delta: -DisplayMediaKeyAdjustment.fine.step,
        brightnessLimits: blackoutLimits, brightnessMinimums: blackoutMinimums,
        blackScreenBelowMinimum: true)
    check(blackedOut == [first, second] && blackoutSession.blackedOutConnections == [first, second]
            && blackoutSession.nextCommand() == nil
            && blackoutSession.monitors[0].brightness.level?.current == 10
            && blackoutSession.requestedLevel(connection: first, control: .brightness) == 0.1,
          "an opted-in extra decrease shades only eligible pinned displays and retains the real ten-percent level")
    _ = blackoutSession.applyReading(.init(current: 10, maximum: 100)!, connection: first,
                                    control: .brightness, generation: blackoutSession.generation)
    check(blackoutSession.blackedOutConnections == [first, second],
          "unchanged periodic reads cannot wake a black screen")
    var wakeGroup = blackoutSession.brightnessGroup(reference: first, synchronized: true,
        allowedConnections: allowedConnections, brightnessLimits: blackoutLimits,
        brightnessMinimums: blackoutMinimums)!
    check(wakeGroup.logicalLevel == 0,
          "a fresh up press on a shaded calibrated reference starts at logical zero")
    _ = blackoutSession.adjustBrightness(&wakeGroup, delta: DisplayMediaKeyAdjustment.standard.step,
        brightnessLimits: blackoutLimits, brightnessMinimums: blackoutMinimums,
        blackScreenBelowMinimum: true)
    let wakeCommands = [blackoutSession.nextCommand()!, blackoutSession.nextCommand()!]
    check(blackoutSession.blackedOutConnections.isEmpty && wakeCommands.map(\.value) == [14, 6]
            && blackoutSession.monitors[0].brightness.level?.current == 10,
          "brightness up removes the shades and increases from zero without claiming the pending level")
    for command in wakeCommands {
        _ = blackoutSession.finish(command, outcome: .confirmed(.init(current: command.value, maximum: 100)!))
    }
    _ = blackoutSession.adjustBrightness(&wakeGroup, delta: -1,
        brightnessLimits: blackoutLimits, brightnessMinimums: blackoutMinimums,
        blackScreenBelowMinimum: true)
    let restoredFloorCommands = [blackoutSession.nextCommand()!, blackoutSession.nextCommand()!]
    for command in restoredFloorCommands {
        _ = blackoutSession.finish(command, outcome: .confirmed(.init(current: command.value, maximum: 100)!))
    }
    _ = blackoutSession.adjustBrightness(&wakeGroup, delta: -0.0625,
        brightnessLimits: blackoutLimits, brightnessMinimums: blackoutMinimums,
        blackScreenBelowMinimum: true)
    blackoutSession.restoreBrightnessVisibility(connection: first)
    check(blackoutSession.blackedOutConnections == [second] && blackoutSession.nextCommand() == nil
            && blackoutSession.monitors[0].brightness.level?.current == 10,
          "manual visibility recovery restores one display without changing another or issuing hardware writes")
    _ = blackoutSession.applyReading(.init(current: 5, maximum: 100)!, connection: second,
                                    control: .brightness, generation: blackoutSession.generation)
    check(blackoutSession.blackedOutConnections.isEmpty && blackoutSession.nextCommand() == nil,
          "a changed real brightness reading restores visibility without reapplying saved levels")

    blackoutSession.replaceDisplays([intervalReference, monitor("side", second)])
    var pendingBlackoutGroup = blackoutSession.brightnessGroup(reference: first, synchronized: true,
        allowedConnections: [first, second], brightnessLimits: blackoutLimits,
        brightnessMinimums: blackoutMinimums)!
    _ = blackoutSession.adjustBrightness(&pendingBlackoutGroup, delta: -1,
        brightnessLimits: blackoutLimits, brightnessMinimums: blackoutMinimums,
        blackScreenBelowMinimum: true)
    _ = blackoutSession.adjustBrightness(&pendingBlackoutGroup, delta: -0.0625,
        brightnessLimits: blackoutLimits, brightnessMinimums: blackoutMinimums,
        blackScreenBelowMinimum: true)
    let blackReferenceBeforeReadback = blackoutSession.brightnessGroup(reference: first, synchronized: true,
        allowedConnections: [first, second], brightnessLimits: blackoutLimits,
        brightnessMinimums: blackoutMinimums)!
    check(blackReferenceBeforeReadback.logicalLevel == 0
            && blackoutSession.monitors[0].brightness.level?.current == 45,
          "a fresh group on a black reference starts at zero even before its minimum write readback")
    let failingBlackoutWrite = blackoutSession.nextCommand()!
    _ = blackoutSession.finish(failingBlackoutWrite, outcome: .failed("Cable disconnected"))
    check(blackoutSession.blackedOutConnections == [second]
            && blackoutSession.monitors[0].brightness.level == nil,
          "failed brightness writes restore the affected screen while another shaded member stays independent")
    let successfulBlackoutWrite = blackoutSession.nextCommand()!
    _ = blackoutSession.finish(successfulBlackoutWrite, outcome: .confirmed(.init(current: 0, maximum: 100)!))
    check(blackoutSession.blackedOutConnections == [second],
          "owned minimum write readback preserves the accepted visual blackout")
    _ = blackoutSession.applyReadFailure("Speakers unavailable", connection: second, control: .volume,
                                        generation: blackoutSession.generation)
    check(blackoutSession.blackedOutConnections == [second],
          "a volume error does not change brightness visibility")
    _ = blackoutSession.applyReadFailure("Brightness unavailable", connection: second, control: .brightness,
                                        generation: blackoutSession.generation)
    check(blackoutSession.blackedOutConnections.isEmpty,
          "an unreadable brightness control cannot leave the display hidden")

    var blackoutFloorReference = monitor("desk", first)
    blackoutFloorReference.brightness.level = .init(current: 10, maximum: 100)!
    blackoutSession.replaceDisplays([blackoutFloorReference, zeroSide])
    var invalidMemberGroup = blackoutSession.brightnessGroup(reference: first, synchronized: true,
        allowedConnections: [first, second], brightnessLimits: [first: 0.8, second: .nan],
        brightnessMinimums: blackoutMinimums)!
    _ = blackoutSession.adjustBrightness(&invalidMemberGroup, delta: -0.0625,
        brightnessLimits: [first: 0.8, second: .nan], brightnessMinimums: blackoutMinimums,
        blackScreenBelowMinimum: true)
    check(blackoutSession.blackedOutConnections == [first] && blackoutSession.nextCommand() == nil,
          "invalid calibration in one group member cannot shade it or block another readable display")
    blackoutSession.cancelPendingCommands()
    check(blackoutSession.blackedOutConnections.isEmpty
            && blackoutSession.adjustBrightness(&invalidMemberGroup, delta: -0.0625,
                brightnessLimits: blackoutLimits, brightnessMinimums: blackoutMinimums,
                blackScreenBelowMinimum: true).isEmpty,
          "routing cancellation restores all shades and a stale held group cannot hide them again")
    var beforeReconnect = blackoutSession.brightnessGroup(reference: first, synchronized: true,
        allowedConnections: [first, second], brightnessLimits: blackoutLimits,
        brightnessMinimums: blackoutMinimums)!
    _ = blackoutSession.adjustBrightness(&beforeReconnect, delta: -0.0625,
        brightnessLimits: blackoutLimits, brightnessMinimums: blackoutMinimums,
        blackScreenBelowMinimum: true)
    blackoutSession.replaceDisplays([blackoutFloorReference, zeroSide])
    check(blackoutSession.blackedOutConnections.isEmpty
            && blackoutSession.adjustBrightness(&beforeReconnect, delta: -0.0625,
                brightnessLimits: blackoutLimits, brightnessMinimums: blackoutMinimums,
                blackScreenBelowMinimum: true).isEmpty,
          "display rediscovery restores shades even if the transport reuses a connection token")
    var singleBlackoutGroup = blackoutSession.brightnessGroup(reference: second, synchronized: false,
        allowedConnections: [first, second], brightnessLimits: [second: 0.05],
        brightnessMinimums: [second: 0.03])!
    _ = blackoutSession.adjustBrightness(&singleBlackoutGroup, delta: -0.0625,
        brightnessLimits: [second: 0.05], brightnessMinimums: [second: 0.03],
        blackScreenBelowMinimum: true)
    check(blackoutSession.blackedOutConnections == [second],
          "single-display blackout remains isolated and ignores sync calibration")
    _ = blackoutSession.adjustBrightness(&singleBlackoutGroup, delta: DisplayMediaKeyAdjustment.fine.step,
        brightnessLimits: [second: 0.05], brightnessMinimums: [second: 0.03],
        blackScreenBelowMinimum: true)
    let singleWake = blackoutSession.nextCommand()!
    check(blackoutSession.blackedOutConnections.isEmpty && singleWake.value == 2,
          "fine brightness up restores a single screen using the hardware scale without calibration drift")
    _ = blackoutSession.adjustBrightness(&singleBlackoutGroup, delta: -1, blackScreenBelowMinimum: true)
    _ = blackoutSession.adjustBrightness(&singleBlackoutGroup, delta: -0.0625, blackScreenBelowMinimum: true)
    _ = blackoutSession.finish(singleWake, outcome: .sent)
    check(blackoutSession.blackedOutConnections.isEmpty && blackoutSession.monitors[1].brightness.level == nil,
          "a brightness write without confirmed readback restores visibility instead of hiding an unknown value")
    _ = blackoutSession.applyReading(.init(current: 0, maximum: 100)!, connection: second,
                                    control: .brightness, generation: blackoutSession.generation)
    _ = blackoutSession.adjustBrightness(&singleBlackoutGroup, delta: -0.0625, blackScreenBelowMinimum: true)
    blackoutSession.stop()
    blackoutSession.start()
    check(blackoutSession.blackedOutConnections.isEmpty && blackoutSession.nextCommand() == nil,
          "shutdown and restart never retain a screen blackout or recreate a hardware command")

    var clippedMinimumSession = DisplayControlSession()
    clippedMinimumSession.start()
    clippedMinimumSession.replaceDisplays([monitor("desk", first)])
    var clippedMinimumGroup = clippedMinimumSession.brightnessGroup(reference: first, synchronized: false,
                                                                   allowedConnections: [first])!
    _ = clippedMinimumSession.adjustBrightness(&clippedMinimumGroup, delta: -1, blackScreenBelowMinimum: true)
    let clippedMinimumCommand = clippedMinimumSession.nextCommand()!
    _ = clippedMinimumSession.finish(clippedMinimumCommand, outcome: .confirmed(.init(current: 1, maximum: 100)!))
    clippedMinimumGroup = clippedMinimumSession.brightnessGroup(reference: first, synchronized: false,
                                                               allowedConnections: [first])!
    check(clippedMinimumGroup.logicalLevel == 0,
          "confirmed firmware clipping retains only the attempted floor across distinct key presses")
    _ = clippedMinimumSession.adjustBrightness(&clippedMinimumGroup, delta: -0.0625, blackScreenBelowMinimum: true)
    _ = clippedMinimumSession.adjustBrightness(&clippedMinimumGroup, delta: -0.0625, blackScreenBelowMinimum: true)
    check(clippedMinimumCommand.value == 0 && clippedMinimumSession.blackedOutConnections == [first]
            && clippedMinimumSession.monitors[0].brightness.level?.current == 1
            && clippedMinimumSession.requestedLevel(connection: first, control: .brightness) == 0.01
            && clippedMinimumSession.nextCommand() == nil,
          "extra down and black-screen repeats issue no new hardware writes when firmware reads back above its requested minimum")
    var clippedWakeGroup = clippedMinimumSession.brightnessGroup(reference: first, synchronized: false,
                                                                allowedConnections: [first])!
    _ = clippedMinimumSession.adjustBrightness(&clippedWakeGroup, delta: DisplayMediaKeyAdjustment.fine.step,
                                               blackScreenBelowMinimum: true)
    let clippedWakeCommand = clippedMinimumSession.nextCommand()!
    check(clippedMinimumSession.blackedOutConnections.isEmpty && clippedWakeCommand.value == 2,
          "a new up press after firmware clipping wakes from logical zero instead of adding to the clipped hardware minimum")
    _ = clippedMinimumSession.finish(clippedWakeCommand, outcome: .confirmed(.init(current: 2, maximum: 100)!))
    check(clippedMinimumSession.brightnessGroup(reference: first, synchronized: false,
                                               allowedConnections: [first])?.logicalLevel == 0.02,
          "brightness up clears the floor marker so later presses start from actual hardware again")

    clippedMinimumSession.replaceDisplays([monitor("desk", first)])
    var clippedCalibratedGroup = clippedMinimumSession.brightnessGroup(reference: first, synchronized: true,
        allowedConnections: [first], brightnessLimits: blackoutLimits, brightnessMinimums: blackoutMinimums)!
    _ = clippedMinimumSession.adjustBrightness(&clippedCalibratedGroup, delta: -1,
        brightnessLimits: blackoutLimits, brightnessMinimums: blackoutMinimums, blackScreenBelowMinimum: true)
    let clippedCalibratedCommand = clippedMinimumSession.nextCommand()!
    _ = clippedMinimumSession.finish(clippedCalibratedCommand,
                                    outcome: .confirmed(.init(current: 11, maximum: 100)!))
    clippedCalibratedGroup = clippedMinimumSession.brightnessGroup(reference: first, synchronized: true,
        allowedConnections: [first], brightnessLimits: blackoutLimits, brightnessMinimums: blackoutMinimums)!
    _ = clippedMinimumSession.adjustBrightness(&clippedCalibratedGroup, delta: -0.0625,
        brightnessLimits: blackoutLimits, brightnessMinimums: blackoutMinimums, blackScreenBelowMinimum: true)
    check(clippedCalibratedCommand.value == 10 && clippedCalibratedGroup.logicalLevel == 0
            && clippedMinimumSession.blackedOutConnections == [first]
            && clippedMinimumSession.monitors[0].brightness.level?.current == 11
            && clippedMinimumSession.nextCommand() == nil,
          "fresh down after a clipped calibrated minimum shades the screen without resending ten percent or claiming zero")
    clippedMinimumSession.restoreBrightnessVisibility()
    _ = clippedMinimumSession.applyReading(.init(current: 12, maximum: 100)!, connection: first,
                                          control: .brightness, generation: clippedMinimumSession.generation)
    check(clippedMinimumSession.brightnessGroup(reference: first, synchronized: true,
        allowedConnections: [first], brightnessLimits: blackoutLimits,
        brightnessMinimums: blackoutMinimums)!.logicalLevel > 0,
          "a changed external hardware reading revokes the retained minimum intent")
    clippedCalibratedGroup = clippedMinimumSession.brightnessGroup(reference: first, synchronized: true,
        allowedConnections: [first], brightnessLimits: blackoutLimits, brightnessMinimums: blackoutMinimums)!
    _ = clippedMinimumSession.adjustBrightness(&clippedCalibratedGroup, delta: -1,
        brightnessLimits: blackoutLimits, brightnessMinimums: blackoutMinimums, blackScreenBelowMinimum: true)
    let floorBeforeManual = clippedMinimumSession.nextCommand()!
    _ = clippedMinimumSession.finish(floorBeforeManual, outcome: .confirmed(.init(current: 11, maximum: 100)!))
    _ = clippedMinimumSession.enqueueAfterReading(connection: first, control: .brightness, normalizedValue: 0.5)
    let absoluteAfterFloor = clippedMinimumSession.nextCommand()!
    _ = clippedMinimumSession.finish(absoluteAfterFloor, outcome: .confirmed(.init(current: 11, maximum: 100)!))
    check(absoluteAfterFloor.value == 50 && clippedMinimumSession.brightnessGroup(reference: first,
        synchronized: true, allowedConnections: [first], brightnessLimits: blackoutLimits,
        brightnessMinimums: blackoutMinimums)!.logicalLevel > 0,
          "manual absolute control clears floor intent even when the monitor returns its previous level")
    clippedMinimumSession.replaceDisplays([monitor("desk", first)])
    var defaultClippedGroup = clippedMinimumSession.brightnessGroup(reference: first, synchronized: false,
                                                                  allowedConnections: [first])!
    _ = clippedMinimumSession.adjustBrightness(&defaultClippedGroup, delta: -1)
    let defaultClippedCommand = clippedMinimumSession.nextCommand()!
    _ = clippedMinimumSession.finish(defaultClippedCommand, outcome: .confirmed(.init(current: 1, maximum: 100)!))
    check(clippedMinimumSession.brightnessGroup(reference: first, synchronized: false,
                                               allowedConnections: [first])?.logicalLevel == 0.01,
          "firmware clipping without the blackout opt-in keeps fresh presses based on the real hardware level")

    var manualBlackoutSession = DisplayControlSession()
    manualBlackoutSession.start()
    manualBlackoutSession.replaceDisplays([monitor("desk", first), monitor("side", second)])
    var manualBlackoutGroup = manualBlackoutSession.brightnessGroup(reference: first, synchronized: true,
        allowedConnections: [first, second])!
    _ = manualBlackoutSession.adjustBrightness(&manualBlackoutGroup, delta: -1, blackScreenBelowMinimum: true)
    let cancelledMinimumWrites = [manualBlackoutSession.nextCommand()!, manualBlackoutSession.nextCommand()!]
    _ = manualBlackoutSession.adjustBrightness(&manualBlackoutGroup, delta: -0.0625, blackScreenBelowMinimum: true)
    _ = manualBlackoutSession.enqueue(connection: second, control: .volume, normalizedValue: 0.6)
    manualBlackoutSession.restoreBrightnessVisibility(connection: first)
    manualBlackoutSession.cancelPendingCommands(preservingBlackScreens: true)
    check(manualBlackoutSession.blackedOutConnections == [second]
            && manualBlackoutSession.monitors.allSatisfy { $0.brightness.level == nil }
            && manualBlackoutSession.nextCommand() == nil
            && manualBlackoutSession.adjustBrightness(&manualBlackoutGroup, delta: -0.0625,
                                                      blackScreenBelowMinimum: true).isEmpty,
          "manual takeover cancels old commands and held intent while retaining another screen's applied blackout")
    _ = manualBlackoutSession.enqueueAfterReading(connection: first, control: .brightness, normalizedValue: 0.4)
    check(manualBlackoutSession.hasDeferredRequests && manualBlackoutSession.nextCommand() == nil
            && cancelledMinimumWrites.allSatisfy {
                !manualBlackoutSession.finish($0, outcome: .confirmed(.init(current: 0, maximum: 100)!))
            },
          "manual absolute intent waits for a real range and stale cancelled write completions stay rejected")
    _ = manualBlackoutSession.applyReading(.init(current: 0, maximum: 100)!, connection: second,
                                          control: .brightness, generation: manualBlackoutSession.generation)
    check(manualBlackoutSession.blackedOutConnections == [second]
            && manualBlackoutSession.monitors[1].brightness.level?.current == 0,
          "a cancelled minimum write's actual result rebases the preserved shade instead of mistaking it for external input")
    _ = manualBlackoutSession.applyReading(.init(current: 20, maximum: 200)!, connection: first,
                                          control: .brightness, generation: manualBlackoutSession.generation)
    let manualBlackoutCommand = manualBlackoutSession.nextCommand()!
    check(manualBlackoutCommand.connection == first && manualBlackoutCommand.value == 80
            && manualBlackoutCommand.maximum == 200 && manualBlackoutSession.nextCommand() == nil
            && manualBlackoutSession.monitors[0].brightness.level?.current == 20
            && manualBlackoutSession.blackedOutConnections == [second],
          "one manual request resumes with the freshly read range without waking or writing another black screen")
    _ = manualBlackoutSession.applyReading(.init(current: 0, maximum: 100)!, connection: second,
                                          control: .brightness, generation: manualBlackoutSession.generation)
    check(manualBlackoutSession.blackedOutConnections == [second],
          "polling after the cancellation rebase keeps an unchanged screen black")
    manualBlackoutSession.cancelPendingCommands()
    check(manualBlackoutSession.blackedOutConnections.isEmpty && manualBlackoutSession.nextCommand() == nil,
          "default cancellation restores all screens even after a selective manual takeover")

    // These bytes are protocol fixtures, not values generated by the codec under test.
    check(DDCVCP.readPacket(.brightness, transport: .i2c) == [0x51, 0x82, 0x01, 0x10, 0xac]
            && DDCVCP.readPacket(.brightness, transport: .ioAV) == [0x82, 0x01, 0x10, 0xfd],
          "I2C and IOAV Get VCP requests use their distinct source-address checksums")
    check(DDCVCP.writePacket(.volume, value: 37, transport: .i2c)
            == [0x51, 0x84, 0x03, 0x62, 0x00, 0x25, 0xff]
            && DDCVCP.writePacket(.volume, value: 37, transport: .ioAV)
            == [0x84, 0x03, 0x62, 0x00, 0x25, 0xff],
          "Set VCP requests retain both value bytes and include the source in either checksum")
    check(DDCVCP.writePacket(.brightness, value: 300, transport: .i2c)
            == [0x51, 0x84, 0x03, 0x10, 0x01, 0x2c, 0x85],
          "DDC writes preserve monitor ranges larger than a single byte")
    let reply: [UInt8] = [0x6e, 0x88, 0x02, 0x00, 0x10, 0x00, 0x00, 0x64, 0x00, 0x32, 0xf2]
    check(DDCVCP.parseReply(reply, control: .brightness) == .success(brightness),
          "a valid DDC reply confirms the actual current and maximum levels")
    check(DDCVCP.parseReply([0x6e, 0x88, 0x02, 0x00, 0x10, 0x00, 0x03, 0xe8, 0x01, 0x2c, 0x62],
                            control: .brightness) == .success(.init(current: 300, maximum: 1_000)!),
          "DDC reads use the monitor's full range rather than assuming one hundred")
    check(DDCVCP.parseReply(reply, control: .volume) == .failure(.malformed),
          "a reply for another VCP control cannot confirm the requested control")
    var unsupported = reply
    unsupported[3] = 0x01
    unsupported[10] = 0xf3
    check(DDCVCP.parseReply(unsupported, control: .brightness) == .failure(.unsupported),
          "the monitor's explicit unsupported reply differs from a communication failure")
    for (offset, value) in [(0, UInt8(0x6f)), (1, 0x87), (2, 0x03), (3, 0x02),
                            (5, 0x01), (7, 0x00), (9, 0x65)] {
        var malformed = reply
        malformed[offset] = value
        // Maintain a valid checksum so each malformed case reaches its intended protocol guard.
        malformed[10] = malformed.prefix(10).reduce(0x50, ^)
        check(DDCVCP.parseReply(malformed, control: .brightness) == .failure(.malformed),
              "DDC reply rejects malformed field \(offset) independently of its checksum")
    }
    for malformed in [Array(reply.dropLast()), reply + [0], Array(repeating: UInt8(0), count: 11),
                      Array(reply.dropLast()) + [0xf3]] {
        check(DDCVCP.parseReply(malformed, control: .brightness) == .failure(.malformed),
              "truncated, oversized, empty and corrupted DDC packets cannot confirm a level")
    }

    // The LS49AG95 returns the preceding Get VCP reply once after Set VCP. A successful write
    // from 75 to 74 must not be confirmed by its cached 75 reply, even with a valid checksum.
    let beforeWrite = DisplayControlLevel(current: 75, maximum: 100)!
    let afterWrite = DisplayControlLevel(current: 74, maximum: 100)!
    var readback = DDCVCPReadback()
    check(readback.accept(beforeWrite, control: .brightness) == beforeWrite,
          "ordinary detection reads are accepted without waiting for an unwritten level")
    readback.didWrite(.brightness)
    check(readback.accept(beforeWrite, control: .brightness) == nil
            && readback.accept(volume, control: .volume) == volume
            && readback.accept(afterWrite, control: .brightness) == afterWrite,
          "post-write DDC confirmation discards the cached reply without delaying another control")
    readback.didWrite(.brightness)
    check(readback.accept(afterWrite, control: .brightness) == nil
            && readback.accept(afterWrite, control: .brightness) == afterWrite,
          "each DDC write needs a fresh reply even when the monitor retains the same actual level")

    for (type, key) in [(0, DisplayMediaKey.volumeUp), (1, .volumeDown), (2, .brightnessUp),
                        (3, .brightnessDown), (7, .mute)] {
        let down = DisplayMediaKeyEvent(data1: type << 16 | 0x0a00)
        let repeatDown = DisplayMediaKeyEvent(data1: type << 16 | 0x0a01)
        let up = DisplayMediaKeyEvent(data1: type << 16 | 0x0b00)
        check(down?.key == key && down?.isDown == true && down?.isRepeat == false
                && repeatDown?.isRepeat == true && up?.key == key && up?.isDown == false,
              "media key \(type) retains down, repeat and up for shared input ownership")
    }
    for data1 in [21 << 16 | 0x0a00, 22 << 16 | 0x0a00, 16 << 16 | 0x0a00, 2 << 16 | 0x0c00] {
        check(DisplayMediaKeyEvent(data1: data1) == nil,
              "keyboard illumination, playback and invalid phases remain outside Display Control")
    }

    let shift: UInt64 = 1 << 17
    let control: UInt64 = 1 << 18
    let option: UInt64 = 1 << 19
    let commandModifier: UInt64 = 1 << 20
    for modifiers: UInt64 in [0, 1 << 16, 1 << 23, (1 << 23) | (1 << 16)] {
        check(DisplayMediaKeyAdjustment(modifierFlags: modifiers) == .standard,
              "Caps Lock and Fn do not disable ordinary display-key adjustment")
    }
    check(DisplayMediaKeyAdjustment(modifierFlags: shift | option) == .fine
            && DisplayMediaKeyAdjustment(modifierFlags: shift | option | (1 << 23)) == .fine,
          "Option Shift brightness and volume keys use fine adjustment, including Fn keyboards")
    for modifiers in [shift, option, control, commandModifier, shift | option | control,
                      shift | option | commandModifier, shift | option | control | commandModifier] {
        check(DisplayMediaKeyAdjustment(modifierFlags: modifiers) == nil,
              "system preference, Shift, Control and Hyperkey chords remain native")
    }
    var keyboardSession = DisplayControlSession()
    keyboardSession.start()
    keyboardSession.replaceDisplays([monitor("desk", first), monitor("side", second)])
    _ = keyboardSession.adjust(connection: first, control: .brightness,
                               delta: DisplayMediaKeyAdjustment.fine.step)
    _ = keyboardSession.adjust(connection: first, control: .brightness,
                               delta: DisplayMediaKeyAdjustment.fine.step)
    _ = keyboardSession.adjust(connection: second, control: .brightness,
                               delta: DisplayMediaKeyAdjustment.standard.step)
    check(keyboardSession.nextCommand()?.value == 54 && keyboardSession.nextCommand()?.value == 56
            && keyboardSession.monitors.allSatisfy { $0.brightness.level?.current == 50 },
          "fine held-key steps accumulate separately while confirmed monitor readings remain unchanged")

    var presses = DisplayMediaKeyPressState()
    var adjustments = 0
    let down = DisplayMediaKeyEvent(data1: 2 << 16 | 0x0a00)!
    let repeatedDown = DisplayMediaKeyEvent(data1: 2 << 16 | 0x0a01)!
    let up = DisplayMediaKeyEvent(data1: 2 << 16 | 0x0b00)!
    check(!presses.handle(repeatedDown) { _ in adjustments += 1; return true }
            && adjustments == 0 && !presses.handle(up) { _ in true },
          "enabling key handling during a held system key never steals its repeats or release")
    check(!presses.handle(down) { _ in false }
            && !presses.handle(up) { _ in true },
          "an unsupported initial key action leaves both phases with macOS")
    check(presses.handle(down) { _ in adjustments += 1; return true }
            && presses.handle(repeatedDown) { _ in adjustments += 1; return false }
            && presses.handle(up) { _ in false } && adjustments == 2,
          "a claimed repeat and release stay consumed when a later monitor adjustment fails")
    check(!presses.handle(up) { _ in true }, "a completed press cannot swallow a second release")
    let muteDown = DisplayMediaKeyEvent(data1: 7 << 16 | 0x0a00)!
    let muteRepeat = DisplayMediaKeyEvent(data1: 7 << 16 | 0x0a01)!
    check(presses.handle(muteDown) { _ in adjustments += 1; return true }
            && presses.handle(muteRepeat) { _ in adjustments += 1; return true }
            && adjustments == 3,
          "holding mute suppresses repeats without toggling the monitor repeatedly")
    _ = presses.handle(down) { _ in true }
    presses.release([.brightnessUp])
    check(!presses.handle(up) { _ in true }
            && presses.handle(DisplayMediaKeyEvent(data1: 7 << 16 | 0x0b00)!) { _ in true },
          "removing one key owner preserves another owner's claimed press")
    _ = presses.handle(down) { _ in true }
    presses.releaseAll()
    check(!presses.handle(repeatedDown) { _ in true } && !presses.handle(up) { _ in true },
          "tap shutdown discards pending key ownership")

    // The shared store owns generic atomic writes. This case owns only new tool integration.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("lineup-display-control-\(UUID())")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("config.json")
    let store = LineupAppConfigStore(url: url)
    _ = store.load()
    try store.setEnabled(true, for: .zones)
    try store.setEnabled(false, for: .displayControl)
    let legacySettings = try JSONDecoder().decode(DisplayControlSettings.self,
        from: Data(#"{"brightnessKeys":true,"monitors":{"desk":{"volumeKeys":false}}}"#.utf8))
    check(!DisplayControlSettings().blackScreenBelowMinimum && !legacySettings.blackScreenBelowMinimum,
          "fresh and existing configurations leave the visual blackout opt-in disabled")
    var legacySession = DisplayControlSession()
    legacySession.start()
    legacySession.replaceDisplays([monitor("desk", first), monitor("side", second)])
    let legacyReference = legacySession.target(legacySettings.brightnessTarget.map(DisplayControlTarget.display) ?? .pointer,
                                               pointerConnection: first)!
    let legacyLimits = [first: legacySettings.monitors["desk"]!.brightnessLimit]
    var legacyGroup = legacySession.brightnessGroup(reference: legacyReference.connection,
        synchronized: legacySettings.synchronizeBrightness, allowedConnections: [first, second],
        brightnessLimits: legacyLimits)!
    _ = legacySession.adjustBrightness(&legacyGroup, delta: 0.125, brightnessLimits: legacyLimits)
    check(legacySession.nextCommand()?.connection == first && legacySession.nextCommand() == nil,
          "existing settings keep pointer routing and individual brightness when sync and calibration are absent")
    var settings = try JSONDecoder().decode(DisplayControlSettings.self, from: Data(#"{"brightnessKeys":true,"brightnessTarget":"desk","monitors":{"desk":{"brightnessKeys":true,"volumeKeys":false,"brightnessLimit":0.6,"futureMonitor":"keep","futureCalibration":{"gamma":2.2}}},"futureTool":{"level":90}}"#.utf8))
    let maximumOnlyPreferences = settings.monitors["desk"]!
    check(DisplayBrightnessMath.hardwareLevel(logicalLevel: 0.5, brightnessLimit: maximumOnlyPreferences.brightnessLimit,
                                               brightnessMinimum: maximumOnlyPreferences.brightnessMinimum) == 0.3,
          "existing maximum-only calibration keeps a zero minimum instead of shifting its brightness")
    settings.monitors["desk"]?.brightnessKeys = false
    settings.monitors["desk"]?.brightnessMinimum = 0.1
    settings.monitors["desk"]?.brightnessLimit = 0.7
    settings.synchronizeBrightness = true
    settings.blackScreenBelowMinimum = true
    try store.setSettings(settings, for: .displayControl)
    let reread = LineupAppConfigStore(url: url)
    check(reread.load() == .loaded, "Display Control preferences reload through the existing store")
    check(try reread.config.settings(DisplayControlSettings.self, for: .displayControl) == settings
            && reread.config.isEnabled(.displayControl) == false && reread.config.isEnabled(.zones) == true,
          "per-monitor routing edits preserve saved selection, tool enablement and siblings")
    let json = reread.config.section(for: .displayControl)!.settings
    check(json["futureTool"]?["level"] == .int(90)
            && json["monitors"]?["desk"]?["futureMonitor"] == .string("keep")
            && json["monitors"]?["desk"]?["brightnessKeys"] == .bool(false)
            && json["monitors"]?["desk"]?["brightnessLimit"] == .number(0.7)
            && json["monitors"]?["desk"]?["brightnessMinimum"] == .number(0.1)
            && json["monitors"]?["desk"]?["futureCalibration"]?["gamma"] == .number(2.2)
            && json["blackScreenBelowMinimum"] == .bool(true)
            && json["blackedOutConnections"] == nil,
          "an edited sync limit preserves tool, monitor and calibration preferences from newer builds")
    for malformed in [#"{"synchronizeBrightness":"true"}"#,
                      #"{"blackScreenBelowMinimum":"true"}"#,
                      #"{"monitors":{"desk":{"brightnessLimit":0}}}"#,
                      #"{"monitors":{"desk":{"brightnessLimit":0.04}}}"#,
                      #"{"monitors":{"desk":{"brightnessLimit":1.01}}}"#,
                      #"{"monitors":{"desk":{"brightnessLimit":"50"}}}"#,
                      #"{"monitors":{"desk":{"brightnessMinimum":-0.01}}}"#,
                      #"{"monitors":{"desk":{"brightnessMinimum":0.8,"brightnessLimit":0.7}}}"#,
                      #"{"monitors":{"desk":{"brightnessMinimum":0.7,"brightnessLimit":0.7}}}"#,
                      #"{"monitors":{"desk":{"brightnessMinimum":"10"}}}"#] {
        var rejected = false
        do { _ = try JSONDecoder().decode(DisplayControlSettings.self, from: Data(malformed.utf8)) }
        catch { rejected = true }
        check(rejected, "invalid sync or calibration settings fail loading instead of applying a different brightness")
    }
    var rejectedSaves = 0
    for (minimum, maximum) in [(0.1, 0.0), (0.8, 0.7)] {
        var invalidSettings = settings
        invalidSettings.monitors["desk"]?.brightnessMinimum = minimum
        invalidSettings.monitors["desk"]?.brightnessLimit = maximum
        do { try store.setSettings(invalidSettings, for: .displayControl) }
        catch { rejectedSaves += 1 }
    }
    let afterRejectedSave = LineupAppConfigStore(url: url)
    _ = afterRejectedSave.load()
    let retainedSettings = try afterRejectedSave.config.settings(DisplayControlSettings.self, for: .displayControl)
    check(rejectedSaves == 2 && retainedSettings == settings,
          "invalid calibration writes preserve the previous valid preferences on disk")
}
