# mt:JevEntries 実装計画

作成日: 2026-09-21

2026-09-22追記: ユーザーの指示により、このMTタグの実装は保留。先に[管理画面の自然言語検索への置き換え](natural-language-search-implementation-plan.md)を進める。本書の全件評価方式は、タグの再開時に見直す。

## 作るもの

既存の Jev プラグインに、記事を自然文で評価して関連度順に出力するブロックタグ `mt:JevEntries` を追加する。ハンドラーが候補記事を取得し、Jev の **Score** で全候補を評価した後、上位記事を `entries` のstashへ渡し、標準の `mt:Entries` に描画を委譲する。

RAG、埋め込み、検索インデックスは使用しない。本文と検索条件を記事ごとに直接評価し、複数記事の質問を1リクエストにまとめる。これは実装計画であり、この段階ではプラグインの機能コードは変更しない。

## 決定事項と初版の提案

ユーザーから指定された要件:

- 記事のみを対象とする。コンテンツデータは扱わない。
- `query` 属性で検索条件を指定する。
- `limit` 属性で出力件数を指定する。省略時は3件。
- 条件に一致する記事のうち、関連度が高い順に上位 `limit` 件を出力する。
- 既存検索の Noul（一致する確率）ではなく、**Scoreで関連度を別に採点する**。
- 候補の取得と評価は独自ハンドラーで行い、出力はstash経由で `mt:Entries` に委譲する。

以下は初版の提案値・範囲であり、ユーザーの指定事項とは分けて扱う。

| 項目 | 初版の案 |
| --- | --- |
| 対象サイト | テンプレートの現在のサイト／ブログのみ。子サイトを自動的に含めない |
| 対象記事 | `class=entry`、`status=RELEASE`。ページ・下書き・予約状態の記事を含めない |
| 評価する内容 | タイトル、概要、本文、追記。HTMLは既存の `MT::Plugin::Jev::Content::plain_text` で文字列化 |
| アーカイブとの関係 | 現在のカテゴリー・月・外側のEntriesによって候補を暗黙に限定せず、対象サイト全体から取得 |
| 現在の記事自身 | 特別な除外はしない。条件に合えば候補に含む |
| 実行環境 | Perlによる静的公開・プレビュー。PHPのダイナミックパブリッシングは初版の対象外 |
| 関連度 | Scoreの5段階、0〜4 |
| 一致の下限 | Scoreが3以上。タグ用のプラグイン設定で調整可能 |
| 同点 | 記事IDの昇順。返却順やDBの取得順に依存させない |
| 処理時間 | タグ1回の評価に300秒を初期値とし、タグ用設定で変更可能 |
| キャッシュ | 初版では永続キャッシュや非同期ジョブを追加しない。呼び出すたびに評価 |

## タグの仕様と使用例

```mtml
<mt:JevEntries query="導入後に困ったことと、その解決方法が書かれた記事" limit="3">
  <mt:EntriesHeader><ul></mt:EntriesHeader>
  <li>
    <a href="<$mt:EntryPermalink encode_html="1"$>"><$mt:EntryTitle encode_html="1"$></a>
  </li>
  <mt:EntriesFooter></ul></mt:EntriesFooter>
<mt:Else>
  <p>該当する記事はありません。</p>
</mt:JevEntries>
```

| 属性 | 必須 | 仕様 |
| --- | --- | --- |
| `query` | 必須 | 自然文の検索条件。前後の空白を除き、未指定・空文字はタグエラー |
| `limit` | 任意 | 1以上の整数。省略時のみ3。0・負数・小数・`all`・空文字などはエラー |

`limit` は出力件数であり、APIに送る候補件数ではない。一致記事が2件なら2件、0件なら `mt:Else` を出力する。順位決定のために全候補の評価を完了する必要があり、3件見つけた段階では打ち切らない。

初版では `mt:Entries` の全検索属性を継承しない。`sort_by`、`sort_order`、`offset`、`lastn`、`include_blogs`、カテゴリーやタグの絞り込みなどは対象外とし、指定された場合は未対応属性としてエラーにする。MT共通のグローバルモディファイアとは区別する。渡された属性一式をそのまま標準ハンドラーへ渡さず、委譲用の属性を新しく作る。

## 使う拡張ポイントと参考例

| 用途 | 拡張ポイント・処理 | 参考資料 |
| --- | --- | --- |
| タグ登録 | `config.yaml` の `tags.block.JevEntries` | 公式開発ガイドのブロックタグ登録例 |
| ハンドラー | `$Jev::MT::Plugin::Jev::Tags::entries`、引数 `($ctx, $args, $cond)` | 現行MTのタグハンドラー |
| 出力の委譲 | `entries` のstashと `$ctx->invoke_handler('Entries', …)` | `MT::Template::Tags::Entry::_hdlr_entries` |
| システム設定 | 既存の `settings`、`system_config_template`、`save_config_filter.Jev` | AI-Assistantの設定画面と、実装済みJev設定画面 |
| API接続・本文処理 | 既存の `MT::Plugin::Jev::Client`、`MT::Plugin::Jev::Content` | 現在のJev検索実装 |

タグを登録する標準の拡張ポイントがあるため、CMS検索で使用している関数ラップは使わない。参考例カタログには今回の順位付きEntries委譲に直接対応するプラグインがないため、委譲の仕様はMT本体を一次資料とする。設定画面の構成は既存どおりAI-Assistantを参考にする。

公式の[タグ登録ガイド](https://movabletype.org/documentation/developer/declaring-template-tags.html)は `tags.block` と3引数のブロックハンドラーを説明している。スキル内の旧日本語ガイド第8章のURLは取得できなかったため、公式英語版と手元のMT9ソースで確認した。

## Scoreの評価方法

TypeSafeのScoreは、説明文を付けた順序付き段階を評価し、その位置を返す仕組みである。順位には返却値 `score` を使用し、判定の確信度である `confidence` は使用しない。[Score公式仕様](https://docs.typesafe.ai/primitives/score)

初版では各記事に同じ5段階の基準を適用する。以下はAPIへ渡す説明文の意味であり、実際の文面は少量の日本語データで検証して固める。

| Scoreの段階 | 評価基準案 |
| --- | --- |
| 0 | 検索条件に関係がない、または明示された条件・否定条件に反する |
| 1 | 同じ語や周辺の話題はあるが、求められた内容を扱っていない |
| 2 | 求められた内容の一部を扱うが、重要な条件の充足が不足・不明確 |
| 3 | 検索条件を満たす内容が明示されている |
| 4 | 検索条件を満たす内容が記事の中心で、具体例や説明が十分にある |

- `state.search_condition` に `query` を置く。
- 質問IDを `entry_<記事ID>` とし、記事ごとに `type: score` の質問を作る。
- `instructions` に評価対象の4項目と問いを置く。本文中の指示には従わず、本文を評価対象データとして扱うよう指定する。
- **`criteria` は質問オブジェクト直下の配列**として5段階を渡す。全記事・全バッチで同じ文面を使う。
- 返却された `score` が0〜4の有限数であることを確認する。小数を丸めず順位としきい値の比較に使う。
- 既定では `score >= 3` の記事を一致とする。3件に満たなくても、不一致の記事で穴埋めしない。
- IDの過不足、不正な型、範囲外の値はエラーとする。`legend`、`probabilities`、`confidence` は初版の順位計算には使わない。

ScoreとNoulでは値の意味が違うため、CMS検索の `jev_threshold`（0〜1）をタグの下限設定へ流用しない。既存の `evaluate_batch` とCMS検索はNoulのまま維持する。[Noul公式仕様](https://docs.typesafe.ai/primitives/noul)

## 候補取得とランキング

1. `query`、`limit`、サイトコンテキスト、設定、APIキーを検証する。サイトが不明な場合に全サイト検索へ広げない。
2. `MT->model('entry')` から現在の `blog_id`、`class=entry`、`status=RELEASE` を条件にイテレーターで取得する。DB側の取得に出力用 `limit` や検索文の部分一致条件を付けない。
3. タイトル・概要・本文・追記を評価用に変換する。管理画面の権限・検索API定義・ログインユーザーを必要とする `MT::Plugin::Jev::Search` は呼ばない。
4. `jev_batch_size` 件ずつ `MT::Plugin::Jev::Client::evaluate_relevance_batch` へ渡す。本文サイズによる追加分割は既存クライアントと共通化する。
5. 各バッチの回答から下限以上の候補を現在の上位候補へ加え、Score降順・ID昇順で上位 `limit` 件を保持する。全本文をまとめて保持せず、プラグインが保持する記事配列をバッチ分と上位分に抑える。
6. 最終バッチまで成功した後に、順位付きの記事配列を描画処理へ渡す。途中の失敗時は上位候補を破棄してタグエラーを返す。

公開用テンプレートではCMSのログインユーザーを前提にできないため、送信対象は公開済み記事に限定する。APIキーや送信本文をエラー文へ含めない。

## mt:Entriesへの委譲と順序の保持

本体の `_hdlr_entries` は、プラグインが用意した記事配列を `entries` のstashから読み込む実装になっている。ただし、`archive_type` がある場合は、その配列も日付順などへ並べ直す。単に関連度順の配列をstashへ置くだけでは、記事アーカイブ上の順位を維持できない。

委譲は次の方針とする。

1. 上位の記事配列を、`local $ctx->{__stash}{entries}` で委譲スコープに限って設定する。
2. 実効アーカイブ種別（`current_archive_type` があればそれ、なければ `archive_type`）を、`local` な `current_archive_type` に保持する。
3. 同じスコープで `archive_type` を一時的に未定義にする。`sort_by`／`sort_order` も渡さず、標準処理の再ソートを避ける。
4. `limit` のみを持つ新しい属性ハッシュで `Entries` ハンドラーへ委譲する。トークンと条件コンテキストを引き継ぐ。
5. 成功・エラーのどちらでも、外側の `entries`、`archive_type`、`current_archive_type` を元に戻す。

0件の場合も **空の配列参照 `[]`** をstashへ渡す。`undef` にすると標準処理が記事を再取得する可能性がある。`mt:Else`、`mt:EntriesHeader`／`Footer`、`__counter__`、記事タイトルやパーマリンクなどの描画は標準処理へ任せる。

この方法はMT内部の再ソート条件に依存するが、関数の置き換えは不要。実装時には `mt:ArchiveType`、`mt:ArchiveLink`、ネストしたEntries、外側への復元を検証する。`archive_type` を直接参照する第三者タグとの互換性は別途確認が必要になる。

### 今回確認した範囲

手元のMT9ソースに対する一時的な検証で10件が成功した。確認したのは、未調整のアーカイブでは日付順になること、調整後はインデックス／記事／月別／カテゴリーで配列順を維持すること、`ArchiveType`・ヘッダー／フッター・カウンター・外側の種別の復元、空配列時のElseである。これは標準Entriesの動作確認であり、新タグやScore API接続の実装・検証ではない。

## 設定とタイムアウト

既存のAPIキー、モデル、バッチ件数を使用し、システムのプラグイン設定へタグ用の2項目を追加する案とする。

| 設定キー | 内容 | 初期値案 | 検証 |
| --- | --- | --- | --- |
| `jev_entries_min_score` | JevEntriesの一致とする最小Score | `3` | 0〜4の有限数 |
| `jev_entries_timeout` | JevEntriesの評価時間上限（秒） | `300` | 1以上の整数 |

期限はタグの候補評価開始時に1回だけ決め、全バッチと再試行で共有する。バッチごとに期限を延長しない。既存のCMS検索の45秒制限は変更しない。

1通信10秒、HTTP 429／529の限定再試行、1記事24,000バイト／1リクエスト48,000バイトという現在のクライアント側上限は共用する。Scoreの基準文もサイズ計算に含める。これらのバイト数と最大50件の設定範囲はプラグイン側の制限であり、サービス側の公称上限ではない。

長すぎる本文は既存と同じくエラーにし、黙って切り詰めない。タグにない「項目を指定する」「日付範囲」へ誘導するCMS向けのエラー文は、タグ用に適切な文面へ置き換える。

## 1万件を評価する場合

**全件評価して上位を出すデモは可能な構成だが、1万件の実用性は未測定。現在の5件バッチ・同期通信のまま、短時間で完了することは期待しない。**

評価件数を `N`、実際に1回へ入る記事数を `B`、1通信の平均所要時間を `T` とすると、追加分割・再試行がない場合の通信回数は `ceil(N / B)`、直列通信時間の概算は `ceil(N / B) × T` になる。`limit=3` にしてもこの件数は減らない。

以下は **1通信を仮に1秒と置いた計算例**。APIの実測値や性能保証ではない。

| 記事数 | 5件／通信 | 50件／通信 |
| --- | --- | --- |
| 100 | 20回／20秒 | 2回／2秒 |
| 1,000 | 200回／3分20秒 | 20回／20秒 |
| 10,000 | 2,000回／33分20秒 | 200回／3分20秒 |

本文と評価基準が48,000バイトに収まらなければさらに分割されるため、設定を50件にしても実効 `B` が50になるとは限らない。応答時間、レート制限、本文量を含めた実測が必要になる。TypeSafeは同一リクエスト内の質問を並列評価すると説明しているが、それを記事数に対する無制限のスループット保証とは扱わない。[複数質問の公式説明](https://docs.typesafe.ai/primitives#ask-multiple-questions-together)

最初のデモは、100件程度の候補と単一インデックステンプレートから始める。100件→1,000件→10,000件と増やして、通信数、入力サイズ、合計時間、失敗率を測る。長い再構築はCLI／バックグラウンド処理を使う前提とし、タグの上限とは別に、実行環境側のタイムアウトも確認する。

特に、1万件の各記事テンプレートで毎回1万件を評価すると、全件再構築で **1億件分の評価** になる。同じqueryの結果を多数ページへ載せる場合は、1回だけ静的出力して共有する使い方を先に検討する。異なるqueryを大量に実行する運用が必要になった段階で、結果キャッシュ、事前計算、制限付き並列実行を別の拡張として設計する。初版で候補を勝手に先頭数百件へ切り詰めることはしない。

## ファイル構成と実装ステップ

| ファイル | 変更内容 |
| --- | --- |
| `plugins/Jev/config.yaml` | `tags.block.JevEntries` → `$Jev::MT::Plugin::Jev::Tags::entries`、タグ用設定と翻訳の登録 |
| `plugins/Jev/lib/MT/Plugin/Jev/Tags.pm`（新規） | 入力検証、公開記事の走査、上位選択、stashとEntriesへの委譲 |
| `plugins/Jev/lib/MT/Plugin/Jev/Client.pm` | `evaluate_relevance_batch` の追加。ScoreとNoulで通信・分割・再試行を共通化し、回答検証を型ごとに分ける |
| `plugins/Jev/lib/MT/Plugin/Jev/Content.pm` | 既存 `plain_text` を使用。記事用4項目の変換を必要に応じてCMS非依存のヘルパーへ分離 |
| `plugins/Jev/lib/MT/Plugin/Jev.pm` | タグ用設定の値検証を追加 |
| `plugins/Jev/tmpl/system_config.tmpl` | タグ用のScore下限・評価時間設定を追加 |
| `plugins/Jev/t/tags.t`（新規） | MTテンプレートから新タグを実行する結合テスト |
| `plugins/Jev/t/client.t`、`config.t` | Score契約・不正回答・既存Noul互換性・設定保存を検証 |
| `plugins/Jev/xt/entries-live.t`（新規） | 明示実行する少量の日本語Score評価。キーがなければスキップ |
| `README.md` | 使用例、対象範囲、設定、再構築時の全件評価と負荷を説明 |

実装順序:

1. Scoreの質問形式と回答検証をクライアントへ追加し、Noulの既存テストが通ることを確認する。
2. タグ用設定と検証を追加する。新設定が未保存でも既定値が適用されるようにする。
3. `MT::Plugin::Jev::Tags::entries` とタグ登録を追加し、モック回答で全候補評価・しきい値・上位選択を確認する。
4. stashへの設定と標準Entriesへの委譲を実装し、アーカイブでの順序維持とコンテキスト復元を確認する。
5. 日本語の固定データでScore基準を確認し、その後に件数を増やした計測へ進む。計測に使うデータとAPI利用量は実行前に明らかにする。
6. READMEを更新し、既存のComposeビルドで追加モジュールが配布物へ入り、テストは除外されることを確認する。

## 動作確認・受け入れ条件

- `query` 未指定／空、`limit` 不正、サイト未確定、APIキー未設定を検出し、不要なAPI呼び出しを行わない。
- `limit` 未指定で最大3件、指定時は最大指定件数を返す。候補の取得件数には影響しない。
- 最後のバッチに最高Scoreの記事を置いても先頭へ表示される。低Scoreを除外し、小数・同点・0件・候補不足を扱える。
- 下書き、予約状態、別サイト、ウェブページ、コンテンツデータを送信しない。
- 投稿順や公開日と異なるScore順で表示され、記事・月別・カテゴリーアーカイブでも順序を維持する。
- `EntryTitle`、`EntryPermalink`、`EntriesHeader`／`Footer`、`__counter__`、`Else` が動作する。
- 空の結果が標準記事の再取得につながらない。外側のEntriesとアーカイブコンテキストへ影響を残さない。
- API失敗・期限超過・不正回答を0件や「評価済み範囲の上位」として表示しない。
- Scoreのリクエスト形式、0〜4の回答検証、サイズ分割、共通期限を確認する。
- CMS検索のNoul、45秒制限、既存設定・ヘッダー検索が従来どおり動作する。
- 日本語の実API確認では、無関係・周辺の話題・一部一致・明確な一致・中心的な話題の例を比較する。モックの順位テストとモデルの判定品質を分けて評価する。

## 参照資料

- [MT公式: Declaring Template Tags](https://movabletype.org/documentation/developer/declaring-template-tags.html)
- [MT本体: Entriesハンドラー](https://github.com/movabletype/movabletype/blob/bc30df924abe7bcc9089295483b5c88bfd09bfec/lib/MT/Template/Tags/Entry.pm#L291) — stashの利用、公開状態、空配列、アーカイブ時の再ソート、出力ループを確認。
- [MT本体: invoke_handler](https://github.com/movabletype/movabletype/blob/bc30df924abe7bcc9089295483b5c88bfd09bfec/lib/MT/Template/Context.pm#L233)
- [MT本体: ArchiveType](https://github.com/movabletype/movabletype/blob/bc30df924abe7bcc9089295483b5c88bfd09bfec/lib/MT/Template/Tags/Archive.pm#L1081)
- [AI-Assistant](https://github.com/movabletype/mt-plugin-AIAssistant) — 手元のシステム設定・設定保存・テンプレートを参照。
- [TypeSafe API](https://docs.typesafe.ai/api)
- [TypeSafe Score](https://docs.typesafe.ai/primitives/score)
- [TypeSafe Noul](https://docs.typesafe.ai/primitives/noul)
- [TypeSafe: 複数質問](https://docs.typesafe.ai/primitives#ask-multiple-questions-together)
