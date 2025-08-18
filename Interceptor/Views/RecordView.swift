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

private struct DisclosureIndicator: View {
    @State private var isExpanded: Bool = true
    let label: () -> Text
    let items: [HTTP.Parameter]

    init(label: @escaping () -> Text, items: HTTP.Parameters) {
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

struct RecordView: View {
    let record: Record
    @State private var isExpanded: Bool = true
    @State private var selection: Int = 0

    @ViewBuilder
    var RequestView: some View {
        List(content: {
            DisclosureIndicator(label: {
                Text("LABEL_RECORD_HEADER")
                    .font(.title2)
                    .fontWeight(.bold)
            }, items: record.request.headers)
                .listRowSeparator(.hidden)
            if !record.queries.isEmpty {
                DisclosureIndicator(label: {
                    Text("LABEL_RECORD_QUERY")
                        .font(.title2)
                        .fontWeight(.bold)
                }, items: record.queries)
                    .listRowSeparator(.hidden)
            }
            if !record.cookies.isEmpty {
                DisclosureIndicator(label: {
                    Text("LABEL_RECORD_COOKIE")
                        .font(.title2)
                        .fontWeight(.bold)
                }, items: record.cookies)
                    .listRowSeparator(.hidden)
            }
            if let json = record.request.json {
                NavigationLink(destination: {
                    CodeView(text: json, language: .json)
                }, label: {
                    Text("LABEL_RECORD_BODY")
                        .font(.title2)
                        .fontWeight(.bold)
                })
                .listRowSeparator(.hidden)
            }
        })
        .tag(0)
    }

    @ViewBuilder
    var ResponseView: some View {
        List(content: {
            DisclosureIndicator(label: {
                Text("LABEL_RECORD_HEADER")
                    .font(.title2)
                    .fontWeight(.bold)
            }, items: record.response.headers)
                .listRowSeparator(.hidden)
            if !record.response.cookies.isEmpty {
                DisclosureIndicator(label: {
                    Text("LABEL_RECORD_SET_COOKIE")
                        .font(.title2)
                        .fontWeight(.bold)
                }, items: record.response.cookies)
                    .listRowSeparator(.hidden)
            }
            if let json = record.response.json {
                NavigationLink(destination: {
                    CodeView(text: json, language: .json)
                }, label: {
                    Text("LABEL_RECORD_BODY")
                        .font(.title2)
                        .fontWeight(.bold)
                })
                .listRowSeparator(.hidden)
            }
        })
        .tag(1)
    }

    @ViewBuilder
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
