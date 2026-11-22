import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct BatterOptionsView: View {
    let template: BatterTemplate
    @Binding var selections: BatterSelections
    @Environment(AppModel.self) private var model
    @State private var replacing: BatterOption?
    @State private var showFile = false
    @State private var error: String?
    @State private var generation = UUID()

    var body: some View {
        Section {
            Text(template.title).font(.headline)
            Text("作者: \(String(describing: template.author))").font(.subheadline).foregroundStyle(.secondary)
            if let description = template.description { Text(description).font(.subheadline) }
            if let banner = template.banner_text { Text(banner).font(.callout).foregroundStyle(.orange) }
        }
        Section("テンプレートをカスタマイズ") {
            if template.options.isEmpty { Text("設定項目はありません。").foregroundStyle(.secondary) }
            ForEach(template.identifiedOptions) { option in
                switch option.type {
                case "replace":
                    VStack(alignment: .leading, spacing: 6) {
                        Text(option.label + (option.required ? L("（必須）") : ""))
                        Button {
                            replacing = option
                            showFile = true
                        } label: {
                            Label(selections.replacements[option.id] == nil ? (option.button_label ?? L("ファイルを選択")) : L("ファイル選択済み・変更"),
                                  systemImage: "doc.badge.plus")
                        }
                        if selections.replacements[option.id] != nil {
                            Button("元に戻す", role: .destructive) { selections.replacements.removeValue(forKey: option.id) }.font(.caption)
                        }
                        if let filter = option.allowed_files { Text(filter).font(.caption).foregroundStyle(.secondary) }
                    }
                case "remove":
                    Toggle(option.label, isOn: boolean(option))
                case "picker":
                    if option.allow_multiple_selection {
                        VStack(alignment: .leading) {
                            Text(option.label).font(.subheadline.bold())
                            ForEach(option.options.indices, id: \.self) { index in
                                Toggle(option.options[index].label, isOn: Binding(
                                    get: { (selections.picked[option.id] ?? option.initialSelection).contains(index) },
                                    set: { selected in
                                        var picked = selections.picked[option.id] ?? option.initialSelection
                                        if selected { picked.insert(index) } else { picked.remove(index) }
                                        selections.picked[option.id] = picked
                                    }))
                            }
                        }
                    } else {
                        Picker(option.label, selection: Binding(
                            get: { (selections.picked[option.id] ?? option.initialSelection).first ?? 0 },
                            set: { selections.picked[option.id] = [$0] })) {
                            ForEach(option.options.indices, id: \.self) { Text(option.options[$0].label).tag($0) }
                        }
                    }
                case "set":
                    if option.setter_type == "toggle" {
                        Toggle(option.label, isOn: boolean(option))
                    } else if option.setter_type == "slider", let specification = try? BatterSlider(option) {
                        VStack(alignment: .leading) {
                            Text("\(option.label): \(current(option).text)").font(.subheadline)
                            ForEach(specification.low.indices, id: \.self) { index in
                                let low = specification.low[index], high = specification.high[index]
                                Slider(value: Binding(
                                    get: {
                                        let current = (try? BatterNumbers(current(option).text).values) ?? specification.initial.values
                                        return min(high, max(low, current[index]))
                                    }, set: { value in
                                        var values = (try? BatterNumbers(current(option).text).values) ?? specification.initial.values
                                        values[index] = value
                                        selections.values[option.id] = .string(BatterNumbers.text(values, tag: specification.initial.tag))
                                    }),
                                       in: low...high, step: specification.steps[index])
                                .accessibilityLabel(option.label + (specification.low.count > 1 ? " \(index + 1)" : ""))
                            }
                        }
                    } else if option.setter_type == "color_picker" {
                        ColorPicker(option.label, selection: color(option),
                                    supportsOpacity: option.sets_opacity || option.initialValue.text.split(separator: " ").count == 4)
                    } else {
                        VStack(alignment: .leading) {
                            Text(option.label).font(.subheadline)
                            TextField("値", text: Binding(get: { current(option).text }, set: { selections.values[option.id] = .string($0) }))
                                .textInputAutocapitalization(.never).autocorrectionDisabled()
                        }
                    }
                default: EmptyView() // The importer rejects unknown option types.
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red) }
        }
        .fileImporter(isPresented: $showFile, allowedContentTypes: [.data], allowsMultipleSelection: false) { result in
            do {
                if let url = try result.get().first, let option = replacing { replace(url, option: option) }
            } catch { self.error = error.localizedDescription }
        }
        .onDisappear { generation = UUID() }
    }

    private func current(_ option: BatterOption) -> BatterValue { selections.values[option.id] ?? option.initialValue }
    private func boolean(_ option: BatterOption) -> Binding<Bool> {
        Binding(get: { current(option).boolean }, set: { selections.values[option.id] = .bool($0) })
    }
    private func color(_ option: BatterOption) -> Binding<Color> {
        Binding(get: {
            let values = current(option).text.split(separator: " ").compactMap { Double($0) }
            guard values.count >= 3 else { return .white }
            return Color(.sRGB, red: values[0], green: values[1], blue: values[2], opacity: values.count >= 4 ? values[3] : 1)
        }, set: { color in
            var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
            guard UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
            let values = option.sets_opacity || option.initialValue.text.split(separator: " ").count == 4 ? [r, g, b, a] : [r, g, b]
            selections.values[option.id] = .string(values.map { String(Double($0)) }.joined(separator: " "))
        })
    }
    private func replace(_ url: URL, option: BatterOption) {
        let token = generation
        error = nil
        model.run(L("Batterの差し替えファイルを読み込み")) {
            do {
                let data = try await model.accessManager.readBatterReplacement(url, filter: option.allowed_files)
                guard token == generation else { return }
                let total = selections.replacements.filter { $0.key != option.id }.values.reduce(0) { $0 + $1.count } + data.count
                guard total <= WallpaperImporter.maximumBytes else { throw RunnerError(localized: "差し替えファイルの合計は256 MiBまでです。") }
                selections.replacements[option.id] = data
            } catch {
                guard token == generation else { return }
                self.error = error.localizedDescription
            }
        }
    }
}
