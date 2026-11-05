# 実 R2 の検証

通常の `just test` は、認証情報を使わない単体テストを実行する。
実 R2 の検証は別に起動し、専用のランダムなプレフィックスに合成データだけを作る。
既存データの一括削除や、バケットのライフサイクル変更は行わない。

## 条件付き書込みの契約

`scripts/r2_contract_probe.py` は Python 3 の標準ライブラリだけを使う開発用ツールである。
アプリ本体には Python も rclone も必要ない。

アクセスキー ID とシークレットは、所有者だけが読める一時ファイルで渡す。
Git の外に置き、次のキーを持つ JSON を用意する。
値はプレースホルダーであり、実際の値を文書へ転記しない。

```json
{
  "accessKeyID": "S3_ACCESS_KEY_ID",
  "secretAccessKey": "S3_SECRET_ACCESS_KEY"
}
```

```sh
python3 scripts/r2_contract_probe.py \
  --account-id "$S3_MOUNTAIN_R2_ACCOUNT_ID" \
  --bucket "$S3_MOUNTAIN_R2_BUCKET" \
  --credentials-file "$S3_MOUNTAIN_R2_CREDENTIALS_FILE" \
  --allow-test-writes
```

EU 管轄では `--jurisdiction eu` を追加する。
`--allow-test-writes` がない場合は起動しない。
結果は認証情報と既存のオブジェクト名を含まない JSON で表示する。

検査は、条件付き PUT、空キーへのマルチパート完了、既存キーへの完了拒否、同じキーへの競合する完了要求を含む。
既存キーの検査は、この実行で作った sentinel の内容が変わらないことを確認する。
競合する完了要求は、成功がちょうど1件であり、最後の内容が勝者と一致することを確認する。
生成したキーと upload ID だけを `finally` で片付ける。
片付けが失敗した場合は成功扱いにしない。

## Swift の転送コア

`mountain-verify` は、アプリと同じ `S3Client` と `UploadEngine` を呼ぶ開発用の実行ファイルである。
引数は、私有の設定ファイル、合成ファイル、専用のジャーナルディレクトリ、テストプレフィックスの順である。
プレフィックスは `s3-mountain-tests/<UUID>/` とし、通常の保存先には起動できない。

設定 JSON は `accountID`、`bucket`、`jurisdiction`、`accessKeyID`、`secretAccessKey` を持つ。
各実行では新しいジャーナルディレクトリを使い、再開検証の2回目だけ同じディレクトリを使う。

```sh
swift run --package-path Packages/MountainCore mountain-verify \
  /path/to/private-setup.json \
  /path/to/synthetic-file.bin \
  /path/to/new-test-journal \
  "s3-mountain-tests/$TEST_UUID/"
```

再開検証では、パート完了を確認してから検証プロセスだけを強制終了し、同じ引数で再起動する。
保存済みの転送量を引き継ぐことと、ダウンロード後の SHA-256 が元と一致することを確認する。
このツールは完了したオブジェクトを自動削除しないため、検証で作った正確なキーだけを後で片付ける。
認証情報を持つ一時ファイルも検証後に削除する。

実行結果は[検証記録](validation.md)にまとめる。
