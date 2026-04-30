import SwiftUI

/// CreateHubBoardCTAView — Large landing-page card that invites the
/// user to start a new board. Renders the primary action on the
/// Create Hub; tapping it launches the 3-step board-creation wizard.
/// iOS twin of web's `CreateHubBoardCTA`.
struct CreateHubBoardCTAView: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                Text("✨")
                    .font(.system(size: 32))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start a new board")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text("Set it up, pick your tasks, and activate.")
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.white.opacity(0.9))
            }
            .padding(20)
            .background(
                LinearGradient(
                    colors: [Color.blue, Color.indigo],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .cornerRadius(14)
            .shadow(color: Color.blue.opacity(0.25), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Start a new board")
    }
}
