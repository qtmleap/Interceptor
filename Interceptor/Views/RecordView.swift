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

struct RecordView: View {
    let record: Record
    @State private var isExpanded: Bool = true
    @State private var selection: Int = 0

    @ViewBuilder
    var RequestView: some View {
        List(content: {
            DisclosureGroup(isExpanded: $isExpanded, content: {
                ForEach(record.request.headers, id: \.self, content: { header in
                    VStack(alignment: .leading, content: {
                        Text(header.key)
                        Text(header.value)
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    })
                    .padding(0)
                })
                .listRowSeparator(.visible)
            }, label: {
                Text("LABEL_RECORD_HEADER")
                    .font(.title2)
                    .fontWeight(.bold)
            })
            .listRowSeparator(.hidden)
            if let body = record.request.body {
                NavigationLink(destination: {
                    CodeView(text: body)
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
            DisclosureGroup(isExpanded: $isExpanded, content: {
                ForEach(record.response.headers, id: \.self, content: { header in
                    VStack(alignment: .leading, content: {
                        Text(header.key)
                        Text(header.value)
                            .foregroundStyle(.secondary)
                            .font(.footnote)
                    })
                    .padding(0)
                })
                .listRowSeparator(.visible)
            }, label: {
                Text("LABEL_RECORD_HEADER")
                    .font(.title2)
                    .fontWeight(.bold)
            })
            .listRowSeparator(.hidden)
            if let body = record.response.body {
                NavigationLink(destination: {
                    CodeView(text: body)
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

    var body: some View {
        TabView(selection: $selection, content: {
            RequestView
            ResponseView
        })
        .toolbar(content: {
            ToolbarItem(placement: .navigation, content: {
                Picker(selection: $selection, content: {
                    Text("LABEL_RECORD_REQUEST")
                        .tag(0)
                    Text("LABEL_RECORD_RESPONSE")
                        .tag(1)
                }, label: {
                    Text("LABEL_RECORD_REQUEST")
                })
                .pickerStyle(.segmented)
                // NOTE: これを書くと表示がバグるので一旦何もしない
                .introspect(.picker(style: .segmented), on: .iOS(.v17...), customize: { control in
                    control.selectedSegmentTintColor = .systemBlue
                })
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
