//
//  ContentView.swift
//  LittleRoute
//
//  Created by Dean Nemphos on 12/4/24.
//

import SwiftUI
import SwiftData
import MapKit

struct ContentView: View {
    @Environment(\.modelContext) private var modelContext
    @Query private var items: [Item]
    
    @State private var paused: Bool = false
    
    let c_radius: CGFloat = 20.0 // corner radius for consistency
    
    var body: some View {
        VStack {
            
            // Map!
            Map() {
                
            }
            .frame(width: 300, height: 300)
            .cornerRadius(c_radius)
            .padding()
            
            // Location info
            LazyVStack {
                
            }
            .background(.black)
            .padding()
            .cornerRadius(c_radius)
            
            // Music bar
            HStack {
                Button {
                    paused = !paused // @TODO -- make this play/pause the music
                } label: {
                    Image(systemName: paused ? "pause.fill" : "play.fill")
                        .imageScale(.large)
                }
                ProgressView(value: /*@START_MENU_TOKEN@*/0.5/*@END_MENU_TOKEN@*/) // @TODO -- Show song's current progression
            }
            .padding()
        }
        .background(.black)
        .ignoresSafeArea(edges: .all)
    }
}

#Preview {
    ContentView()
        .modelContainer(for: Item.self, inMemory: true)
}
