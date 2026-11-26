# 静岡コンペ・入札ウォッチ

静岡県・県内市町・県内の国の機関が出す入札／プロポーザル（企画提案）案件のうち、
**イベント／Web・IT／デザイン・広報・映像** 分野のものを毎朝自動収集し、Webページで一覧表示します。

- 情報源
  - [官公需情報ポータルサイト](https://www.kkj.go.jp/) 検索API（中小企業庁）… 静岡県内の自治体・国の機関の公告
  - [静岡県 入札・公募・公売](https://www.pref.shizuoka.jp/kensei/nyusatsukobai/index.html) の部署別「入札・業務委託・プロポーザル等」ページ
- 実行: GitHub Actions が毎日 6:30（日本時間）に収集 → `docs/data.json` を更新
- 表示: GitHub Pages で `docs/index.html` を公開（RSS: `docs/feed.xml`）

## ファイル構成

| ファイル | 役割 |
|---|---|
| `config.json` | 分野ごとのキーワード、除外キーワードなどの設定 |
| `scripts/collect.ps1` | 収集スクリプト（PowerShell 5.1 / 7 対応） |
| `scripts/serve.ps1` | ローカル確認用の簡易Webサーバー |
| `docs/index.html` | 一覧ページ（検索・分野・新着・プロポーザル絞り込み、締切順ソート） |
| `docs/data.json` / `docs/feed.xml` | 収集結果（自動更新） |
| `.github/workflows/update.yml` | 毎朝の自動実行設定 |

## クラウドで動かす手順（GitHub）

1. GitHub で新しいリポジトリを作成（GitHub Pages を無料で使う場合は **Public**）
2. このフォルダの中身をすべてアップロード（`.github` フォルダも含める）
   - Git を使う場合: `git init` → `git add .` → `git commit` → `git push`
   - ブラウザの場合: リポジトリの「Add file → Upload files」にフォルダごとドラッグ
3. **Settings → Pages** で「Deploy from a branch」、Branch を `main` / `/docs` にして Save
4. **Actions** タブで「案件データ更新」を開き「Run workflow」で一度手動実行して動作確認
5. 数分後、`https://<ユーザー名>.github.io/<リポジトリ名>/` で一覧が見られます

> Organization のリポジトリでコミットに失敗する場合は、Settings → Actions → General →
> Workflow permissions を「Read and write permissions」にしてください。

## ローカルで動かす（Windows）

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\collect.ps1
powershell -ExecutionPolicy Bypass -File .\scripts\serve.ps1   # → http://localhost:8765/
```

## 分野・キーワードの調整

`config.json` の `tags[].keywords` に語句を足す／消すだけで反映されます（次回収集時に過去分にも再適用）。
ノイズになる語は `excludeKeywords` に追加してください。英字のみの語（`IT`, `AI` など）は単語単位で照合します。

## 注意

- 「締切目安」は公告文から自動推定した日付です。必ず原文で日程・参加資格を確認してください。
- 締切が読み取れない案件は、掲載から45日で「終了」扱いになります（「終了・締切済みも表示」で確認可）。
- 官公需ポータルに掲載されない市町独自の案件（市のサイトのみに掲載など）は拾えません。
  必要なら静岡市・浜松市など個別サイトの収集を `collect.ps1` に追加できます。
