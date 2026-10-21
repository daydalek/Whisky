//
//  GtkDirectoryPicker.swift
//  WhiskyCrossUI
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
import CGtk
import Foundation
import Gtk
import WhiskyCore

/// The Gtk host selects the folder action explicitly for library directory requests.
@MainActor
final class GtkDirectoryPicker: DirectoryPicking {
    private struct Request {
        let id: UUID
        let chooser: Gtk.FileChooserNative
        let continuation: CheckedContinuation<URL?, Never>
    }

    private var active: Request?

    func chooseDirectory(initialDirectory: URL?) async -> URL? {
        guard active == nil else { return nil }
        let id = UUID()
        return await withTaskCancellationHandler {
            guard !Task.isCancelled else { return nil }
            return await withCheckedContinuation { continuation in
                let parent = g_application_get_default().flatMap {
                    gtk_application_get_active_window(UnsafeMutableRawPointer($0)
                        .assumingMemoryBound(to: GtkApplication.self))
                }
                let chooser = Gtk.FileChooserNative(
                    title: "选择包含游戏文件夹的目录", parent: parent,
                    action: Gtk.FileChooserAction.selectFolder.toGtk(), acceptLabel: "Select", cancelLabel: "Cancel"
                )
                // The Swift wrapper retains the dialog; balance the constructor's owned reference.
                g_object_unref(chooser.gobjectPointer)
                chooser.modal = true
                chooser.selectMultiple = false
                if let initialDirectory {
                    chooser.setCurrentFolder(initialDirectory)
                }
                chooser.registerSignals()
                active = Request(id: id, chooser: chooser, continuation: continuation)
                chooser.response = { [weak self] _, response in
                    self?.respond(to: id, response: Int32(truncatingIfNeeded: response))
                }
                gtk_native_dialog_show(nativeDialog(chooser))
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(id, with: nil) }
        }
    }

    private func respond(to id: UUID, response: Int32) {
        guard let active, active.id == id else { return }
        guard response == Gtk.ResponseType.accept.toGtk().rawValue,
              let file = gtk_file_chooser_get_file(OpaquePointer(active.chooser.gobjectPointer))
        else { finish(id, with: nil)
            return
        }
        defer { g_object_unref(UnsafeMutableRawPointer(file)) }
        let url = g_file_get_path(file).map { path in
            defer { g_free(UnsafeMutableRawPointer(path)) }
            return URL(fileURLWithPath: String(cString: path), isDirectory: true)
        }
        finish(id, with: url)
    }

    private func finish(_ id: UUID, with url: URL?) {
        guard let request = active, request.id == id else { return }
        active = nil
        request.chooser.response = nil
        gtk_native_dialog_hide(nativeDialog(request.chooser))
        request.continuation.resume(returning: url)
    }

    private func nativeDialog(_ chooser: Gtk.FileChooserNative) -> UnsafeMutablePointer<GtkNativeDialog> {
        UnsafeMutableRawPointer(chooser.gobjectPointer).assumingMemoryBound(to: GtkNativeDialog.self)
    }
}
#endif
