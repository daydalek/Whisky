//
//  ManagedInstallScopeTrait.swift
//  WhiskyKitTests
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
@testable import WhiskyKit

/// Suite/test trait that resolves the managed engine as installed for the
/// duration of a test — the task-local ``WineEngine/scopedManagedInstallOverride``
/// seam, NOT the process-global ``WineEngine/managedInstallOverride`` a
/// parallel suite could reset out from under another test's async operation.
struct ManagedInstallScopeTrait: TestTrait, SuiteTrait, TestScoping {
    var isRecursive: Bool {
        true
    }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        self
    }

    func provideScope(
        for test: Test,
        testCase: Test.Case?,
        performing function: @Sendable () async throws -> Void
    ) async throws {
        try await WineEngine.$scopedManagedInstallOverride.withValue(true) {
            try await function()
        }
    }
}

extension Trait where Self == ManagedInstallScopeTrait {
    /// The managed engine resolves as installed inside this test or suite.
    static var managedInstalled: Self {
        Self()
    }
}

@Suite("Managed install task-local seam")
struct ScopedManagedInstallTests {
    /// Two concurrent `.withValue` scopes must see their own availability —
    /// the flag a parallel suite holds can never leak or reset mid-test.
    @Test func concurrentScopesSeeIsolatedAvailability() async throws {
        async let installed: Bool = WineEngine.$scopedManagedInstallOverride
            .withValue(true) {
                try await Task.sleep(for: .milliseconds(5))
                return WineEngine.managed.availabilityError == nil
            }
        async let missing: Bool = WineEngine.$scopedManagedInstallOverride
            .withValue(false) {
                try await Task.sleep(for: .milliseconds(5))
                return WineEngine.managed.availabilityError == nil
            }
        #expect(try await installed)
        #expect(try await !missing)
        // After the scope the task-local is gone — nothing leaks outward.
        #expect(WineEngine.scopedManagedInstallOverride == nil)
    }

    /// The trait itself: inside this test the managed engine is available.
    @Test(.managedInstalled) func traitResolvesManagedAsInstalled() {
        #expect(WineEngine.managed.availabilityError == nil)
    }
}
