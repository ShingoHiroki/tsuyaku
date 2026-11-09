# Tsuyaku

オンライン会議（Google Meet・Zoom・Teams など）の相手の発言と自分の発言を字幕にし、英⇔日に訳して表示する Mac アプリ（試作版）。文字起こしと翻訳はすべて Mac の中で行う。

使い方は `app/README.md`。手順書のコマンドは、すべてリポジトリのルートで実行する。

## フォルダー構成

| パス | 内容 |
|---|---|
| `app/` | Tsuyaku のアプリ本体（字幕と翻訳まで）。使い方は中の README.md |
| `models/` | WhisperKit と PLaMo（`models/plamo/`）のモデル。git の管理対象外（再ダウンロードできる） |
| `.venv/` | PLaMo を動かす Python の仮想環境。git の管理対象外（手元で作る。`app/README.md` の「PLaMo の準備」） |

## ライセンス

このリポジトリのコードは MIT License（`LICENSE`）。

使っている部品とモデルには、それぞれの利用条件がある（このリポジトリには含めず、ビルドや準備のときに取得する）。

| 部品・モデル | 利用条件 |
|---|---|
| [WhisperKit](https://github.com/argmaxinc/WhisperKit) | MIT License |
| [PLaMo 3 Translate](https://huggingface.co/pfnet) のモデル | [PLaMo Community License](https://plamo.preferredai.jp/info/plamo-community-license-ja)（使う前に条件を確認する） |
