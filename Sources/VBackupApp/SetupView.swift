import SwiftUI
import UniformTypeIdentifiers

/// Before a backup folder is chosen: sign in first, then choose the folder.
struct SetupView: View {
    @Bindable var model: AppModel
    @State private var choosingFolder = false

    var body: some View {
        if model.isSignedIn { chooseFolder } else { signIn }
    }

    private var signIn: some View {
        VStack(spacing: 14) {
            Image(systemName: "person.crop.circle")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Sign in to Vimeo")
                .font(.title2.weight(.semibold))
            Button("Sign In…") { model.showSignIn = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var chooseFolder: some View {
        VStack(spacing: 14) {
            Image(systemName: "externaldrive.badge.plus")
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            Text("Choose a backup folder")
                .font(.title2.weight(.semibold))
            Text("Your Vimeo folders are mirrored into it.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 440)
            Button("Choose backup folder…") { choosingFolder = true }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 6)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .fileImporter(isPresented: $choosingFolder, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result { model.setRoot(url) }
        }
    }
}
