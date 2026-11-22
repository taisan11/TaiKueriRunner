import Foundation

// Key meanings come from bundled MGKeys; preset values are cross-checked against
// Nugget and GestaltX. UI, conversion and draft handling share these definitions.
struct MobileGestaltFeature: Identifiable, Sendable {
    enum Category: String, CaseIterable, Identifiable, Sendable {
        case display = "画面・見た目", device = "サウンド・操作", camera = "カメラ・写真・動画"
        case battery = "バッテリー・充電", ipad = "iPad・マルチタスク", connectivity = "接続・外部出力"
        case accessibility = "アクセシビリティ"
        case intelligence = "Apple Intelligence・Siri", advanced = "端末情報・詳細"
        var id: Self { self }
        var title: String { LKey(rawValue) }
    }

    enum Control: Sendable { case toggle, picker, text, number }

    struct Field: Sendable {
        enum Kind: Sendable { case flag, integer, string }
        let key: String
        let name: String
        var kind: Kind = .flag
        var subkeys: [String] = []
        var path: [PlistPathComponent] { [.key("CacheExtra"), .key(key)] + subkeys.map { .key($0) } }

        func normalized(_ value: PropertyListValue) throws -> PropertyListValue {
            guard MGKeyCatalog.names[key] == name else { throw RunnerError(localized: "キー定義を確認できません。") }
            switch (kind, value) {
            case (.flag, .boolean): return value
            case (.flag, .integer("0")): return .boolean(false)
            case (.flag, .integer("1")): return .boolean(true)
            case (.integer, .integer(let number)) where Int64(number) != nil: return value
            case (.string, .string): return value
            default: throw RunnerError(localized: "設定の値の型が対応していません。")
            }
        }

        func encoded(_ value: PropertyListValue, like current: PropertyListValue?) throws -> PropertyListValue {
            if let current { _ = try normalized(current) }
            let normalized = try normalized(value)
            if case .flag = kind, case .boolean(let enabled) = normalized {
                switch current {
                case nil, .integer?: return .integer(enabled ? "1" : "0")
                default: break
                }
            }
            return normalized
        }
    }

    struct Choice: Identifiable, Sendable {
        let id: String
        let title: String
        let values: [PropertyListValue]

        init(id: String, title: String, values: [PropertyListValue]) {
            self.id = id
            self.title = LKey(title)
            self.values = values
        }
    }

    let id: String
    let category: Category
    let title: String
    let explanation: String
    let symbol: String
    let control: Control
    let fields: [Field]
    var choices: [Choice] = []

    init(id: String, category: Category, title: String, explanation: String,
         symbol: String, control: Control, fields: [Field], choices: [Choice] = []) {
        self.id = id
        self.category = category
        self.title = LKey(title)
        self.explanation = LKey(explanation)
        self.symbol = symbol
        self.control = control
        self.fields = fields
        self.choices = choices
    }

    func matches(search: String) -> Bool {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        return query.isEmpty || ([title, explanation, category.rawValue, category.title] + fields.flatMap { [$0.name, $0.key] + $0.subkeys })
            .contains { $0.localizedStandardContains(query) }
    }

    func values(in document: MobileGestaltDocument, original: Bool = false) throws -> [PropertyListValue] {
        try optionalValues(in: document, original: original).map { value in
            guard let value else { throw RunnerError(localized: "キーが未設定です。変更すると自動追加します。") }
            return value
        }
    }

    private func optionalValues(in document: MobileGestaltDocument, original: Bool = false) throws -> [PropertyListValue?] {
        let values = try fields.map { field in
            guard MGKeyCatalog.names[field.key] == field.name else { throw RunnerError(localized: "キー定義を確認できません。") }
            return try document.valueIfPresent(at: field.path, original: original).map { try field.normalized($0) }
        }
        if case .number = control, case .integer(let value)? = values.first ?? nil, let number = Int64(value), number < 0 {
            throw RunnerError(localized: "0以上の整数を入力してください。")
        }
        return values
    }

    func isAvailable(in document: MobileGestaltDocument) -> Bool {
        editingIssue(in: document) == nil
    }

    func editingIssue(in document: MobileGestaltDocument?) -> String? {
        guard let document else { return L("Plistを読み込むと編集できます。") }
        do {
            _ = try optionalValues(in: document)
            _ = try optionalValues(in: document, original: true)
            return nil
        } catch { return error.localizedDescription }
    }

    func needsKeyAddition(in document: MobileGestaltDocument) -> Bool {
        (try? optionalValues(in: document).contains { $0 == nil }) == true
    }

    func selection(in document: MobileGestaltDocument) -> String? {
        guard let values = try? values(in: document) else { return nil }
        return choices.first { $0.values == values }?.id
    }

    func stage(choice id: String, in document: inout MobileGestaltDocument) throws {
        guard let choice = choices.first(where: { $0.id == id }) else { throw RunnerError(localized: "設定の選択肢が無効です。") }
        try apply(choice.values, to: &document)
    }

    func stage(input: String, in document: inout MobileGestaltDocument) throws {
        let value: PropertyListValue
        switch control {
        case .text: value = .string(input)
        case .number:
            guard let number = Int64(input), number >= 0 else { throw RunnerError(localized: "0以上の整数を入力してください。") }
            value = .integer(String(number))
        default: throw RunnerError(localized: "設定の入力形式が無効です。")
        }
        try apply([value], to: &document)
    }

    private func apply(_ values: [PropertyListValue], to document: inout MobileGestaltDocument) throws {
        guard fields.count == values.count else { throw RunnerError(localized: "設定の値が不足しています。") }
        if let issue = editingIssue(in: document) { throw RunnerError(issue) }
        var draft = document
        for (field, value) in zip(fields, values) {
            try draft.setFeatureValue(value, at: field.path)
        }
        document = draft
    }

    func reset(in document: inout MobileGestaltDocument) throws {
        var draft = document
        for field in fields { try draft.resetFeatureValue(at: field.path) }
        document = draft
    }

    func summary(in document: MobileGestaltDocument, original: Bool = false) throws -> String {
        let optional = try optionalValues(in: document, original: original)
        if optional.contains(where: { $0 == nil }) {
            if optional.allSatisfy({ $0 == nil }) { return L("未設定（キーなし）") }
            return optional.map { $0?.summary ?? L("未設定") }.joined(separator: " / ")
        }
        let values = optional.compactMap { $0 }
        if let choice = choices.first(where: { $0.values == values }) { return choice.title }
        if case .toggle = control { return L("一部のみ有効") }
        return values.map(\.summary).joined(separator: " / ")
    }

    static func available(in document: MobileGestaltDocument) -> [Self] { all.filter { $0.isAvailable(in: document) } }
    static func feature(at path: [PlistPathComponent]) -> Self? { all.first { $0.fields.contains { $0.path == path } } }

    static func changed(in document: MobileGestaltDocument) -> [Self] {
        let ids = Set(document.changes.values.compactMap { feature(at: $0.path)?.id })
        return all.filter { ids.contains($0.id) }
    }

    static func validateGuidedChanges(in document: MobileGestaltDocument) throws {
        for entry in document.changes.values {
            guard let feature = feature(at: entry.path), feature.isAvailable(in: document) else {
                throw RunnerError(localized: "詳細エディタの変更が含まれています。詳細エディタで確認・保存してください。")
            }
        }
    }

    static func toggle(_ id: String, _ category: Category, _ title: String, _ explanation: String,
                               _ symbol: String, _ fields: [Field]) -> Self {
        Self(id: id, category: category, title: title, explanation: explanation, symbol: symbol, control: .toggle, fields: fields,
             choices: [.init(id: "off", title: "無効", values: fields.map { _ in .boolean(false) }),
                       .init(id: "on", title: "有効", values: fields.map { _ in .boolean(true) })])
    }

    static let parallax = toggle("parallax", .display, "壁紙の視差効果", "端末の傾きに合わせて壁紙を動かす機能です。", "photo.on.rectangle.angled",
                                  [.init(key: "mmu76v66k1dAtghToInT8g", name: "UIParallaxCapability")])
    static let liquidGlass = toggle("liquidGlass", .display, "Liquid Glassの省負荷モード", "Liquid Glassの描画負荷を抑えるモードです。", "drop.halffull",
                                     [.init(key: "SAGvsp6O6kAQ4fEfDJpC4Q", name: "IsSolariumLowPerformanceDevice")])
    static let bootChime = toggle("bootChime", .device, "起動・終了サウンド", "端末の起動・終了時のサウンドへの対応を切り替えます。", "speaker.wave.2",
                                   [.init(key: "QHxt+hGLaBPbQJbXiUJX3w", name: "DeviceSupportsBootChime")])
    static let tapToWake = toggle("tapToWake", .device, "タップでスリープ解除", "画面のタップによるスリープ解除への対応を切り替えます。", "hand.tap",
                                   [.init(key: "yZf3GTRMGTuwSV/lD7Cagw", name: "DeviceSupportsTapToWake")])

    static let all: [Self] = [
        parallax, liquidGlass,
        toggle("dynamicIsland", .display, "Dynamic Island", "Dynamic Islandの表示への対応を切り替えます。", "capsule",
               [.init(key: "YlEtTtHlNesRBMal1CqRaA", name: "DeviceSupportsDynamicIsland")]),
        .init(id: "islandLayout", category: .display, title: "Dynamic Islandのレイアウト", explanation: "表示サイズに使う機種別レイアウトを選びます。", symbol: "rectangle.topthird.inset.filled", control: .picker,
              fields: [.init(key: "oPeik/9e8lQWMszEjbPzng", name: "ArtworkTraits", kind: .integer, subkeys: ["ArtworkDeviceSubType"]),
                       .init(key: "YlEtTtHlNesRBMal1CqRaA", name: "DeviceSupportsDynamicIsland")],
              choices: [("2436", "iPhone X（ジェスチャー）", 2436), ("2556", "iPhone 14 / 15 Pro", 2556), ("2796", "iPhone 14 / 15 Pro Max", 2796),
                        ("2622", "iPhone 16 Pro", 2622), ("2868", "iPhone 16 Pro Max", 2868), ("2736", "iPhone Air", 2736)]
                .map { .init(id: $0.0, title: $0.1, values: [.integer(String($0.2)), .boolean(true)]) }),
        toggle("alwaysOnDisplay", .display, "常時表示", "ロック画面と時計の常時表示への対応を切り替えます。", "display",
               [.init(key: "2OOJf1VhaM7NxfRok3HbWQ", name: "DeviceSupportsAlwaysOnDisplay"), .init(key: "j8/Omm6s1lsmTDFsXjsBfA", name: "DeviceSupportsAlwaysOnTime")]),
        toggle("aodVibrancy", .display, "常時表示の鮮やかさ", "常時表示中の色の表現を切り替えます。", "paintpalette",
               [.init(key: "ykpu7qyhqFweVMKtxNylWA", name: "DeviceSupportsAODVibrancy")]),
        toggle("aodHighLuminance", .display, "高輝度の常時表示", "常時表示で高い明るさを使う機能への対応を切り替えます。", "sun.max",
               [.init(key: "7brdL5xrEUWnlF9C0kdg5A", name: "DeviceSupportsHighLuminanceAlwaysOnDisplay")]),
        toggle("aodFlipbook", .display, "常時表示のFlipbook", "常時表示中のウィジェット更新への対応を切り替えます。", "rectangle.stack",
               [.init(key: "aoJSd/MXk7M40NgXTM6x+g", name: "DeviceSupportsAlwaysOnDisplayFlipbook")]),
        .init(id: "flipbookCount", category: .display, title: "Flipbookの最大数", explanation: "常時表示で使うFlipbookの最大数です。", symbol: "number", control: .number,
              fields: [.init(key: "qqrspu7CpuPdZwSDxNY+Fg", name: "MaximumFlipbookCount", kind: .integer)]),
        toggle("hdrPhotos", .display, "HDR写真の表示", "写真をHDRで表示する機能への対応を切り替えます。", "photo",
               [.init(key: "a1r7npIrhXsZ7SmKRKC1eA", name: "DeviceSupportsHDRPhotoDisplay")]),
        toggle("pwm", .display, "ディスプレイのPWM対応", "ディスプレイのPWM制御への対応情報を切り替えます。", "waveform.path",
               [.init(key: "6IejgN+1Fmu5/QrZFOIeNw", name: "DeviceSupportsPulseWidthMaximization")]),
        toggle("displayPort", .display, "DisplayPort出力", "外部ディスプレイへのDisplayPort出力への対応を切り替えます。", "display.2",
               [.init(key: "CoWnN4xo783YGn4wLrUatA", name: "DeviceSupportsDisplayPort")]),
        bootChime, tapToWake,
        toggle("chargeLimit", .battery, "充電上限", "充電上限の設定表示への対応を切り替えます。", "battery.100percent",
               [.init(key: "37NVydb//GP/GrhuTN+exg", name: "DeviceSupports80ChargeLimit")]),
        toggle("actionButton", .device, "Action Button", "アクションボタンの設定表示への対応を切り替えます。", "button.programmable.square",
               [.init(key: "cT44WE1EohiwRzhsZ8xEsw", name: "RingerButtonCapability")]),
        toggle("cameraControl", .device, "カメラコントロール", "カメラコントロールの設定表示への対応を切り替えます。", "camera",
               [.init(key: "CwvKxM2cEogD3p+HYgaW0Q", name: "CameraButtonCapability")]),
        toggle("collisionSOS", .device, "衝突事故検出", "衝突事故検出の設定表示への対応を切り替えます。", "car.side",
               [.init(key: "HCzWusHQwZDea6nNhaKndw", name: "DeviceSupportsCollisionSOS")]),
        toggle("audioMix", .device, "オーディオミックス", "動画のオーディオミックスへの対応を切り替えます。", "slider.vertical.3",
               [.init(key: "aVL5GE3tx0LSCI/ErfrJGA", name: "DeviceSupportsAudioMix")]),
        toggle("spatialFaceTime", .device, "FaceTimeの空間オーディオ", "FaceTimeの空間オーディオ再生への対応を切り替えます。", "person.wave.2",
               [.init(key: "/EVOCjM/Nmb2roP5ebtEFA", name: "DeviceSupportsSpatialFaceTimeAudioPlayback")]),
        toggle("pencil", .ipad, "Apple Pencil", "Apple Pencilの設定表示への対応を切り替えます。", "applepencil",
               [.init(key: "yhHcB0iH0d1XzPO/CFd3ow", name: "DeviceSupportsApplePencil")]),
        toggle("stageManager", .ipad, "Stage Manager", "ステージマネージャへの対応を切り替えます。", "rectangle.3.group",
               [.init(key: "qeaj75wk3HF4DwQ8qbIi7g", name: "DeviceSupportsEnhancedMultitasking")]),
        toggle("appleIntelligence", .intelligence, "Apple Intelligence", "生成モデルを利用する機能への対応情報を切り替えます。", "sparkles",
               [.init(key: "A62OafQ85EJAiiqKn4agtg", name: "DeviceSupportsGenerativeModelSystems")]),
        toggle("audioIntelligence", .intelligence, "Audio Intelligence", "音声向けのIntelligence機能への対応を切り替えます。", "waveform",
               [.init(key: "rb2tKZxlj0Gm2tBmUQSLqQ", name: "DeviceSupportsAudioIntelligence")]),
        toggle("personalTranslator", .intelligence, "パーソナル翻訳", "パーソナル翻訳機能への対応を切り替えます。", "translate",
               [.init(key: "M1n2sAqf33NAOgZRGxQYBA", name: "DeviceSupportsPersonalTranslator")]),
        toggle("photosCleanUp", .intelligence, "写真のクリーンアップ", "写真から不要なものを取り除く機能への対応を切り替えます。", "eraser",
               [.init(key: "XNCjqOupLM/S8fNyxRNQTA", name: "DeviceSupportsPhotosInpainting")]),
        toggle("handwriting", .intelligence, "手書き文字の合成", "手書き文字を整えるモデルへの対応を切り替えます。", "pencil.and.scribble",
               [.init(key: "YgYIIViDt1kgzyIsIV61vA", name: "DeviceSupportsHandwritingSynthesisModel")]),
        toggle("heySiri", .intelligence, "Hey Siriの常時待機", "Hey Siriの常時待機への対応を切り替えます。", "mic",
               [.init(key: "TusANsf9Lfe3P/9fIXXSrQ", name: "DeviceSupportsAlwaysListeningHeySiri")]),
        .init(id: "modelName", category: .advanced, title: "機種の表示名", explanation: "画面表示に使う機種名を編集します。", symbol: "iphone", control: .text,
              fields: [.init(key: "oPeik/9e8lQWMszEjbPzng", name: "ArtworkTraits", kind: .string, subkeys: ["ArtworkDeviceProductDescription"])]),
        .init(id: "productType", category: .advanced, title: "機種識別子", explanation: "機種識別子を編集します（例: iPhone17,1）。", symbol: "iphone.gen3", control: .text,
              fields: [.init(key: "h9jDsbgj7xIVeIQ8S3/X3Q", name: "ProductType", kind: .string)]),
        .init(id: "regionCode", category: .advanced, title: "地域コード", explanation: "端末の地域コードを編集します。", symbol: "globe", control: .text,
              fields: [.init(key: "h63QSdBCiT/z0WU6rdQv6Q", name: "RegionCode", kind: .string)]),
        .init(id: "regionInfo", category: .advanced, title: "販売地域", explanation: "販売地域の識別情報を編集します（例: LL/A）。", symbol: "globe.asia.australia", control: .text,
              fields: [.init(key: "zHeENZu+wbg7PUprwNwBWg", name: "RegionInfo", kind: .string)]),
        toggle("internalInstall", .advanced, "内部向け機能", "内部向けメニューの表示に使う情報を切り替えます。", "wrench.and.screwdriver",
               [.init(key: "EqrsVvjcYDdxHBiQmGhAWw", name: "apple-internal-install")]),
        toggle("internalBuild", .advanced, "Internal Build", "システム全体のInternal Build情報を切り替えます。", "hammer",
               [.init(key: "LBJfwOEzExRxzlAnSuI7eg", name: "InternalBuild")]),
        toggle("researchDevice", .advanced, "研究用デバイス情報", "Security Research Deviceの対応情報を切り替えます。", "ladybug",
               [.init(key: "XYlJKKkj2hztRP1NWWnhlw", name: "ResearchFuse")]),
        toggle("internalSettings", .advanced, "内部向け設定", "内部向け設定バンドルの表示に使う情報を切り替えます。", "gearshape.2",
               [.init(key: "Oji6HRoPi7rH7HPdWVakuw", name: "HasInternalSettingsBundle")])
    ] + extendedFeatures
}
