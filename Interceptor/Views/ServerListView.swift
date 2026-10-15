//
//  ServerListView.swift
//  Interceptor
//
//  Created by devonly on 2025/08/21.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import Mudmouth
import SwiftUI
@_spi(Advanced) import SwiftUIIntrospect

struct ServerListView: View {
    @EnvironmentObject private var tuberose: Tuberose

    var body: some View {
        SSLProxyingListView(store: tuberose.store)
    }
}

private struct SSLProxyingListView: View {
    /// Identity stays stable while a host is renamed.
    private struct Draft: Identifiable {
        let id = UUID()
        var original: String?
    }

    @ObservedObject var store: SSLProxyingListStore
    @State private var draft: Draft?
    @State private var confirmReset = false

    var body: some View {
        List {
            if let error = store.loadError {
                Section {
                    Text(error == .corrupt
                         ? LocalizedStringKey("SSL_LIST_ERROR_CORRUPT")
                         : LocalizedStringKey("SSL_LIST_ERROR_VERSION"))
                    Button("Reset List", role: .destructive) { confirmReset = true }
                        .accessibilityIdentifier("ssl.reset")
                }
            } else if store.options.isEmpty {
                Section {
                    Text("SSL_LIST_EMPTY")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                ForEach(store.options) { option in
                    Button(action: { draft = .init(original: option.host) }, label: {
                        Text(option.host)
                            .foregroundStyle(Color.primary)
                    })
                    .accessibilityIdentifier("ssl.row.\(option.host)")
                }
                .onMove(perform: store.move)
                .onDelete(perform: store.delete)
            } header: {
                HStack {
                    Text("Hosts")
                        .accessibilityAddTraits(.isHeader)
                    Spacer()
                    sortMenu
                }
                .textCase(nil)
            } footer: {
                Text("SSL_LIST_FOOTER")
            }
        }
        .navigationTitle(Text("TITLE_SERVER_LIST"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                EditButton()
                    .accessibilityIdentifier("ssl.edit")
                Button(action: { draft = .init() }, label: {
                    Label("Add Host", systemImage: "plus")
                })
                .disabled(store.loadError != nil)
                .accessibilityIdentifier("ssl.add")
            }
        }
        .sheet(item: $draft) { draft in
            HostEditorView(store: store, original: draft.original)
        }
        .alert("Reset List?", isPresented: $confirmReset) {
            Button("Reset List", role: .destructive) { store.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("SSL_LIST_RESET_CONFIRMATION")
        }
        .tint(Color(uiColor: .systemBlue))
    }

    private var sortMenu: some View {
        Menu {
            Button("Host Name (A–Z)") { store.sort(ascending: true) }
            Button("Host Name (Z–A)") { store.sort(ascending: false) }
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
                .frame(minWidth: 44, minHeight: 44)
        }
        .disabled(store.loadError != nil || store.options.count < 2)
        .accessibilityIdentifier("ssl.sort")
    }
}

private struct HostEditorView: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject var store: SSLProxyingListStore
    let original: String?
    @State private var text: String
    @State private var saveError: String?

    init(store: SSLProxyingListStore, original: String?) {
        self.store = store
        self.original = original
        _text = State(initialValue: original ?? "")
    }

    private var result: Result<String, CaptureHostList.HostError> {
        store.validate(text, replacing: original)
    }

    private var errorMessage: LocalizedStringKey? {
        guard case let .failure(error) = result else { return nil }
        switch error {
            case .empty, .notFound: return nil
            case .invalid: return "SSL_HOST_ERROR_INVALID"
            case .duplicate: return "SSL_HOST_ERROR_DUPLICATE"
            case .unavailable: return "SSL_HOST_ERROR_UNAVAILABLE"
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("example.com", text: $text)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .accessibilityLabel(Text("Host"))
                        .accessibilityIdentifier("ssl.host")
                } header: {
                    Text("Host")
                } footer: {
                    if let saveError {
                        Text(saveError).foregroundStyle(.red)
                    } else if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .accessibilityIdentifier("ssl.error")
                    } else {
                        Text("SSL_HOST_HELP")
                    }
                }
            }
            .onChange(of: text) { saveError = nil }
            .navigationTitle(original == nil ? Text("Add Host") : Text("Edit Host"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                        .accessibilityIdentifier("ssl.cancel")
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled((try? result.get()) == nil)
                        .accessibilityIdentifier("ssl.save")
                }
            }
        }
    }

    private func save() {
        do {
            if let original {
                try store.rename(original, to: text)
            } else {
                try store.add(text)
            }
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}

#Preview {
    NavigationView(content: {
        ServerListView()
    })
    .environmentObject(Tuberose.default)
    .introspect(.navigationSplitView, on: .iOS(.v17...), customize: { controller in
        controller.preferredDisplayMode = .oneBesideSecondary
        controller.preferredSplitBehavior = .displace
        controller.presentsWithGesture = false
    })
}
