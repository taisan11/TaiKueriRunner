# LINEのE2EEメディア調査

LINEビューアで「E2EEメディアの復号は行わない」としている範囲について、実データと公開実装で確認した結果です。

## 結論

- **端末内のE2EEメディアは、LINEが復号済みの平文で保存しています。** フルサイズの添付もサムネイルもJPEG/PDFなどの通常ファイルで、ビューアの現行実装（`Message Attachments`と`Message Thumbnails`をそのまま読む）で表示できます。復号処理は不要です。
- 将来または別端末で、暗号化されたblobがローカルに残る場合も**オフライン復号は可能**です。鍵はメッセージの`ZCONTENTMETADATA`にある`ENC_KM`（32バイト）で、`E2EEData.sqlite`やキーチェーンは不要です。
- 端末にないフルサイズ（今回のデータでは1,027件）はOBS上の暗号化オブジェクトです。取得にはLINEの認証付き通信が必要で、ローカル専用のビューアの範囲外です。

## 確認したデータ

対象: `group.com.linecorp.line-data`（App Group）の`Messages/`と、`jp.naver.line-data`（アプリコンテナ）の`Message Attachments`・`Message Thumbnails`。

| 項目 | 件数 |
| --- | --- |
| `e2eeVersion`を持つメディアメッセージ（`ZCONTENTTYPE` 1/2/14/112） | 3,097 |
| 内訳: 画像 / 動画 / ファイル / まとめ内メディア | 1,833 / 256 / 90 / 918 |
| ローカルのフルサイズ添付があるもの | 2,070 |
| ローカルのサムネイル（`.thumb`）があるもの | 2,924 |
| `ENC_KM`の長さ | 全件32バイト |

（1件のメッセージがフルサイズ添付とサムネイルの両方を持つ場合があるため、合計は3,097件を超えます。）

- ローカル添付2,070件とサムネイル2,924件について、`ENC_KM`から導出したHMACを検証しました。**一致したものは0件**で、いずれも暗号化blobではなく平文です。
- `Message Attachments`の内訳はjpg 2,302・pdf 21・xlsx 1・m4a 1で、E2EEの画像も通常のJPEGとして保存されています。
- `E2EEData.sqlite`は`ZE2EEKEY` 997件（32バイト351件・48バイト646件）と`ZE2EECHAT` 544件を持ちます。`ZMIDDATA`は`0x00`（ユーザー）または`0x02`（グループ）+ 16バイトのMIDで、MIDへの対応は復元できます。

## E2EEメディアの形式

`e2eeVersion=2`のメディアは、メッセージ本文とは別に、ファイル本体を`ENC_KM`で暗号化しています。`ENC_KM`は送信時に本文（`chunks`）へ封入され、受信側で`ZCONTENTMETADATA`へ復元された値です。

```
derived = HKDF-SHA256(ikm = ENC_KM, salt = 空, info = "FileEncryption", L = 76)
encKey  = derived[0..32]
macKey  = derived[32..64]
nonce   = derived[64..76] + 0x00000000   // AES-CTRの16バイトカウンタ
blob    = AES-256-CTR(encKey, nonce, 平文) + HMAC-SHA256(macKey, 暗号文)
```

復号は、末尾32バイトをHMACとして検証してからAES-CTRで戻します。参照実装:

- [linejs](https://github.com/evex-dev/linejs) `packages/linejs/base/e2ee/mod.ts` の`deriveKeyMaterial`・`encryptByKeyMaterial`・`decryptByKeyMaterial`
- [beeper/line](https://github.com/beeper/line) の`ENC_KM`フォールバック復号
- [OkLine: Letter Sealing](https://nicedayzc.github.io/OkLine/e2ee/) のSealed media

linejsでは`ENC_KM`をbase64文字列として扱いますが、iOSの`ZCONTENTMETADATA`では32バイトの`NSData`として保存されています。

## 実装する場合の選択肢

1. **現状維持**: 端末内は平文なので、E2EEメディアも既に表示できています。ドキュメントの表現だけ実態に合わせます。
2. **復号フォールバック**: `ENC_KM`を`LINEMessage`に載せ、添付ファイルが既知の画像・PDF等のmagicで始まらない場合だけHKDF/AES-CTR/HMACで復号します。暗号化blobがローカルに残る端末向けの保険で、通常のデータでは何も変わりません。
3. **E2EE表示**: `E2EEData.sqlite`の`ZE2EECHAT`からLetter Sealingの有効/無効を読み、トークにバッジを出します。表示のみで復号は行いません。
4. **OBSから取得**: `OID`/`SID`を使って暗号化オブジェクトを取得し、`ENC_KM`で復号します。LINEの認証トークンとネットワークが必要なため、現在のローカル専用方針とは相容れません。

## 制限

- 今回のデータには暗号化されたメディアblobが存在しないため、復号処理を実データで検証することはできませんでした。形式は上記の公開実装3つで一致しています。
- フルサイズが端末にない1,027件は、サムネイルのみ表示できます（現行どおり）。
- `E2EEData.sqlite`の鍵データはメッセージ本文の再復号用で、メディア表示には使いません。テキストは端末のDBに平文で保存されています（E2EE有効チャットを含む）。
