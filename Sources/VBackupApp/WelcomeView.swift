import AppKit
import SwiftUI

/// Getting started, shown once on first launch.
struct WelcomeView: View {
    @Bindable var model: AppModel
    /// Reopened from the toolbar's "?" button: the button just closes the sheet.
    var revisit = false
    @Environment(\.dismiss) private var dismiss

    private let steps: [(icon: String, title: String, detail: String)] = [
        ("person.crop.circle", "Sign in to Vimeo", "Email and password."),
        ("folder", "Choose a folder", "Your Vimeo folders are mirrored here."),
        ("arrow.down.circle", "Download", "Pick folders, dates and quality."),
    ]

    var body: some View {
        VStack(spacing: 36) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 96, height: 96)
            Text("Back up your Vimeo library")
                .font(.largeTitle.weight(.semibold))
            HStack(alignment: .top, spacing: 48) {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    VStack(spacing: 10) {
                        ZStack(alignment: .topTrailing) {
                            Image(systemName: step.icon)
                                .font(.system(size: 40, weight: .light))
                                .foregroundStyle(.tint)
                                .frame(width: 64, height: 64)
                            Text("\(index + 1)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .frame(width: 20, height: 20)
                                .background(Circle().fill(.tint))
                        }
                        Text(step.title).font(.headline)
                        Text(step.detail)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(width: 180)
                }
            }
            Label("Run it again anytime: only new or missing videos are downloaded.", systemImage: "arrow.clockwise")
                .font(.callout)
                .foregroundStyle(.secondary)
            Button(revisit ? "Done" : "Get Started") { revisit ? dismiss() : model.finishWelcome() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
        }
        .padding(48)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
