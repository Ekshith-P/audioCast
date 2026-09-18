import SwiftUI

struct ContentView: View {
    @StateObject private var receiver = StreamReceiver()

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "airport.express")
                .resizable()
                .scaledToFit()
                .frame(width: 80, height: 80)
                .foregroundColor(.green)
            
            Text("AudioCast Receiver")
                .font(.title)
                .bold()

            Text(statusText)
                .foregroundColor(.secondary)

            if let error = receiver.lastError ?? receiver.player().lastError {
                Text(error)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding()
        .task {
            receiver.start()
        }
    }

    private var statusText: String {
        switch receiver.status {
        case .idle:
            return "Idle"
        case .browsing:
            return "Searching for Mac…"
        case .connecting(let name):
            return "Connecting to \(name)…"
        case .connected(let name):
            return "Connected to \(name)"
        case .failed(let message):
            return message
        }
    }
}
