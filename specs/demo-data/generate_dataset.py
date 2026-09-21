#!/usr/bin/env python3
"""Generate 1,000 fictional Japanese articles in Movable Type import format."""

import csv
import hashlib
import html
import json
import re
from datetime import datetime, timedelta
from pathlib import Path


ROOT = Path(__file__).resolve().parent
# Topic, system, routine, concrete symptom, cause, remedy, operational detail.
TOPICS = [
    ("国産クラウドへのサイト移行", "国産クラウド上のMovable Type", "広報サイトの記事公開",
     "切り替え後も古いページが表示された", "配信キャッシュの有効期限が旧環境のまま残っていた",
     "キャッシュの更新手順を公開作業に組み込んだ", "画像とHTMLを別々に確認し、切り替え前のURL一覧と照合する"),
    ("Movable Typeの承認フロー", "Movable Typeの段階承認", "複数部署による原稿確認",
     "承認者が不在になると原稿が次へ進まなくなった", "代理担当者に必要な権限を渡していなかった",
     "代理承認者の役割と引き継ぎ手順を決めた", "下書き、差し戻し、公開待ちを分け、担当者が替わっても経緯を追えるようにする"),
    ("災害時の情報発信サイト", "緊急情報用の静的サイト", "避難所の開設情報の掲載",
     "更新した避難所一覧が一部の端末に届かなかった", "平常時と緊急時で配信経路が異なっていた",
     "緊急時の配信経路でも更新確認を行う手順に変えた", "訓練用の情報は実際のお知らせと区別し、更新時刻を一覧の先頭に表示する"),
    ("観光案内サイトの多言語化", "多言語の観光案内CMS", "施設案内の翻訳と更新",
     "日本語を直しても外国語ページに古い営業時間が残った", "翻訳依頼と原稿更新を別の一覧で管理していた",
     "原文の更新と翻訳の確認を同じ管理表にまとめた", "地名は固有名詞の対訳表を参照し、季節営業の施設は次回確認日も記録する"),
    ("図書館イベントの予約受付", "図書館のイベント予約フォーム", "読み聞かせ会の参加受付",
     "定員に達した後も予約が受け付けられた", "残席を更新する処理と受付処理が別々に動いていた",
     "受付と残席確認を同じ処理にまとめた", "保護者と子どもの人数を分け、キャンセル待ちの連絡順も記録する"),
    ("学校サイトのアクセシビリティ", "学校向けの共通ページテンプレート", "保護者向けのお知らせ掲載",
     "キーボード操作では添付資料のリンクまで移動できなかった", "装飾用の要素が操作対象に重なっていた",
     "リンクの構造とフォーカスの順序を見直した", "見出しの順序、画像の代替テキスト、拡大表示を実際のページで確認する"),
    ("会員サイトのログイン", "会員サイトの二段階認証", "会員のログインと登録情報確認",
     "機種変更した会員が認証コードを受け取れなくなった", "旧端末を失った場合の復旧手順が共有されていなかった",
     "本人確認後の復旧窓口と手順を整えた", "通常のログインと端末変更時の問い合わせを分け、対応履歴を残す"),
    ("社内文書の検索", "社内文書の横断検索", "手順書と議事録の探索",
     "新しい手順書より廃止済みの資料が先に表示された", "文書の有効期限が検索対象に反映されていなかった",
     "有効期限と廃止状態を検索用データに反映した", "略語と正式名称を並べて記録し、部署をまたぐ呼び方の違いを確認する"),
    ("店舗情報の一括更新", "複数店舗の情報管理CMS", "臨時休業と営業時間の更新",
     "一店舗の営業時間を変えたところ別店舗の案内も変わった", "店舗を識別する番号が取り込み時に重複していた",
     "店舗番号の重複を取り込み前に検査するようにした", "住所、営業日、臨時休業を別項目にし、店舗ごとに確認者を決める"),
    ("ECサイトの商品画像配信", "商品画像の自動変換と配信機能", "商品写真の登録と差し替え",
     "スマートフォンで商品写真の縦横比が崩れた", "縦長画像を正方形として変換していた",
     "商品写真の比率ごとに変換規則を分けた", "正面写真と細部写真を区別し、回線が細い端末でも順に表示できるか確認する"),
    ("医療機関の診療案内更新", "診療案内ページの更新CMS", "休診日と担当窓口の案内",
     "予約済みの休診案内が予定時刻に公開されなかった", "公開予約の時刻設定が運用側の想定とずれていた",
     "公開時刻の設定と確認担当を統一した", "この事例で扱うのは案内ページであり、診療情報や患者の記録は扱わない"),
    ("展示会サイトの短期公開", "展示会用サイトの複製機能", "会期に合わせた案内サイトの立ち上げ",
     "前回の会場へのリンクが新しい案内に残った", "複製対象に前年の固定リンクが含まれていた",
     "複製直後に会場と日付のリンクを一括点検した", "出展者一覧、会場図、開催日を分け、終了後の案内も事前に用意する"),
    ("採用サイトの応募フォーム", "採用サイトの応募受付フォーム", "応募資料の受付と連絡",
     "添付資料を送った応募者に完了通知が届かなかった", "大きな添付ファイルの処理で通知の待ち時間を超えていた",
     "添付ファイルの処理と受付通知を分けた", "入力途中のエラーと送信完了を区別し、応募者が同じ内容を二重送信しない導線にする"),
    ("バックアップからの復元訓練", "サイトのバックアップと復元機能", "記事と画像の復元訓練",
     "記事は戻ったが本文中の画像が表示されなかった", "画像の保存領域を復元対象に含めていなかった",
     "データベースと画像の保存領域を一組として復元した", "バックアップの取得だけで終わらせず、復元したページを別環境で開いて確認する"),
    ("サイトのアクセス分析", "サイトのアクセス集計機能", "記事ごとの閲覧傾向の確認",
     "一度の閲覧が複数回のアクセスとして集計された", "共通部分と記事本文の両方に計測処理を入れていた",
     "計測処理の設置場所を一か所に統一した", "閲覧数と問い合わせ数を混同せず、社内確認によるアクセスは別に見られるようにする"),
    ("APIを使ったデータ連携", "外部システムとCMSを結ぶAPI連携", "施設一覧の定期取り込み",
     "夜間の取り込みで同じ施設が二重に登録された", "再送されたデータを新規データとして処理していた",
     "施設番号を使って再送時にも同じ記録を更新するようにした", "追加、更新、削除を区別し、取り込み前後の件数を記録する"),
    ("テレワーク用ナレッジ共有", "遠隔勤務向けのナレッジサイト", "引き継ぎ事項と作業手順の共有",
     "担当者ごとに異なる手順書を参照してしまった", "同じ手順の複製が複数の場所に保存されていた",
     "正本の置き場所を決めて複製からリンクする形に変えた", "決定事項と相談中の案を分け、読む人がその場にいなくても経緯を追えるようにする"),
    ("高負荷時のページ配信", "混雑時に備えたページ配信機能", "受付開始日の案内ページ配信",
     "閲覧が集中した時間帯にページの表示が止まった", "静的に配信できる部分まで毎回処理していた",
     "変化しない部分を事前に生成して配信する形に変えた", "案内ページと受付処理を分け、画面が表示されても受付まで進めるか確認する"),
    ("メールマガジンの配信管理", "メールマガジンの配信管理機能", "登録者への更新情報の送信",
     "配信停止を選んだ読者にも次の案内が届いた", "配信対象の一覧を停止処理より前に固定していた",
     "送信直前にも配信停止の状態を確認するようにした", "本文の確認と宛先の確認を別に行い、試験送信には架空の宛先だけを使う"),
    ("環境活動の報告ページ", "環境活動レポートの公開CMS", "拠点ごとの活動報告の掲載",
     "集計表と本文に異なる単位の数値が並んだ", "拠点ごとに記入単位が異なっていた",
     "入力欄に単位を固定し、公開前に集計表と照合した", "取り組みの実施件数と削減量を区別し、推定値には算出方法を添える"),
]

CONTEXTS = [
    ("あさぎ情報室", 4, "二つの拠点を兼務する少人数の体制", "一人が休んでも作業を引き継げること",
     "専任の技術担当者は置かず、通常業務の合間に作業する。画面上の操作だけで手順を説明できるよう、確認用の画像も残した。"),
    ("つむぎ広報室", 7, "出先からスマートフォンで確認する体制", "移動中でも公開前の内容を確認できること",
     "机の前に戻らなくても確認できるよう、小さな画面での表示を重視した。操作の説明では色だけに頼らず、項目の名前も併記している。"),
    ("こもれび制作室", 12, "紙の確認表と画面を併用する体制", "紙と画面で確認した内容が食い違わないこと",
     "すぐには従来の確認表を廃止せず、画面の項目と対応づけた。記録を残す場所が増えすぎないよう、最終確認の結果だけをまとめている。"),
    ("みなと企画室", 18, "平日と週末で担当が交代する体制", "担当が替わっても作業の続きが分かること",
     "引き継ぎのたびに口頭説明を繰り返さなくて済むよう、作業の途中経過を残した。曜日によって扱う件数が異なるため、混み合う日も確認対象にした。"),
    ("しおり運用室", 25, "新任者と経験者が一緒に作業する体制", "初めて触る担当者も同じ手順で進められること",
     "経験者だけが知っている操作を洗い出し、説明の順番を揃えた。研修では完成した画面を見せるだけでなく、新任者自身が一通り操作する時間を設けた。"),
]

SCENARIOS = [
    # Code, launched, actual difficulty, resolved, mentions price, price at end.
    ("S01", True, True, True, True, False),
    ("S02", True, True, True, False, False),
    ("S03", True, False, False, False, False),
    ("S04", False, False, False, False, False),
    ("S05", False, False, False, True, False),
    ("S06", True, False, False, True, False),
    ("S07", True, False, False, True, True),
    ("S08", True, True, True, False, False),
    ("S09", True, True, False, False, False),
    ("S10", True, False, False, False, False),
]

TITLES = ["運用ノート", "担当者の記録", "作業日誌", "現場からの報告", "取り組みのメモ"]
PRICE_WORDS = re.compile(r"料金|費用|月額|年額|予算|コスト|円")


def make_body(topic, context, scenario, topic_index, variant):
    name, system, routine, symptom, cause, remedy, detail = topic
    team, people, arrangement, requirement, background = context
    code, launched, difficulty, resolved, price, tail_price = scenario
    monthly = 6000 + topic_index * 1100 + variant * 700
    price_text = f"契約上の利用料金は月額{monthly:,}円で、初期設定の費用は{monthly * 3:,}円だった。ここではこの二つを分けて記録している。"
    intro = f"{team}では、{routine}を担当している。今回取り上げるのは{system}だ。担当者は{people}人で、{arrangement}をとっている。"
    purpose = f"日々の確認では、{requirement}を重視してきた。{background}"
    procedure = f"確認項目は具体的な作業に沿って整理した。{detail}。画面の見た目だけでは判断せず、担当者が普段扱う内容を使って確かめる方針にした。"
    before, after = 32 + variant * 8, 11 + variant * 3
    smooth = [
        f"{system}はすでに導入を終え、本番で利用している。最初の一か月に実際の作業を通して確認したが、支障なく進んだ。担当者への聞き取りでも、導入後に困ったことはなかった。",
        f"作業時間は以前の約{before}分から約{after}分になった。確認漏れもなく、問い合わせが急増することもなかった。事前に想定したトラブルは実際には発生していない。",
    ]
    if code in ("S01", "S02"):
        progress = [
            f"本番への導入を終えた直後、{symptom}。現場はこの対応に苦労し、予定していた作業を中断した。操作を覚えれば済む話ではなく、普段の業務が進まない状態だった。",
            f"調べると、{cause}ことが分かった。そこで、{remedy}。同じ内容で再度確かめたところ再発せず、現在は通常の作業に戻っている。",
            f"今回の記録には、つまずいた場面と解決までに行った操作を残した。現在の確認作業は約{after}分で終わるが、導入直後の問題がなかったことにはしない。",
        ]
    elif code in ("S03", "S06", "S07"):
        progress = smooth[:]
    elif code == "S04":
        progress = [
            f"現在は導入を検討している段階で、本番ではまだ利用していない。説明用の画面を見ながら、{symptom}場合を想定して質問をまとめた。これは実際に経験した障害の報告ではない。",
            f"特に、{cause}状態を避けられるかを次回確認する。採用を決めた場合には、{remedy}上で試す予定だが、現時点では計画にとどまっている。",
            "導入後の評価を書くには、実際の業務で試す期間が必要になる。今回のメモは比較検討のための論点整理であり、運用実績としては扱わない。",
        ]
    elif code == "S05":
        progress = [
            f"検討会では{system}の操作説明を受けたが、導入は見送った。機能そのものは業務に合っていたものの、継続して支払う金額が今年度の予算に収まらなかった。",
            price_text.replace("だった", "という見積もりだった"),
            f"本番の業務には採用しておらず、運用開始後の障害を経験したわけでもない。いまは従来の方法を続けている。{requirement}という課題は残るため、次年度に範囲を絞って再検討する。",
        ]
    elif code == "S08":
        progress = [
            f"新しい仕組みでの業務を始めて三日目、{symptom}。担当者の手が止まり、確認待ちの仕事が積み上がった。予定した時刻に間に合わず、いったん従来の手順に戻してその日をしのいだ。",
            f"原因は、{cause}ことだった。作業を記録していたため影響した箇所をたどることができ、{remedy}。翌週には待ち行列がなくなり、今は同じ作業を止めずに終えられている。",
            "説明会で画面を見ていたときには気づかなかった点だった。振り返りでは、日常の作業を最初から最後まで試すことが役立ったという声が出た。",
        ]
    elif code == "S09":
        progress = [
            "導入初日の報告には「問題なく利用できた」と書かれていた。説明会での操作だけを確認した時点の評価だった。",
            f"しかし、本番の業務を一週間続けると、{symptom}。予定した処理が進まず、担当者は実際に困っている。最初の報告だけを読むと、この状況が伝わらない。",
            f"{cause}可能性を調べているが、まだ原因を確定できていない。当面は以前の手順を併用し、影響した内容を毎日記録している。現時点で解決済みとは言えない。",
        ]
    else:
        progress = [
            f"{system}は導入済みで、実際の業務は順調に進んでいる。担当者の聞き取りでも、導入後に困ったことや処理の停止は報告されていない。",
            f"研修では「{symptom}ため担当者が困った」という架空の事例を題材にした。これは対応の練習用に作った文章であり、この組織で起きた出来事ではない。",
            "研修資料に問題の記述があることと、実際の運用で問題が起きたことを混同しないよう、振り返りの記録を分けた。本番で同じ事象が起きたという報告はない。",
        ]
    if price and code not in ("S05", "S07"):
        progress.insert(1, price_text)
    paragraphs = [intro, purpose, procedure, *progress]
    if tail_price:
        # S03 and S07 otherwise have identical bodies: only the final paragraph differs.
        paragraphs.append(price_text)
    plain = "\n".join(paragraphs)
    assert bool(PRICE_WORDS.search(plain)) == price, (name, code)
    body = "\n".join(f"<p>{html.escape(p)}</p>" for p in paragraphs)
    return body, len(plain)


def main():
    records = []
    blocks = []
    for ti, topic in enumerate(TOPICS):
        for scenario in SCENARIOS:
            for vi, context in enumerate(CONTEXTS):
                number = len(records) + 1
                article_id = f"JEV-{number:04d}"
                body, characters = make_body(topic, context, scenario, ti, vi)
                date = datetime(2024, 1, 1, 9) + timedelta(hours=((number * 317) % 1000) * 23)
                title = f"{topic[0]}の{TITLES[vi]} — {context[0]} [{article_id}]"
                code, launched, difficulty, resolved, price, tail_price = scenario
                records.append({
                    "id": article_id, "basename": f"jev-demo-{number:04d}", "title": title,
                    "topic_id": f"T{ti + 1:02d}", "topic": topic[0], "scenario": code,
                    "team": context[0], "staff_count": context[1],
                    "launched": int(launched), "actual_difficulty": int(difficulty),
                    "resolved": int(resolved), "mentions_price": int(price),
                    "price_only_at_end": int(tail_price), "body_characters": characters,
                    "date": date.isoformat(sep=" "), "status": "Draft",
                    "body_sha256": hashlib.sha256(body.encode()).hexdigest(),
                })
                blocks.append("\n".join([
                    f"TITLE: {title}", f"BASENAME: jev-demo-{number:04d}", "STATUS: Draft",
                    "ALLOW COMMENTS: 0", "ALLOW PINGS: 0", "CONVERT BREAKS: 0",
                    f"PRIMARY CATEGORY: {topic[0]}", f"DATE: {date:%m/%d/%Y %I:%M:%S %p}",
                    "-----", "BODY:", body,
                    "-----", "EXTENDED BODY:", "", "-----", "EXCERPT:", "",
                    "-----", "KEYWORDS:", "", "-----", "--------", "",
                ]))
    assert len(records) == 1000
    assert len({r["body_sha256"] for r in records}) == 1000
    assert all(r["body_characters"] < 1000 for r in records)
    with (ROOT / "jev-demo-1000.txt").open("w", encoding="utf-8", newline="\n") as stream:
        stream.write("\n".join(blocks))
    with (ROOT / "manifest.csv").open("w", encoding="utf-8-sig", newline="") as stream:
        writer = csv.DictWriter(stream, fieldnames=list(records[0]))
        writer.writeheader()
        writer.writerows(records)
    tests = [
        ("cloud-difficulty", "国産クラウドへのサイト移行で、実際に運用を始めてから困ったことが書かれている記事", lambda r: r["topic_id"] == "T01" and r["actual_difficulty"]),
        ("cloud-no-price", "国産クラウドへのサイト移行で実際に困ったことがあり、料金や費用には一切言及していない記事", lambda r: r["topic_id"] == "T01" and r["actual_difficulty"] and not r["mentions_price"]),
        ("cloud-smooth-no-price", "国産クラウドを導入して問題なく運用できており、料金や費用に言及していない記事", lambda r: r["topic_id"] == "T01" and r["launched"] and not r["actual_difficulty"] and not r["mentions_price"]),
        ("approval-recovered", "Movable Typeの承認フローを導入した後に承認が滞ったが、対処して解決した事例", lambda r: r["topic_id"] == "T02" and r["resolved"]),
        ("backup-unresolved", "バックアップから画像を復元できず、まだ解決していない事例", lambda r: r["topic_id"] == "T14" and r["scenario"] == "S09"),
        ("mobile-library", "スマートフォンで確認する体制の図書館イベント予約で、運用開始後に定員を超えて受け付ける問題が起きた事例", lambda r: r["topic_id"] == "T05" and r["staff_count"] == 7 and r["actual_difficulty"]),
        ("small-cloud", "担当者が5人以下で、国産クラウドへの移行後の問題を解決した事例", lambda r: r["topic_id"] == "T01" and r["staff_count"] <= 5 and r["resolved"]),
        ("price-rejection", "機能は業務に合っていたが、予算に収まらず導入を見送った事例", lambda r: r["scenario"] == "S05"),
        ("actual-not-planned", "APIによるデータ取り込みを本番で始めた後、同じ施設が二重登録された事例。検討段階の想定や研修の架空事例は除く", lambda r: r["topic_id"] == "T16" and r["actual_difficulty"]),
        ("absence-only", "料金、費用、月額、予算について一切言及していない記事", lambda r: not r["mentions_price"]),
    ]
    queries = [{"id": key, "query": query, "expected_count": sum(bool(predicate(r)) for r in records),
                "expected_ids": [r["id"] for r in records if predicate(r)]} for key, query, predicate in tests]
    (ROOT / "queries.json").write_text(json.dumps(queries, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    lengths = [r["body_characters"] for r in records]
    print(f"Generated {len(records)} records; BODY text {min(lengths)}–{max(lengths)} characters, mean {sum(lengths) / len(lengths):.1f}")
    print(f"MT file: {(ROOT / 'jev-demo-1000.txt').stat().st_size:,} bytes")
    print("Query counts:", ", ".join(f"{q['id']}={q['expected_count']}" for q in queries))


if __name__ == "__main__":
    main()
