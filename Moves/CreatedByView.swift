//
//  CreatedByView.swift
//  Raul
//
//  Created by Holger Krupp on 22.08.25.
//

import SwiftUI

struct CreatedByView: View {
    @Environment(\.openURL) private var openURL

    private let websiteURL = URL(string: "https://extremelysuccessfulapps.com")!
    private let sourceCodeURL = URL(string: "https://github.com/holgerkrupp/Moves")!

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            Text("Created in Buxtehude by")

            linkButton(
                title: "Extremely Successful Apps",
                image: "extremelysuccessfullogo",
                url: websiteURL
            )

            Divider()

            linkButton(
                title: "Get the source code",
                image: "githublogo",
                url: sourceCodeURL
            )

            VersionNumberView()
                .font(.caption)
        }
    }

    private func linkButton(title: String, image: String, url: URL) -> some View {
        Button {
            openURL(url)
        } label: {
            Label(title, image: image)
                .foregroundStyle(.accent)
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    CreatedByView()
}
