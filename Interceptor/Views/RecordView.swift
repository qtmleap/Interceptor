//
//  RecordView.swift
//  Interceptor
//
//  Created by devonly on 2025/08/16.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import CodeViewer
import Mudmouth
import SwiftUI

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
                    CodeViewer(content: .constant(body), mode: .json, isReadOnly: true)
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
                    CodeViewer(content: .constant(body), mode: .json, isReadOnly: true)
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
        VStack(content: {
            HStack(content: {
                Button(action: {
                    withAnimation(.spring) {
                        selection = 0
                    }
                }, label: {
                    Text("LABEL_RECORD_REQUEST")
                })
                .foregroundStyle(selection == 0 ? .blue : .secondary)
                .fontWeight(.semibold)
                Button(action: {
                    withAnimation(.spring) {
                        selection = 1
                    }
                }, label: {
                    Text("LABEL_RECORD_RESPONSE")
                })
                .foregroundStyle(selection == 1 ? .blue : .secondary)
                .fontWeight(.semibold)
            })
            TabView(selection: $selection, content: {
                RequestView
                ResponseView
            })
            .tabViewStyle(.page(indexDisplayMode: .never))
            .listStyle(.plain)
        })
        .navigationTitle(record.path)
        .navigationBarTitleDisplayMode(.inline)
    }
}

#Preview {
    HomeView()
}
