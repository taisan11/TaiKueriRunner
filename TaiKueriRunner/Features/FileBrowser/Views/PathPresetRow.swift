import SwiftUI

struct PathPresetRow: View {
    let preset: PathPreset

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(preset.title).foregroundStyle(.primary)
            Text(preset.path).font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(preset.note).font(.caption).foregroundStyle(.secondary)
        }.padding(.vertical, 3)
    }
}
