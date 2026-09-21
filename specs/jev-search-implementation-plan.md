# Jev 検索プラグイン実装計画

作成日: 2026-09-21

2026-09-22追記: 全件をJevで評価する方式は、[自然言語検索への置き換え計画](natural-language-search-implementation-plan.md)で更新する。本書は初期実装の経緯と既存の拡張ポイントの記録として残す。

## 目的

Movable Type の管理画面で、Jev を使い、自由な自然文で検索条件を指定して検索できるようにする。

`__mode=search_replace` の検索オプション「大文字/小文字を区別する」「正規表現」「項目を指定する」「日付範囲」と同じ列に「Jev」を追加する。チェックが入っている場合、検索条件と対象コンテンツを Jev に送り、条件を満たすと判定されたコンテンツを標準の検索結果に表示する。

RAG、ベクトル検索、埋め込み、検索インデックスの作成は行わない。対象コンテンツを1件ずつ判定し、通信は数件分の判定をまとめて行える構成にする。

## 決定事項と仮定

### ユーザーの要望として決まっていること

- 既存の検索／置換画面に「Jev」チェックボックスを追加する。
- チェック時は、入力した自然文と対象コンテンツを Jev に渡して判定する。
- 適切な拡張ポイントがなければ、関数の差し替えを使用してよい。
- APIキーはプラグインの設定画面で入力する。
- APIキーの設定画面は AI-Assistant と同様の操作感にする。
- グローバルヘッダーの検索入力欄の下にもチェックボックスを追加し、ONなら直接 Jev で検索する。
- ヘッダーの初期状態はプラグイン設定で切り替え可能にし、既定はONとする。

### この計画で置いている仮定

以下は未確定であり、ユーザーの回答に合わせて変更する。

| 項目 | 仮定 |
| --- | --- |
| 対応する MT | MT9以降。実装と検証は手元の MT9 系ソースを基準にする |
| API接続先 | TypeSafe 公式API |
| 初版の検索対象 | 記事、ウェブページ、コンテンツデータ |
| 設定のスコープ | システム共通 |

OpenRouter など別の接続先を採用する場合は、認証・モデル名・リクエスト形式・レスポンス形式を再確認し、APIクライアントの仕様を変更する。

### 初期実装で提案する値・動作

- プラグイン名・ID・キーは `Jev` とする。
- 判定しきい値は `0.5` とし、設定で変更可能にする。
- 1回のAPI呼び出しに含める候補数は5件とし、1件ずつの処理にも変更可能にする。
- 検索結果の並び順は標準検索と同じにする。
- Jev 有効時は検索専用とし、置換を無効にする。
- 初版は同期処理とする。分割実行や進捗表示は実測後の検討事項とする。

## 利用時の動作

1. 検索欄へ「導入後に困ったことが書かれている記事」などの自然文を入力する。
2. 「Jev」にチェックを入れる。
3. 必要に応じて、検索対象、項目、日付範囲を指定する。
4. MT がサイト・日付・公開状態などの条件で候補を取得する。
5. 各候補の権限を確認してから、対象項目を Jev に送る。
6. 条件を満たすと判定された候補を、標準の検索結果として表示する。

自然文そのものを含まないコンテンツも判定対象にする。そのため、Jev 検索では検索語による SQL の部分一致条件や正規表現による事前絞り込みを行わない。

### 既存オプションとの関係

| 操作・設定 | Jev 有効時の動作 |
| --- | --- |
| 検索欄 | 自然文の検索条件として使う |
| 大文字/小文字を区別する | 無効化する。サーバー側でも通常検索の判定に使用しない |
| 正規表現 | 無効化する。サーバー側でも通常検索の判定に使用しない |
| 項目を指定する | 指定された項目だけを判定用コンテンツに含める |
| 日付範囲 | 標準と同じ条件で候補を絞る |
| 検索結果の並び順 | 標準の並び順を維持する |
| 表示件数制限 | 判定した件数ではなく、一致した件数に適用する |
| 置換 | UIで無効化し、サーバー側でも拒否する |
| Jev を外す | 標準検索へ戻る |

自然文による一致判定からは置換する文字列の位置を特定できないため、Jev による置換は実装しない。Jev が無効な場合の標準の検索・置換は従来どおり動作させる。

空の検索条件では API を呼ばない。画面を開いただけの場合と、空欄で検索を実行した場合を区別し、後者では条件の入力を促す。APIキーが未設定の場合も検索を開始せず、設定が必要であることを表示する。

## MT本体の調査結果

調査対象は `lib/MT/CMS/Search.pm` と、`tmpl/admin2023/cms/search_replace.tmpl`、`tmpl/admin2025/cms/search_replace.tmpl`。

- `search_apis` には、検索対象項目、権限確認、取得条件の組み立て、結果表示の定義がある。
- `search_apis` の `handler` は検索結果テーブルを構築する処理であり、候補の一致判定を差し替えるものではない。
- 通常の検索は `make_terms` による SQL の部分一致条件と、`do_search_replace` 内の正規表現などによる照合を使用する。
- コンテンツフィールドには `search_handler` があるが、通常の記事フィールドなども含めた汎用の判定フックではない。
- 検索オプションはテンプレート内の通常のHTMLとして記述されている。チェックボックスを追加するための専用レジストリは見当たらない。
- 候補の取得には `incremental_iter` が使われる。
- 標準処理は一致件数を表示上限と比較し、追加の一致を検出すると `have_more` を設定する。

MTML や標準設定だけでは外部APIによる管理画面の検索判定を実現できないため、プラグインを作成する。

## 使用する拡張ポイントと参考例

| 用途 | 使用する仕組み | 参考例 |
| --- | --- | --- |
| APIキーなどの設定 | `settings`、`system_config_template`、`save_config_filter.Jev` | AI-Assistant |
| チェックボックス追加 | `template_source.search_replace`、`template_param.search_replace` | ContentInfoWidget の画面拡張構成 |
| ヘッダー検索の拡張 | `template_param.header`、プラグインのJavaScript | AI-Assistant のヘッダーへのテンプレート挿入 |
| 検索処理の入口 | `MT::App::CMS::init_app` で `MT::CMS::Search::search_replace` を一度だけラップ | 現行の CMS 動作モードの呼び出し方式 |
| Jev 判定への接続 | Jev 検索実行中に限定した内部関数の差し替え | 現行の `MT::CMS::Search` |

画面・設定には既存のコールバックを使う。検索の入口と候補の一致判定には内部関数のラップ・差し替えを採用する。

ContentInfoWidget はコールバックからプラグインのテンプレートを挿入する構成の参考にする。ただし、今回の挿入先は通常のHTMLなので、その DOM 操作をそのまま適用するのではなく、対象部分に限定したテンプレートソースの加工を行う。

## 検索処理の接続方針

`MT::App::CMS::init_app` に `$Jev::MT::Plugin::Jev::CMS::init_app` を登録し、標準の `MT::CMS::Search::search_replace` を一度だけラップする。元の関数を保持し、Jev が無効な場合や検索画面以外の呼び出しはそのまま委譲する。

当初候補とした `applications.cms.methods.search_replace` へのハンドラ追加は採用しない。結合テストで、MT は同名モードのハンドラを追加実行し、Jev のエラー後にも標準処理が実行されることを確認した。二重実行と置換拒否の無効化を避けるため、既存関数の入口をラップする。

Jev が無効な場合はそのまま標準処理へ委譲する。Jev による検索実行時に限り、次の接続方法を第一候補とする。

1. `MT::CMS::Search::make_terms` を一時的に差し替え、検索文による部分一致条件を追加しない。サイト、日付、公開状態、コンテンツタイプなどの取得条件は維持する。
2. `MT::CMS::Search::incremental_iter` を一時的にラップする。元のイテレーターから取得した候補を権限確認後にまとめて Jev で判定し、一致したオブジェクトだけを返す。
3. 標準の全件表示経路を内部的に利用し、Jev で判定済みのオブジェクトに対して正規表現の再照合を行わないようにする。
4. 結果テーブルの構築、表示件数の制限、追加結果の有無の検出は標準処理を利用する。
5. 検索条件や Jev の選択状態を表示用パラメータに保持する。一時的に使用した内部状態が利用者の条件表示や再検索に混ざらないようにする。

入口のラップはプロセス内に保持する。`make_terms` と `incremental_iter` の差し替えは Jev 検索の呼び出しスコープに限定し、正常終了・例外終了のいずれでも元の関数と一時パラメータを復元する。常駐プロセスで次の通常検索に影響を残さない。

この方法は本体の内部仕様に依存する設計案であり、結合テストで成立を確認する。特に、全件表示経路を使った場合の条件保持、権限、検索結果パラメータ、表示上限、`have_more` を検証する。本体へのファイル変更や、検索処理全体の無条件なコピーは前提にしない。

### 権限と対象項目

- 標準画面へのアクセス権限確認を維持する。
- 候補ごとの `perm_check` 相当の確認は、外部APIへの送信前に行う。
- 標準の `search_cols` と、コンテンツタイプの `searchable_fields` を対象項目の基準にする。
- ユーザーから渡された項目名は標準と同じ許可リストで検証する。
- コンテンツデータでは、選択中のコンテンツタイプに属するフィールドだけを使用する。
- Jev の対象外のオブジェクト種別ではチェックボックスを無効化または非表示にし、不正な直接リクエストも検証する。

## Jev APIの利用方法

### API契約

TypeSafe 公式APIを使う場合の接続先は `POST https://api.typesafe.ai/v1/systemone`。Bearer APIキーで認証し、JSONを送信する。

| 要素 | 内容 |
| --- | --- |
| `model` | 設定した Jev モデル名。初期候補は `jev-latest` |
| `state` | ユーザーが入力した検索条件 |
| `questions` | コンテンツ1件につき1つの Noul 質問 |
| 質問ID | `entry_123` など、対象を識別できるID |
| 質問の `instructions` | 対象の項目名・内容と、そのコンテンツが検索条件を満たすかを尋ねる質問を構造化して格納 |
| 回答 | 質問IDに対応する `answers` 内の `noul` 値 |

`Noul` は条件が真である確率を0〜1の数値で返す。初期設定では `noul >= 0.5` を一致とする。このしきい値はプラグイン側の提案値であり、実際の日本語検索例を使って調整する。

複数の質問は共通の `state` に対して独立に評価される。各レコードの内容をそのレコードの質問に含めることで、通信をまとめながら1件ごとの判定を受け取る。別の非同期バッチAPIを前提にはしない。

### 送信するコンテンツ

`MT::Plugin::Jev::Content` で判定用データを生成する。

- 指定された検索項目だけを含め、項目名と値の対応を維持する。
- 記事とウェブページではタイトル、本文、続き、概要など、標準の検索対象項目を扱う。
- HTMLやブロック形式の本文は、形式に応じて判定に必要な内容を取り出す。
- コンテンツフィールドの配列や複合データは型に応じて扱い、Perl の参照文字列のまま送信しない。
- 選択項目は値とラベルを、参照項目は同一サイト内で権限を確認した参照先のIDとラベルを送信する。画像・音声・動画のファイル自体は送信しない。
- MT標準で検索対象に含まれないテーブルフィールドなどは送信しない。本文内のHTMLの表はテキストに変換する。
- 判定の単位は選択項目をまとめたコンテンツ1件とし、項目ごとに別々の一致判定を行わない。

### 通信とエラー

- `MT::Plugin::Jev::Client::evaluate_batch` にHTTP通信とレスポンス検証を集約する。
- 期待する質問ID、回答の型、`noul` の数値と範囲を検証する。
- 回答の欠落や不正なレスポンスを不一致として処理しない。
- APIキー不正、入力エラー、タイムアウトなどは、検索を完了できなかったことが分かるエラーとして表示する。
- `429` や `529` の再試行は回数と時間を制限し、バックオフを使う。
- 1回の通信タイムアウトは最大10秒、検索全体の処理時間上限は45秒とする。再試行は最大2回で、待機時間も全体の上限に含める。実APIの測定結果に応じて見直す。
- 件数だけでなく入力サイズでもバッチを分割する。1件でも許容サイズを超える場合は明示的にエラーにし、本文を黙って切り捨てない。
- 初期実装ではプラグイン側の保守的な上限として、検索条件・指示を含むUTF-8 JSONを1件24,000バイト、1リクエスト48,000バイトまでとする。API自体の公称上限とは区別する。
- APIキーや送信本文を通常のログへ出さない。

## 設定画面

システムのプラグイン設定に以下の項目を置く。

| 設定キー | 内容 | 初期値案 |
| --- | --- | --- |
| `jev_api_key` | TypeSafe APIキー | 空 |
| `jev_model` | モデル名 | `jev-latest` |
| `jev_threshold` | 一致と判定するしきい値 | `0.5` |
| `jev_batch_size` | 1回の通信に含める候補数 | `5` |
| `jev_header_default` | グローバルヘッダーの「Jev を使う」の初期状態 | `1`（ON） |

APIキーの表示・更新は AI-Assistant を参考にする。

- 保存済みなら末尾だけをマスク付きで表示する。
- 「更新」を押したときに新しいキーの入力欄を有効にする。
- キーを変更せずに設定保存した場合は既存の値を維持する。
- 保存済みのキー全体をHTMLやJavaScriptに埋め込まない。
- しきい値は0〜1、バッチ件数は1〜50の整数としてサーバー側で検証する。
- ヘッダー検索の初期状態はON/OFFの選択欄で設定し、サーバー側では `0` / `1` を検証する。

## グローバルヘッダー検索

検索フォームの `input[type="text"]` の直下に「Jev を使う」チェックボックスを追加する。ONなら `is_jev=1` を付けて `__mode=search_replace`、`do_search=1` で送信し、検索結果画面へ進む時点で Jev 検索を実行する。OFFならMT標準の検索を実行する。プラグイン設定が未保存の場合も初期値はONとする。

- `MT::App::CMS::template_param.header` → `MT::Plugin::Jev::Callbacks::template_param_header` で、AI-Assistant のヘッダー拡張と同じ `js_include` の直前へ `header_search.tmpl` を挿入する。初期状態はIncludeの引数で渡し、APIキーは埋め込まない。
- `admin2025` のデスクトップ検索とモバイル検索は、`SearchForm.svelte` が動的にDOMを生成する。`header_search.js` で該当フォームの追加を監視してチェックボックスを挿入する。入力欄の下に並べるCSSはプラグイン側へ置く。
- 標準コンポーネントは送信時に別のフォームを生成して `form.submit()` を呼ぶため、チェックボックスを追加するだけでは値が送られない。JevがONの場合に限り、対象フォームのボタンクリック／Enterをcaptureで処理し、標準と同じパラメータに `is_jev=1` を追加してPOSTする。検索対象、サイトID、コンテンツタイプID、CSRFトークン、検索文を保持する。IME変換確定中のEnterでは送信しない。
- OFF時は標準ハンドラーへ任せる。検索結果画面を直接開いた場合や、`is_jev` を送らなかった通常検索へ初期値を強制しない。
- 記事・ウェブページ・コンテンツデータ以外を選んだ場合はチェックを無効化し、通常検索へ戻す。対応する対象を再び選ぶとそのページでの選択状態を復元する。
- 同じページ内ではポップアップを閉じて再度開いても選択状態を維持する。ページ遷移後はプラグイン設定の初期値を使う。
- 旧来の `#basic-search` フォームが存在する場合は、名前付きチェックボックスを挿入して標準のフォーム送信に含める。`admin2023` の通常の検索リンクと検索／置換画面は維持する。

本体のSvelteコンポーネントやブラウザー全体の `HTMLFormElement.prototype.submit` は置き換えない。MT更新時には `src/admin2025/forms/search/SearchForm.svelte`、`src/admin2025/admin-ui.ts`、対応するテーマのDOMを再確認する。

## ファイル構成

```text
plugins/Jev/
├── config.yaml
├── lib/MT/Plugin/Jev.pm          # 共通設定・エラー
├── lib/MT/Plugin/Jev/
│   ├── CMS.pm          # search_replace の入口
│   ├── Search.pm       # 候補走査・権限確認・一致判定
│   ├── Client.pm       # Jev API通信
│   ├── Content.pm      # 項目を送信用データに変換
│   └── Callbacks.pm    # 画面追加・設定保存
├── tmpl/
│   ├── system_config.tmpl
│   ├── header_search.tmpl
│   └── search_option.tmpl
├── t/
│   ├── search.t
│   ├── client.t
│   ├── content.t
│   ├── references.t
│   ├── config.t
│   ├── header_search.test.cjs # Node.js / jsdom によるヘッダー送信テスト
│   └── lib/MT/Plugin/Jev/Test.pm # MT の一時テスト環境
└── xt/live.t           # 明示実行する実API確認

mt-static/plugins/Jev/
├── search.js
├── header_search.js
├── header_search.css
└── system_config.js
```

小規模な翻訳は `config.yaml` の `l10n_lexicon` で定義する。独自のデータベーステーブルは初版では作成しない。

配布用にはルートの `Makefile.PL`、`compose.yml`、`Dockerfile` を AI-Assistant と同じ構成で用意する。`make build` でJavaScriptの構文を確認し、`make manifest`、`make dist`、`make zipdist` を順に実行して、設定内のバージョンに対応するtar.gzとZIPを生成する。配布対象は `MANIFEST.SKIP` で制御し、テスト・仕様書・ビルド関連ファイルを除く。生成物は `.gitignore` で管理対象外にする。

## 実装ステップ

1. **基本定義を作る。** `plugins/Jev/config.yaml` に `name`、`id`、`key`、`version`、翻訳、システム設定と設定画面を登録する。
2. **設定画面を作る。** `system_config.tmpl` と `system_config.js` を実装する。`save_config_filter.Jev` を `$Jev::MT::Plugin::Jev::Callbacks::save_config_filter` に接続し、未変更のキーを維持する。
3. **APIクライアントを作る。** `MT::Plugin::Jev::Client::evaluate_batch` に認証、JSONの送受信、タイムアウト、限定的な再試行、回答検証を実装する。
4. **コンテンツの変換を作る。** `MT::Plugin::Jev::Content` に記事・ウェブページ・コンテンツデータの項目抽出と型別の変換を実装する。
5. **Jev検索を接続する。** `MT::App::CMS::init_app` で `$Jev::MT::Plugin::Jev::CMS::init_app` を呼び出し、入口を一度だけラップする。`MT::Plugin::Jev::CMS::search_replace` と `MT::Plugin::Jev::Search` で候補走査と Jev 判定を標準検索へ接続する。最初に少数の候補で内部関数の差し替え方式が成立することを確認する。
6. **検索オプションを追加する。** `MT::App::CMS::template_source.search_replace` を `$Jev::MT::Plugin::Jev::Callbacks::template_source_search_replace` に接続し、選択肢の列へテンプレートを挿入する。`MT::App::CMS::template_param.search_replace` を `$Jev::MT::Plugin::Jev::Callbacks::template_param_search_replace` に接続し、状態保持と表示制御を行う。
7. **画面の連動を実装する。** `search.js` でチェック状態、正規表現などの無効化、再検索・タブ変更・全件表示時の引き継ぎを扱う。置換はUIとサーバーの両方で拒否する。
8. **テストと実APIでの確認を行う。** 通常検索との互換性、権限、絞り込み、件数制限、API失敗時の挙動を確認した後、少量の日本語データで判定精度と待ち時間を測定する。
9. **ヘッダー検索を拡張する。** `jev_header_default`（既定ON）と設定UIを追加し、ヘッダーの入力欄直下へチェックボックスを追加する。ON/OFF、動的生成、Enter／IME、対象切り替え、POSTの条件保持を確認する。

## 動作確認と受け入れ条件

MTの既存検索テストを参考に、APIをモックしたテストで以下を確認する。

### 標準動作との互換性

- Jev が無効な通常検索・置換は従来どおり動作し、APIを呼ばない。
- 画面を開いただけではAPIを呼ばない。
- Jev 検索の後に同じプロセスで通常検索しても、関数差し替えや一時パラメータの影響が残らない。
- API例外後にも元の関数とパラメータへ復元される。
- `DisableRegexpSearch` の設定にかかわらず、Jev 検索の判定が通常検索の判定へ戻らない。

### 検索条件と権限

- 検索文の文字列を含まないコンテンツも Jev により一致できる。
- 権限のないコンテンツはAPIへ送信されない。
- サイト、子サイト、日付、公開状態、コンテンツタイプの条件が適用される。
- 指定されていない検索項目を送信しない。
- 他のコンテンツタイプのフィールドが混ざらない。
- Jev 有効時の置換リクエストを拒否する。

### APIと結果表示

- 複数候補の回答が正しいオブジェクトに対応する。
- しきい値の境界と、0件・複数件の一致を正しく扱う。
- 表示上限は一致件数に適用され、追加結果の有無も正しく表示される。
- API失敗、回答欠落、不正な値、処理時間超過を検索結果0件として扱わない。
- 未走査の候補がある状態を「検索完了」と表示しない。
- タブ変更と全件表示で Jev の選択状態と検索条件を維持する。
- APIキーの未変更保存・更新とマスク表示が正しく動作する。
- ヘッダーの初期状態は未保存時ONで、設定をOFFにすると再表示後もOFFになる。
- ヘッダーでONにしてボタンまたはEnterで検索すると Jev 検索を直ちに実行し、結果画面でもONを維持する。
- ヘッダーでOFFにした検索では初期値がONでもAPIを呼ばない。
- 動的に開くポップアップとモバイル検索で重複なくチェックボックスを挿入し、IMEの変換確定時には送信しない。

画面は MT9 で使う管理画面テーマを確認し、必要な `admin2023` / `admin2025` の両方で選択肢の挿入位置とフォーム送信を確認する。

実APIの確認では少量の日本語コンテンツを使用し、同じ検索条件で1件ずつ送る場合と複数件まとめる場合の判定・待ち時間を比較する。自然文の条件に対する一致の妥当性も人手で確認する。

## 注意点・今後の検討事項

- 全候補を走査する方式なので、対象件数と本文量に応じて通信量・待ち時間が増える。
- 表示上限に達しない検索や「全件表示」では、多数の候補を調べる必要がある。
- 同期処理が管理画面のタイムアウトに収まらない場合は、進捗表示を伴う分割実行を検討する。
- Jev のしきい値とモデルによって判定結果は変わる。評価後のモデルバージョン固定を検討する。
- Transformer と検索内部関数は本体の変更に影響されるため、MT更新時に検索テストを実行する。
- 標準の文字列一致の位置情報はないため、自然文を本文内で一致文字列として強調する処理は行わない。
- カスタムフィールドなど、他プラグインが追加する検索項目への対応は、初版の標準項目の対応とは別に確認する。

## 参照資料

### MT本体・参考プラグイン

- [MT本体の検索処理](https://github.com/movabletype/movabletype/blob/develop/lib/MT/CMS/Search.pm)
- [MT9管理画面の検索テンプレート](https://github.com/movabletype/movabletype/blob/develop/tmpl/admin2025/cms/search_replace.tmpl)
- [ContentInfoWidget](https://github.com/movabletype/movabletype/tree/develop/plugins/ContentInfoWidget)
- [AI-Assistant](https://github.com/movabletype/mt-plugin-AIAssistant)
- [mt-dev](https://github.com/movabletype/mt-dev)

実装の裏付けは、上記に対応する手元のリポジトリのソースを読んで確認した。設定画面については AI-Assistant の `plugins/AIAssistant/config.yaml`、`plugins/AIAssistant/lib/MT/Plugin/AIAssistant.pm`、`plugins/AIAssistant/tmpl/ai_assistant_system_config.tmpl`、`mt-static/plugins/AIAssistant/src/system_config.ts` を参照した。

### プラグイン開発ガイドの対応章

- [第11章: プラグインの設定](https://github.com/movabletype/Documentation/wiki/Japanese-plugin-dev-3-1)
- [第12章: コールバックとフックポイント](https://github.com/movabletype/Documentation/wiki/Japanese-plugin-dev-3-2)
- [第17章: Transformer](https://github.com/movabletype/Documentation/wiki/Japanese-plugin-dev-4-3)
- [第20章: 動作モードとモーダル](https://github.com/movabletype/Documentation/wiki/Japanese-plugin-dev-5-2)
- [第21章: 外部Web API連携](https://github.com/movabletype/Documentation/wiki/Japanese-plugin-dev-5-3)

ガイドは拡張ポイントの対応資料として挙げている。具体的なレジストリと関数の仕様は、現行の本体・参考プラグインのソースを優先する。

### Jev公式ドキュメント

- [Quick start](https://docs.typesafe.ai/introduction/quickstart)
- [API reference](https://docs.typesafe.ai/api)
- [Primitives](https://docs.typesafe.ai/primitives)
- [Noul / Structured instructions](https://docs.typesafe.ai/primitives/noul)
