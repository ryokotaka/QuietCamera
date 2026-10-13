<p align="center">
  <img src="QuietCamera/Assets.xcassets/AppIcon.appiconset/AppIcon.png" width="96" height="96" alt="Quiet Camera のアイコン">
</p>

<h1 align="center">Quiet Camera</h1>

<p align="center">静かに撮るための、実験的なiPhoneカメラアプリ</p>

<p align="center">
  <img src="https://img.shields.io/badge/iOS-18.0%2B-1d2b31?style=flat-square" alt="iOS 18.0+">
  <img src="https://img.shields.io/badge/dependencies-none-1d2b31?style=flat-square" alt="外部ライブラリなし">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3f6f60?style=flat-square" alt="MIT License"></a>
</p>

<p align="center">
  <a href="README.md">English</a> · <strong>日本語</strong>
</p>

授業中に、教授から「シャッター音を消してほしい」と言われました。ところが日本のiPhoneでは、マナーモードにしてもシャッター音が消えないことがあります。無音カメラアプリも試しましたが、画質には満足できませんでした。

そこで自分で作ってみたのが、このアプリです。撮影のたびにシャッター音を抑える処理を行い、カメラが対応する最大サイズの写真を要求します。静かな場所で周りの邪魔をしないためのものなので、撮影が許可された場所で、周りの人やその場のルールに配慮して使ってください。

> [!IMPORTANT]
> 個人で作った実験的なアプリです。無音になること、最大解像度で保存されること、純正カメラと同じ画質になることは保証できません。結果はiPhoneの機種、iOSのバージョン、地域によって変わる可能性があり、動作を確認できたのはまだ1台だけです。

## できること

- **撮影のたびに自動で消音処理**：オンにする操作はいりません。iPhoneが対応していればAppleの公式APIを、対応していなければ実験的な方法を使います。
- **最大解像度を要求**：選択中のカメラが対応する最大の写真寸法を要求し、HEIC（非対応ならJPEG）で「写真」に保存します。保存前にアプリ側で縮小・再圧縮することはありません。
- **大きな4:3プレビュー**：前後のカメラを切り替えられます。倍率ボタン、調整バー、ピンチでデジタルズームもできます。
- **通信・広告なし**：使う権限は、カメラと写真ライブラリへの追加だけです。アプリ独自の通信、広告、分析はありません。

## これまでの確認

iPhone 15（iOS 27.0.1）の背面メインカメラ・1×で、撮影音なしで撮影できました。「写真」では8064 × 6048（約48.8MP）で保存されていることを確認しています。この端末では公式APIが消音に非対応だったため、実験的な方法が使われました。ほかの機種や地域ではまだ試していません。記録の詳細は[詳しい情報](#詳しい情報)にあります。

## 自分のiPhoneで使う

署名済みのアプリは含まれていないので、Xcodeでビルドして自分のiPhoneに入れて使います。必要なものは次のとおりです。

- iOS 18.0以降のiPhone
- iOS 18以降のSDKを含み、そのiPhoneのiOSに対応したXcodeが入ったMac
- Apple Account

手順:

1. [QuietCamera.xcodeproj](QuietCamera.xcodeproj) をXcodeで開き、**Xcode > Settings > Apple Accounts** でサインインします。
2. **TARGETS > QuietCamera > Signing & Capabilities** で **Automatically manage signing** を有効にし、自分の **Team** を選びます。
3. **Bundle Identifier** を、仮の値 `com.example.QuietCamera` から自分だけのもの（例：`com.example.myuniqueid.QuietCamera`）に変えます。
4. iPhoneをMacにつないでロックを解除し、求められたらコンピュータを信頼します。必要に応じて **設定 > プライバシーとセキュリティ > デベロッパモード** を有効にします。
5. スキーム **QuietCamera** と接続したiPhoneを選び、**Run（⌘R）** を押します。
6. 未信頼のデベロッパと表示されたら、iPhoneの **設定 > 一般 > VPNとデバイス管理** でアプリを信頼・検証します。
7. カメラと写真の追加を許可して撮影し、「写真」で結果を確かめます。最初は音が出ても困らない場所で試してください。

無料のPersonal Teamでは、プロビジョニングプロファイルが発行から7日で期限切れになります。そのときは同じApple AccountとBundle Identifierで再ビルド・再インストールしてください（[Appleの説明](https://developer.apple.com/help/account/basics/about-your-developer-account)）。

## 詳しい情報

技術的な背景、制約、出典は、以下にまとめています。

<details>
<summary><strong>シャッター音の背景と、消音処理のしくみ</strong></summary>

<br>

Appleの説明では、iPhoneのシャッター音は消音モードで消せます。ただし、一部の国や地域では消音できないとされています（[Appleサポート](https://support.apple.com/guide/iphone/adjust-the-shutter-volume-iph6cfaf98b6/ios)）。日本では、たとえばSoftBankのiPhone向けFAQが、マナーモードでも消音されないものとしてカメラのシャッター音を挙げています（[SoftBank よくあるご質問](https://www.softbank.jp/support/faq/view/12722)）。細かな挙動は端末や地域によって異なります。

Quiet Camera は撮影のたびに、次のどちらかを自動で行います。オン・オフの切り替えはありません。

| 条件 | 処理 | 種類 |
| --- | --- | --- |
| `isShutterSoundSuppressionSupported` が true | `isShutterSoundSuppressionEnabled` を有効にする | Appleの公式API（[ドキュメント](https://developer.apple.com/documentation/avfoundation/avcapturephotooutput/isshuttersoundsuppressionsupported)） |
| 上記に該当しない | 撮影前後の通知内で `AudioServicesDisposeSystemSoundID(1108)` を呼ぶ | 実験的な処理 |

`AudioServicesDisposeSystemSoundID` 自体は公開APIです。ただし、ID `1108` を使って撮影音を抑える方法は、Appleが文書化した消音の仕組みではありません。この処理は [ExperimentalShutterSilencer.swift](QuietCamera/ExperimentalShutterSilencer.swift) に分けてあります。

- 処理を実行することと、実際に無音になることは別です。戻り値が `0` でも、消音に成功したとは判断していません。
- 端末、OS、地域、撮影条件によっては音が鳴る可能性があります。OSのアップデートで動作が変わることもあります。
- 前面カメラにも同じ処理を適用していますが、前面での効果は実機で確認できていません。
- Appleがこの実装を承認していることも、App Store審査やAppleの契約・規約に適合していることも、確認していません。

</details>

<details>
<summary><strong>画質と解像度</strong></summary>

<br>

| 項目 | 設定 |
| --- | --- |
| 撮影 | `AVCapturePhotoOutput`、`.photo` プリセット |
| 要求する寸法 | 選択中のカメラが提示する最大の写真寸法 |
| 写真品質の優先度 | `.quality` |
| 圧縮品質 | `1.0` |
| 保存形式 | HEIC。非対応ならJPEG |
| アプリ内の縮小・再圧縮 | 保存前には行いません |

- **HEIC/JPEGは非可逆圧縮です。** 圧縮品質 `1.0` は、無劣化という意味ではありません。
- アプリに表示される最大解像度は、要求している値です。実際の保存結果は、機種、レンズ、照明、システムの処理などによって変わります。
- 純正カメラと同じ画像処理・画質や、すべての機種で24MP/48MPになることは保証しません。RAW/ProRAWには対応していません。
- 背面ではメインの広角カメラを使います。ズームはデジタルズームなので、倍率を上げると細部や保存解像度が落ちることがあります。画素数が同じでも、1×と同じ細部が残るわけではありません。
- 「さらに拡大」は、そのカメラが許可する上限まで倍率を上げてみる機能です。高倍率での画質や動作は、広くは検証していません。

**48MPの確認**：48MP対応の背面カメラを1×で使う場合は、要求した最大寸法を基準に写真を確認します。寸法が足りない写真は保存せず、エラーを表示します。確認するのは、完成画像なら実際の寸法、遅延処理のプロキシならシステムが返す完成予定の寸法です。ズーム中は解像度の低下を受け入れます。前面カメラにはこの条件を適用しません。

**遅延処理**：遅延写真処理に対応した環境では、プロキシを `.photoProxy` として写真ライブラリへ渡し、仕上げはシステムが行います。プロキシの寸法は、完成画像の寸法ではありません。また、完成予定の寸法を確認しても、処理後の画質が保証されるわけではありません。「写真アプリで仕上げ待ち」と表示された場合は、処理が終わってから「写真」の情報画面で寸法を確認してください（[Appleの遅延写真プロキシ](https://developer.apple.com/documentation/avfoundation/avcapturedeferredphotoproxy)）。

</details>

<details>
<summary><strong>確認の記録</strong></summary>

<br>

| 日付 | 環境 | 結果 |
| --- | --- | --- |
| 2026年10月6日 | iPhone 15 / iOS 27.0.1<br>背面メインカメラ・1× | 実際に使って、撮影音なしで撮影できることを確認しました。「写真」の情報画面で、8064 × 6048（約48.8MP、向きによって縦横が逆）での保存も確認しています。公式の消音対応フラグは `false` で、実験的な処理が使われました。 |
| 同年10月9日<br>（画面更新後） | 背面カメラ・1× | 大きなプレビューと、スイッチ操作なしでの消音・保存を、実際の使用で確認しました。 |

いずれも特定の端末での確認結果です。複数の機種や地域では検証していません。他のアプリや純正カメラとの画質比較も行っていません。

</details>

<details>
<summary><strong>権限・保存・データ</strong></summary>

<br>

| アクセス | 通常の撮影での扱い |
| --- | --- |
| カメラ | 撮影に使用 |
| 写真ライブラリ | 追加のみ（`addOnly`）。既存の写真を読む権限は要求しません |
| 位置情報 | 要求しません |
| マイク | 使用しません |
| 通信・広告・分析・追跡 | アプリ独自のものはありません |

- 写真ごとに保存状況を表示し、保存に失敗したときは再試行できます。アプリを終了すると、まだ保存されていない写真は失われます。
- 写真ライブラリに保存した後のiCloud同期などは、端末の設定に従います。
- 以前のマイク・Live Photo実験のコードと、マイク権限の説明文はプロジェクトに残っています。ただし、この機能の有効フラグは `false` に固定されていて、撮影画面からは起動できません。通常の撮影でマイクやLive Photoを使うことはありません。

</details>

<details>
<summary><strong>ビルドと、自分の版を公開するとき</strong></summary>

<br>

- このリポジトリはソースコードのみです。署名済みアプリ、開発者証明書、秘密鍵、プロビジョニングプロファイルは含みません。
- 外部ライブラリ、追加パッケージ、サーバーは不要です。
- Simulatorでは、実際の撮影・消音・保存品質は確認できません。
- 自分の署名設定を加えたうえで再公開する場合は、Team ID、端末情報、証明書、個人用の設定やログが含まれていないことを確認してください。

</details>

## ライセンス

[MIT License](LICENSE) で公開しています。著作権表示とライセンス文を残せば、再利用・改変・再配布・商用利用ができます。無保証で提供され、AppleのSDKやサービスの利用条件を変えるものではありません。実装時に参照した公開例とライセンス表示は [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) にあります。
