//
//  LibraryRuntimeTests.swift
//  WhiskyCore
//
//  This file is part of Whisky.
//
//  Whisky is free software: you can redistribute it and/or modify it under the terms
//  of the GNU General Public License as published by the Free Software Foundation,
//  either version 3 of the License, or (at your option) any later version.
//
//  Whisky is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY;
//  without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.
//  See the GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License along with Whisky.
//  If not, see https://www.gnu.org/licenses/.
//

import Foundation
import Testing
@testable import WhiskyCore

@MainActor
private final class RuntimeProbe: LibraryRuntimeDriver {
    var snapshot = LibraryRuntimeDriverSnapshot()
    let channel = RuntimeEventChannel<LibraryRuntimeDriverEvent>()
    struct Attempt {
        let request: LibraryLaunchRequest
        let started: @MainActor () -> Void
        var completion: CheckedContinuation<LaunchResult, Never>?
    }

    var attempts: [Attempt] = []
    var started: [LibraryLaunchRequest] = []
    var steamLaunches: [LibraryEntry] = []
    var steamCancellations: [LibraryEntry] = []
    var stops: [LibraryEntry] = []
    var retained: Set<URL> = []
    var trackingStopped = false
    func events() -> AsyncStream<LibraryRuntimeDriverEvent> {
        channel.stream(replaying: [.changed(snapshot)])
    }

    func capabilities(for entry: LibraryEntry)
        -> LibraryRuntimeCapabilities {
        [.launch, .cancelLaunch, .terminal, .stop]
    }

    func retainContainers(_ urls: Set<URL>) {
        retained = urls
    }

    func configure(entries: [LibraryEntry], containerURL: URL) async {}
    func launchProgram(
        _ request: LibraryLaunchRequest, onStarted: @escaping @MainActor () -> Void
    ) async -> LaunchResult {
        await withCheckedContinuation { attempts.append(Attempt(request: request, started: onStarted, completion: $0)) }
    }

    func programDidStart(_ request: LibraryLaunchRequest) {
        started.append(request)
    }

    func launchSteam(_ entry: LibraryEntry) {
        steamLaunches.append(entry)
    }

    func cancelSteamLaunch(_ entry: LibraryEntry) {
        steamCancellations.append(entry)
    }

    func stop(_ entry: LibraryEntry) async {
        stops.append(entry)
    }

    func stopTracking() {
        trackingStopped = true
    }

    func publish() {
        snapshot.revision &+= 1
        channel.send(.changed(snapshot))
    }

    func finish(_ index: Int, result: LaunchResult? = nil) {
        let continuation = attempts[index].completion
        attempts[index].completion = nil
        continuation?
            .resume(returning: result ?? .launchedSuccessfully(programName: attempts[index].request.entry.name))
    }

    func finishAll() {
        for index in attempts.indices {
            finish(index)
        }
    }
}

private actor RuntimeSleeper {
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { waiters[id] = $0 }
        } onCancel: { Task { await self.cancel(id) } }
    }

    private func cancel(_ id: UUID) {
        waiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    var count: Int {
        waiters.count
    }

    func fire() {
        let waiting = waiters
        waiters.removeAll()
        for waiter in waiting.values {
            waiter.resume()
        }
    }
}

@Suite("Portable runtime lifecycle")
@MainActor
struct LibraryRuntimeTests {
    private func entry(_ id: String = "game", steam: Bool = false) -> LibraryEntry {
        let bottle = URL(fileURLWithPath: "/prefix")
        return LibraryEntry(
            id: id,
            name: id,
            iconURL: nil,
            bottleURL: bottle,
            source: steam ? .steam : .pinned,
            launch: steam ? .steam(appID: 42) : .program(bottle.appendingPathComponent("game.exe"))
        )
    }

    private func settle(_ condition: @MainActor () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(10)
        while !condition(), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(condition())
    }

    @Test func launchRequestDeliveryProcessConfirmationAndExitAreSeparateEvents() async {
        let driver = RuntimeProbe()
        defer { driver.finishAll() }
        let runtime = LibraryRuntimeController(driver: driver)
        let game = entry()
        let stream = runtime.events()
        var received: [LibraryRuntimeEvent] = []
        let consumer = Task { for await event in stream {
            received.append(event)
        } }
        defer { consumer.cancel() }
        runtime.launch(LibraryLaunchRequest(entry: game, mode: .terminal))
        runtime.launch(LibraryLaunchRequest(entry: game))
        await settle { driver.attempts.count == 1 }
        #expect(driver.attempts[0].request.mode == .terminal)
        #expect(runtime.state.launch.state(for: game) == .preparing)
        driver.attempts[0].started()
        #expect(runtime.state.launch.state(for: game) == .launching)
        #expect(driver.started.count == 1)
        driver.finish(0)
        await settle { received.contains(.launchResult(
            entryID: game.id,
            result: .launchedSuccessfully(programName: game.name)
        )) }
        #expect(runtime.state.launch.state(for: game) == .launching)
        driver.snapshot.observation = GameActivityObservation(runningEntryIDs: [game.id], revision: 1)
        driver.publish()
        await settle { runtime.state.launch.state(for: game) == .running }
        let completed = Date(timeIntervalSince1970: 100)
        driver.snapshot.observation = GameActivityObservation(
            endedEntryIDs: [game.id],
            revision: 2,
            completedAt: [game.id: completed]
        )
        driver.publish()
        await settle { runtime.state.launch.state(for: game) == .idle }
        #expect(runtime.state.observation.completedAt[game.id] == completed)
    }

    @Test func timeoutRejectsLateStartAndLateResultFromPriorAttempt() async {
        let driver = RuntimeProbe()
        defer { driver.finishAll() }
        let sleeper = RuntimeSleeper()
        let runtime = LibraryRuntimeController(driver: driver, sleep: { try await sleeper.sleep($0) })
        let game = entry()
        var received: [LibraryRuntimeEvent] = []
        let stream = runtime.events()
        let consumer = Task { for await event in stream {
            received.append(event)
        } }
        defer { consumer.cancel() }
        runtime.launch(LibraryLaunchRequest(entry: game))
        await settle { driver.attempts.count == 1 }
        let deadline = ContinuousClock.now + .seconds(10)
        while await sleeper.count == 0, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(1))
        }
        #expect(await sleeper.count > 0)
        await sleeper.fire()
        await settle { runtime.state.launch.state(for: game) == .idle }
        await settle { received.contains(.failure(.launchTimedOut(entryID: game.id, queryError: nil))) }
        runtime.launch(LibraryLaunchRequest(entry: game))
        await settle { driver.attempts.count == 2 }
        driver.attempts[0].started()
        driver.finish(0, result: .launchFailed(programName: game.name, errorDescription: "late error"))
        await Task.yield()
        #expect(runtime.state.launch.state(for: game) == .preparing)
        #expect(driver.started.isEmpty)
        driver.attempts[1].started()
        #expect(runtime.state.launch.state(for: game) == .launching)
        #expect(driver.started.count == 1)
        driver.finish(1)
        await settle { received.contains(.launchResult(
            entryID: game.id,
            result: .launchedSuccessfully(programName: game.name)
        )) }
        #expect(!received.contains(.launchResult(
            entryID: game.id,
            result: .launchFailed(
                programName: game.name,
                errorDescription: "late error"
            )
        )))
    }

    @Test func queryFailurePreservesRunningStateAndPriorExitAllowsRelaunch() async {
        let driver = RuntimeProbe()
        defer { driver.finishAll() }
        let game = entry()
        driver.snapshot.observation = GameActivityObservation(endedEntryIDs: [game.id], revision: 1)
        let runtime = LibraryRuntimeController(driver: driver)
        runtime.launch(LibraryLaunchRequest(entry: game))
        await settle { driver.attempts.count == 1 }
        driver.snapshot.queryFailures = [game.bottleURL: "probe unavailable"]
        driver.publish()
        await settle { !runtime.state.queryFailures.isEmpty }
        #expect(runtime.state.launch.state(for: game) == .preparing)
        driver.attempts[0].started()
        #expect(runtime.state.launch.state(for: game) == .checkingLaunch)
        driver.snapshot.observation = GameActivityObservation(runningEntryIDs: [game.id], revision: 2)
        driver.publish()
        await settle { runtime.state.launch.state(for: game) == .running }
        driver.snapshot.queryFailures[game.bottleURL] = "another failed query"
        driver.publish()
        await settle { runtime.state.queryFailures[game.bottleURL] == "another failed query" }
        #expect(runtime.state.launch.state(for: game) == .running)
    }

    @Test func removedContainersAndCancellationInvalidatePendingLaunches() async {
        let driver = RuntimeProbe()
        defer { driver.finishAll() }
        let runtime = LibraryRuntimeController(driver: driver)
        let game = entry()
        runtime.launch(LibraryLaunchRequest(entry: game))
        await settle { driver.attempts.count == 1 }
        runtime.retainContainers([])
        driver.attempts[0].started()
        #expect(runtime.state.launch.state(for: game) == .idle)
        #expect(driver.started.isEmpty)
        runtime.launch(LibraryLaunchRequest(entry: game))
        await settle { driver.attempts.count == 2 }
        runtime.cancelLaunch(for: game)
        driver.attempts[1].started()
        #expect(runtime.state.launch.state(for: game) == .idle)
        #expect(driver.started.isEmpty)
    }

    @Test func independentConsumersReplayStateAndReceiveSameCompletions() async {
        let driver = RuntimeProbe()
        let runtime = LibraryRuntimeController(driver: driver)
        let game = entry(steam: true)
        var first = runtime.events().makeAsyncIterator()
        var second = runtime.events().makeAsyncIterator()
        #expect(await first.next() == .state(runtime.state))
        #expect(await second.next() == .state(runtime.state))
        driver.snapshot.steamRunning = [game.bottleURL: [42]]
        driver.publish()
        let one = await first.next()
        let two = await second.next()
        #expect(one == two)
        #expect(runtime.state.launch.state(for: game) == .running)
        runtime.cancelLaunch(for: game)
        await runtime.stop(game)
        runtime.stopTracking()
        #expect(driver.steamCancellations == [game])
        #expect(driver.stops == [game])
        #expect(driver.trackingStopped)
    }

    @Test func staleReplayCannotOverwriteObservedProcessesAndUnavailableRuntimeDeclaresCapabilities() async {
        let driver = RuntimeProbe()
        let runtime = LibraryRuntimeController(driver: driver)
        let game = entry()
        driver.snapshot.revision = 2
        driver.snapshot.observation = GameActivityObservation(runningEntryIDs: [game.id], revision: 1)
        runtime.launch(LibraryLaunchRequest(entry: game))
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(runtime.state.launch.state(for: game) == .running)
        #expect(driver.attempts.isEmpty)
        let unavailable = LibraryRuntimeController(driver: UnavailableLibraryRuntimeDriver())
        #expect(unavailable.capabilities(for: game).isEmpty)
        var events = unavailable.events().makeAsyncIterator()
        _ = await events.next()
        unavailable.launch(LibraryLaunchRequest(entry: game))
        #expect(await events.next() == .failure(.unavailable(entryID: game.id)))
    }

    @Test func processConfirmationCancelsDeadlineAndLateCommandFailureKeepsRunningState() async {
        let driver = RuntimeProbe()
        defer { driver.finishAll() }
        let sleeper = RuntimeSleeper()
        let runtime = LibraryRuntimeController(driver: driver, sleep: { try await sleeper.sleep($0) })
        let game = entry()
        runtime.launch(LibraryLaunchRequest(entry: game))
        await settle { driver.attempts.count == 1 }
        driver.attempts[0].started()
        driver.snapshot.observation = GameActivityObservation(runningEntryIDs: [game.id], revision: 1)
        driver.publish()
        await settle { runtime.state.launch.state(for: game) == .running }
        await sleeper.fire()
        driver.finish(0, result: .launchFailed(programName: game.name, errorDescription: "late command failure"))
        for _ in 0 ..< 10 {
            await Task.yield()
        }
        #expect(runtime.state.launch.state(for: game) == .running)
        runtime.cancelLaunch(for: game)
        #expect(runtime.state.launch.state(for: game) == .running)
    }

    @Test func retiringAContainerPublishesClearedStateToItsConsumer() async {
        let driver = RuntimeProbe()
        defer { driver.finishAll() }
        let runtime = LibraryRuntimeController(driver: driver)
        var events = runtime.events().makeAsyncIterator()
        _ = await events.next()
        let game = entry()
        runtime.launch(LibraryLaunchRequest(entry: game))
        _ = await events.next()
        runtime.retainContainers([])
        #expect(await events.next() == .state(runtime.state))
        #expect(runtime.state.launch.state(for: game) == .idle)
    }

    @Test func cancellingOneEventConsumerPreservesOtherConsumers() async {
        let channel = RuntimeEventChannel<Int>()
        let firstStream = channel.stream()
        let first = Task { for await _ in firstStream {} }
        var second = channel.stream().makeAsyncIterator()
        first.cancel()
        await first.value
        channel.send(42)
        #expect(await second.next() == 42)
        channel.finish()
        #expect(await second.next() == nil)
    }

    @Test func frontendSubscriptionCanEndWhileAnApplicationOwnedLaunchContinues() async {
        let driver = RuntimeProbe()
        defer { driver.finishAll() }
        let runtime = LibraryRuntimeController(driver: driver)
        let stream = runtime.events()
        let consumer = Task { for await _ in stream {} }
        let game = entry()
        runtime.launch(LibraryLaunchRequest(entry: game))
        await settle { driver.attempts.count == 1 }
        consumer.cancel()
        await consumer.value
        driver.attempts[0].started()
        #expect(driver.started.count == 1)
        #expect(runtime.state.launch.state(for: game) == .launching)
        var returningFrontend = runtime.events().makeAsyncIterator()
        #expect(await returningFrontend.next() == .state(runtime.state))
        driver.snapshot.observation = GameActivityObservation(runningEntryIDs: [game.id], revision: 1)
        driver.publish()
        _ = await returningFrontend.next()
        #expect(runtime.state.launch.state(for: game) == .running)
    }
}
