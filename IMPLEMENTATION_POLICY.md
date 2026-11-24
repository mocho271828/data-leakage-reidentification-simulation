# 模擬漏えい実験の実装方針

**プロジェクト状態**　本番投入前か導入済みかはユーザーに確認中. 既存の出力形式やCLI操作の互換性を変更する場合は, 回答を踏まえて判断する.

実験条件と評価指標の定義は[実験計画](実験計画.md), コマンドと出力の説明は[README](README.md)に記載する. 実装の変更時は次の3項目を確認する.

- [模擬データと比較条件の再現性](policy_gates/reproducibility.md)
- [照合と採点の分離](policy_gates/evaluation.md)
- [依存の利用と出力の保護](policy_gates/implementation.md)

検証時は上の3ファイルを `temp_gates/yyyy-mm-dd-hh-mm-ss/` へコピーし, 各コピーにチェックと判定を記入する. 不合格条件に該当する場合は該当欄にチェックを付け, 判定をNOとする.
