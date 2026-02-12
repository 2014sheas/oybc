import SwiftUI

/// Main content view for OYBC app
///
/// Phase 1.5: Shows a simple "Hello OYBC" message and verifies database connection.
/// Includes navigation to Playground for feature testing.
/// Phase 2: Will show the main game interface.
struct ContentView: View {
    @State private var dbStatus: String = "Connecting..."
    @State private var dbConnected: Bool = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 20) {
                Text("Hello OYBC")
                    .font(.largeTitle)
                    .fontWeight(.bold)
                    .padding()

                Text("On Your Bingo Card - iOS App")
                    .font(.title3)
                    .foregroundColor(.secondary)

                // Database status indicator
                VStack(spacing: 10) {
                    HStack {
                        Image(systemName: dbConnected ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                            .foregroundColor(dbConnected ? .green : .orange)
                        Text("Database Status:")
                            .fontWeight(.semibold)
                        Text(dbStatus)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(dbConnected ? Color.green.opacity(0.1) : Color.orange.opacity(0.1))
                    )

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Phase 1.5: Working App Infrastructure 🚧")
                            .font(.headline)
                        Text("This is a minimal working iOS app. Phase 2 will add the actual game UI.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    .padding()
                    .background(
                        RoundedRectangle(cornerRadius: 10)
                            .fill(Color.blue.opacity(0.1))
                    )
                }
                .padding()

                // Navigation to Playground
                NavigationLink(destination: PlaygroundView()) {
                    HStack {
                        Image(systemName: "hammer.fill")
                        Text("Go to Playground")
                    }
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .cornerRadius(10)
                }
                .padding(.horizontal)
            }
            .padding()
            .navigationTitle("Home")
            .navigationBarTitleDisplayMode(.inline)
            .onAppear {
                testDatabaseConnection()
            }
        }
    }

    /// Test database connection
    private func testDatabaseConnection() {
        do {
            // Try to read from database
            let db = AppDatabase.shared
            _ = try db.read { database in
                // Simple query to test connection
                try String.fetchAll(database, sql: "SELECT name FROM sqlite_master WHERE type='table' LIMIT 1")
            }
            dbStatus = "✅ Connected"
            dbConnected = true
            print("✅ Database connection successful")
        } catch {
            dbStatus = "❌ Error: \(error.localizedDescription)"
            dbConnected = false
            print("❌ Database connection failed: \(error)")
        }
    }
}

#Preview {
    ContentView()
}
