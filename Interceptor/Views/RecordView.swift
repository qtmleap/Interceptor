//
//  RecordView.swift
//  Interceptor
//
//  Created by devonly on 2025/08/16.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import Mudmouth
import SwiftUI
@_spi(Advanced) import SwiftUIIntrospect
import TreeSitterJSONRunestone

private struct DisclosureIndicator<Label: View>: View {
    @State private var isExpanded: Bool = true
    let label: () -> Label
    let items: [HTTP.Parameter]

    init(label: @escaping () -> Label, items: HTTP.Parameters) {
        self.label = label
        self.items = items.values
    }

    var body: some View {
        DisclosureGroup(isExpanded: $isExpanded, content: {
            ForEach(items, id: \.self, content: { item in
                VStack(alignment: .leading, content: {
                    Text(item.key)
                    Text(item.value)
                        .textSelection(.enabled)
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                })
                .padding(0)
            })
            .listRowSeparator(.visible)
        }, label: {
            label()
        })
    }
}

/// Read-only context: the full path wraps and stays selectable instead of being truncated.
private struct SummaryRow: View {
    let title: String
    let path: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4, content: {
            Text(title)
                .font(.headline)
            Text(path)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        })
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SectionTitle: View {
    let key: LocalizedStringKey

    init(_ key: LocalizedStringKey) {
        self.key = key
    }

    var body: some View {
        Text(key)
            .font(.headline)
            .accessibilityAddTraits(.isHeader)
    }
}

struct RecordView: View {
    let record: Record
    @State private var isExpanded: Bool = true
    @State private var selection: Int = 0

    var RequestView: some View {
        List(content: {
            SummaryRow(title: record.method, path: record.path)
                .listRowSeparator(.hidden)
            DisclosureIndicator(label: {
                SectionTitle("LABEL_RECORD_HEADER")
            }, items: record.request.headers)
                .listRowSeparator(.hidden)
            if !record.queries.isEmpty {
                DisclosureIndicator(label: {
                    SectionTitle("LABEL_RECORD_QUERY")
                }, items: record.queries)
                    .listRowSeparator(.hidden)
            }
            if !record.cookies.isEmpty {
                DisclosureIndicator(label: {
                    SectionTitle("LABEL_RECORD_COOKIE")
                }, items: record.cookies)
                    .listRowSeparator(.hidden)
            }
            if let json = record.request.json {
                NavigationLink(destination: {
                    CodeView(text: json, language: .json)
                        .navigationTitle("LABEL_REQUEST_BODY")
                        .navigationBarTitleDisplayMode(.inline)
                }, label: {
                    SectionTitle("LABEL_RECORD_BODY")
                })
                .listRowSeparator(.hidden)
            }
        })
        .tag(0)
    }

    var ResponseView: some View {
        List(content: {
            SummaryRow(title: "\(record.code) \(record.phrase)", path: record.path)
                .listRowSeparator(.hidden)
            DisclosureIndicator(label: {
                SectionTitle("LABEL_RECORD_HEADER")
            }, items: record.response.headers)
                .listRowSeparator(.hidden)
            if !record.response.cookies.isEmpty {
                DisclosureIndicator(label: {
                    SectionTitle("LABEL_RECORD_SET_COOKIE")
                }, items: record.response.cookies)
                    .listRowSeparator(.hidden)
            }
            if let json = record.response.json {
                NavigationLink(destination: {
                    CodeView(text: json, language: .json)
                        .navigationTitle("LABEL_RESPONSE_BODY")
                        .navigationBarTitleDisplayMode(.inline)
                }, label: {
                    SectionTitle("LABEL_RECORD_BODY")
                })
                .listRowSeparator(.hidden)
            }
        })
        .tag(1)
    }

    var SegmentControl: some View {
        Picker(selection: $selection, content: {
            Text("LABEL_RECORD_REQUEST")
                .tag(0)
            Text("LABEL_RECORD_RESPONSE")
                .tag(1)
        }, label: {
            Text("LABEL_RECORD_REQUEST")
        })
        .pickerStyle(.segmented)
        // 有効化すると最初の表示が表示されないかつNavigationLinkで遷移できなくなる
        //        .introspect(.picker(style: .segmented), on: .iOS(.v17...), customize: { controller in
        //            controller.selectedSegmentTintColor = .systemBlue
        //        })
    }

    var body: some View {
        TabView(selection: $selection, content: {
            RequestView
            ResponseView
        })
        .toolbar(content: {
            ToolbarItem(placement: .navigation, content: {
                SegmentControl
            })
        })
        .tabViewStyle(.page(indexDisplayMode: .never))
        .listStyle(.plain)
        //        .navigationTitle(record.path)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    NavigationView(content: {
        RecordsView(group: .init())
    })
    .introspect(.navigationSplitView, on: .iOS(.v17...), customize: { controller in
        controller.preferredDisplayMode = .oneBesideSecondary
        controller.preferredSplitBehavior = .displace
        controller.presentsWithGesture = false
    })
}
