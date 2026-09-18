import SwiftUI

struct ContentView: View {
    @StateObject private var controller = MacStreamingController()

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "waveform.circle.fill")
                .resizable()
                .frame(width: 80, height: 80)
                .foregroundColor(.blue)
            
            Text("AudioCast Server")
                .font(.title)
                .bold()

            Group {
                if controller.server.isRunning, let port = controller.server.port {
                    Text("Broadcasting on port \(port)")
                } else {
                    Text("Waiting to start broadcast...")
                }
            }
            .foregroundColor(.secondary)

            Text("Clients: \(controller.server.connectedClientCount)")
                .foregroundColor(.secondary)

            if let error = controller.capture.lastError ?? controller.server.lastError ?? controller.lastError {
                Text(error)
                    .foregroundColor(.red)
                    .multilineTextAlignment(.center)
            }

            Button(controller.isBroadcasting ? "Stop Broadcast" : "Start Broadcast") {
                if controller.isBroadcasting {
                    controller.stop()
                } else {
                    controller.start()
                }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
        .padding(40)
        .frame(minWidth: 300, minHeight: 300)
    }
}
