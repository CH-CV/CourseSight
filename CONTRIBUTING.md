# 贡献指南 / Contributing

## 报告解析失败(最有价值的贡献)

1. 在 App 内复现失败后,点击「导出诊断包」,把生成的 JSON 发到 Issue 或用户群
2. 诊断包含脱敏后的页面内容与解析过程信息,**不含** API Key 与任何账号密码
3. Issue 请注明:学校、教务系统名称(如正方/强智/URP)、现象

## 开发

- 环境:Flutter 3.41+,Android SDK
- 仓库是 Dart pub workspace:`flutter pub get` 在根目录执行一次即可
- 引擎改动必须通过 `packages/coursesight_core` 的测试:`dart test`
- 提交信息遵循 Conventional Commits(feat/fix/docs/...)

## 提交 PR

1. Fork → 分支 → 改动 → 确保分析零告警、测试全绿
2. 描述改动原因与影响面
3. 首次贡献请按 DCO 在提交信息中带 `Signed-off-by`(`git commit -s`)
