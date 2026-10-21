//
//  GtkDirectoryPickerTests.swift
//  WhiskyCrossUITests
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

#if os(Linux)
import Foundation
import Testing
@testable import WhiskyCrossUI

struct GtkDirectoryPickerTests {
    @MainActor @Test func cancelledRequestCompletesBeforeCreatingTheNativeDialog() async {
        let picker = GtkDirectoryPicker()
        let task = Task { await picker.chooseDirectory(initialDirectory: nil) }
        task.cancel()
        let result = await task.value
        #expect(result == nil)
    }
}
#endif
