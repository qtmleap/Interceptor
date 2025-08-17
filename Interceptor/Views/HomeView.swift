//
//  HomeView.swift
//  Interceptor
//
//  Created by devonly on 2025/08/16.
//  Copyright © 2025 QuantumLeap. All rights reserved.
//

import CoreData
import Mudmouth
import SwiftData
import SwiftUI
import SwiftyLogger

struct HomeView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: \RecordGroup.host, order: .forward) private var groups: [RecordGroup]
    @State private var isPresented: Bool = false

    var body: some View {
        List(content: {
            ForEach(groups, content: { group in
                NavigationLink(destination: {
                    RecordsView(group: group)
                }, label: {
                    HStack(content: {
                        Label(title: {
                            HStack(content: {
                                Text(group.host)
                                    .lineLimit(1)
                                    .truncationMode(.tail)
                                Text(group.records.count, format: .number)
                                    .foregroundStyle(.secondary)
                            })
                        }, icon: {
                            Image(systemName: "folder.fill")
                        })
                    })
                })
                .isDetailLink(false)
            })
        })
        .onAppear(perform: {
            print(groups.count)
        })
        .listStyle(.plain)
        .navigationTitle(Text("TITLE_HOME"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar(content: {
            ToolbarItem(placement: .topBarLeading, content: {
                Button(action: {
                    isPresented.toggle()
                }, label: {
                    Image(systemName: "trash.fill")
                })
                .confirmationDialog(NSLocalizedString("LABEL_CLEAR_REQUESTS", comment: ""), isPresented: $isPresented, actions: {
                    Button(role: .destructive, action: {
                        // 全削除
                        Task(priority: .background, operation: {
                            withAnimation(.spring) {
                                try? modelContext.delete(model: RecordGroup.self)
                            }
                        })
                    }, label: {
                        Text("LABEL_CLEAR")
                    })
                }, message: {
                    Text("LABEL_CLEAR_REQUESTS_DESC")
                })
            })
        })
    }
}

#Preview {
    HomeView()
}
