# refusal-log hook

Claude Code の安全分類器による拒否や自動フォールバックを、JSONL に 1 件 1 行で記録する。
「いつ」「どのセッションで」「直前のプロンプトは何だったか」「どのモデルへ切り替わったか」を後から追えるようにするのが目的。

Claude Code には拒否専用の hook が無いので、既存の 3 イベントを組み合わせている。設定はリポジトリ側の `.claude/settings.json` に置いているので、Claude Code on the Web (CCoW) でもそのまま効く。

## 仕組み

`refusal-log.sh` 1 本で 3 イベントを受け、`hook_event_name` で分岐する。

| イベント | 記録する条件 | 主なフィールド |
|:--|:--|:--|
| `UserPromptSubmit` | すべて記録する（後で `session_id` で突き合わせるため） | `prompt` |
| `PostModelSwitch` | `source == "auto"` のときだけ記録する（自動フォールバックなど、Claude Code 自身が切り替えた場合） | `model`（= `to_model`）、`from_model`、`source` |
| `StopFailure` | `last_assistant_message` が拒否文言に一致するときだけ記録する | `message`、`error` |

StopFailure の `error` 型には refusal を表す値が無い（拒否時にどの型で届くかはドキュメントに書かれていないため、`error` はそのまま記録している）。そのため、型ではなく画面に出た文言で判定している。判定に使う文言は [errors.md](https://code.claude.com/docs/en/errors.md) に載っている 4 種類。

- `<model> can't help with this. Start a new session to continue`
- `... appears to violate our Usage Policy`（v2.1.219 より前の文言）
- `<model>'s safeguards flagged this message` / `... this session`
- `<model> has safety measures that flagged this message for a cybersecurity topic`

このスクリプトは、どんな場合でも **exit 0 で即座に終了し、stdout には何も出さない**。UserPromptSubmit と PostModelSwitch の stdout は Claude の context に入り、UserPromptSubmit の exit 2 はプロンプトを消してしまうためである。入力が壊れていたり、書き込みに失敗したり、jq と python3 が両方とも無かったりした場合は、何も記録せずに終了する。

## ログの形式

出力先は `${CLAUDE_PROJECT_DIR}/.claude/logs/refusal.jsonl`（`.gitignore` 済み）。値が無いキーは出力しない。

```json
{"ts":"2026-09-25T01:23:45Z","event":"UserPromptSubmit","session_id":"…","prompt":"…","transcript_path":"…","cwd":"…"}
{"ts":"…","event":"PostModelSwitch","session_id":"…","model":"claude-opus-4-8","from_model":"claude-opus-5-5","source":"auto","transcript_path":"…","cwd":"…"}
{"ts":"…","event":"StopFailure","session_id":"…","message":"API Error: Opus 4.8's safeguards flagged this message. …","error":"invalid_request","transcript_path":"…","cwd":"…"}
```

- `ts` は UTC の ISO 8601 形式。
- `prompt` は全文を保存する。4000 文字を超える場合は先頭 4000 文字に切り詰め、`"truncated": true` を付ける。
- 拒否の直前に送られたプロンプトは、`session_id` が同じで `ts` がそれより前の `UserPromptSubmit` 行を見れば分かる。

```bash
jq -c 'select(.event != "UserPromptSubmit")' .claude/logs/refusal.jsonl
```

## 環境変数

| 変数 | 意味 |
|:--|:--|
| `REFUSAL_LOG_URL` | 設定されていれば、ローカルに書くのと同じ JSON を POST する。バックグラウンドで送り、タイムアウトは 3 秒、失敗は無視する |
| `REFUSAL_LOG_TOKEN` | 設定されていれば `Authorization: Bearer <token>` を付ける。値は curl の引数ではなく fd 経由で渡す |
| `REFUSAL_LOG_DEBUG=1` | stdin を丸ごと `.claude/logs/refusal-debug.jsonl` に追記する。記録対象外のイベントも含まれる。実際の入力フィールドを確かめるときに使う |
| `REFUSAL_LOG_FILE` | 出力先のファイルを変える |
| `REFUSAL_LOG_NO_JQ=1` | jq があっても python3 版を使う（テスト用） |

URL や token はリポジトリに書かない。CCoW では環境設定の環境変数として渡す。

## テスト

```bash
bash tests/test-refusal-log.sh
```

`tests/fixtures/refusal-log/` のサンプル JSON を入力にして、jq 版と python3 版の両方で次の点を確かめている。

- 期待どおりの JSONL が出ること
- 拒否文言でない StopFailure（`rate_limit`）は記録されないこと
- `source` が `auto` 以外の PostModelSwitch は記録されないこと
- 壊れた入力でも exit 0 で終わり、stdout が空であること
- POST の中身と Bearer ヘッダが正しいこと
- POST 先に届かなくても hook がすぐ返ること

## 既知の限界

- **直前のプロンプトが原因とは限らない。** 分類器は会話全体を見て判定するので、それより前のターンやツールの出力、読み込んだファイルが引き金になっている場合もある。原因を追うときは、記録された `transcript_path` の transcript を読むこと。
- **自動フォールバックが成功した場合、StopFailure は発火しない。** 別のモデルで再実行されて応答が返るので、この場合に残るのは `PostModelSwitch`（`source: "auto"`）の行だけになる。逆に、フォールバック先が無い場合（Opus 5 での biology など）や `availableModels` でフォールバック先が禁止されている場合は、StopFailure の行だけが残る。
- `source: "auto"` はフォールバック専用の値ではない。ドキュメント上は「Claude Code が自分で行ったその他の切り替え」も含むので、拒否ではない行が混じることがある。
- 拒否文言の判定は、ドキュメントに載っている文言との一致で行っている。Claude Code の更新で文言が変わると取りこぼす。そのときは `REFUSAL_LOG_DEBUG=1` で実際の `last_assistant_message` を確かめ、`REFUSAL_RE` を更新する。
- 記録されるのは、hook が有効なこのリポジトリの中で起きたセッションだけ。`claude --safe-mode` では hook 自体が無効になる。
- プロンプトは全文ローカルに残る。機密を含む可能性がある。`REFUSAL_LOG_URL` を設定するとプロンプトが外部にも送られるので、送信先は信頼できるものに限る。
