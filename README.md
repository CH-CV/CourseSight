# 课见 CourseSight

**课见**是一款用 AI 通用解析高校教务系统课表页面的开源课表 App——不为每一所学校手工适配,让 AI 直接读懂你的课表页面。

> CourseSight is an open-source timetable app that uses AI to universally parse university academic-system schedule pages — no per-school adapters.

[English](#english) | [中文](#中文)

---

## 中文

### 特性

- **AI 通用解析**:粘贴教务系统网址,在内嵌浏览器里登录你的学校账号,一键抓取课表页,AI 自动提取课程/教师/地点/周次——不挑学校、不挑教务系统
- **生成 + 双 Agent 审查**:AI 提交课表后,独立的"审查 Agent"对照原文交叉核对(时间节次 → 周次单双周 → 遗漏核对),纠错必须附带页面原文依据,防止幻觉
- **日常可用**:周课表(单双周/周次切换/今日高亮)、手动增删改课、桌面小组件、课前本地提醒
- **隐私优先**:
  - 账号密码只提交给学校自己的系统,本应用不接触、不存储
- **BYOK**:自带 API Key,支持任何 OpenAI 兼容端点(智谱 / DeepSeek / Kimi / 通义千问 / 硅基流动 / 本地 Ollama)
- **开源**(MIT License)

### 使用步骤

1. 安装 APK(GitHub Releases 下载)
2. 首次启动:选择 AI 服务商并填入 API Key(可用「测试连接」验证)
3. 首页右上角「+」→ 输入教务系统网址 → 登录你的学校账号 → 点「抓取此页并解析课表」
4. 核对解析结果(低置信度会标黄)→ 保存
5. 添加桌面小组件,设置课前提醒

### 开发

```bash
# 环境:Flutter 3.41+ / Android SDK(Dart pub workspaces,根目录一次解析)
flutter pub get
cd packages/coursesight_core && dart test   # 引擎测试
cd apps/app && flutter run                  # 运行 App
flutter build apk --release                 # 签名 APK
```

工程结构:

```
packages/coursesight_core   # 解析引擎(纯 Dart:预处理→整表提交→校验→审查循环→规范化)
apps/app                    # Flutter App
```

### 贡献

欢迎 Issue 与 PR!最值钱的贡献是[各校教务页面样本与解析反馈](#)——遇到解析失败的学校,请在 App 内「导出诊断包」发给我们。详见 [CONTRIBUTING.md](CONTRIBUTING.md)。

### License

[MIT](LICENSE)

---

<a id="english"></a>

## English

**CourseSight** is an open-source timetable app for Chinese university students that uses AI to universally parse academic-system schedule pages — instead of hand-crafting an adapter for every school.

### Features

- **Universal AI parsing**: paste your school's academic-system URL, log in inside the embedded browser, capture the schedule page, and let AI extract courses / teachers / rooms / weeks — works across schools and academic systems
- **Generate + dual-agent review**: after the AI submits a timetable, an independent reviewer agent cross-checks it against the page (times → weeks/odd-even → missing courses). Every correction must cite verbatim evidence from the page to prevent hallucination
- **Daily usability**: weekly grid (odd/even weeks, week switching, today highlight), manual editing, home-screen widget, local pre-class reminders
- **Privacy first**:
  - Credentials go only to your school's own system — this app never sees or stores them
- **BYOK**: bring your own API key; any OpenAI-compatible endpoint (Zhipu / DeepSeek / Kimi / Qwen / SiliconFlow / local Ollama)
- **Open source** (MIT License)

### Getting started

1. Install the APK from GitHub Releases
2. On first launch, pick an AI provider and enter your API key ("Test connection" helps)
3. Tap "＋" → enter your academic-system URL → log in to your school account → "Capture & parse"
4. Review the parsed courses (low-confidence fields are highlighted) → save
5. Add the home-screen widget and set reminders

### Contributing

Issues and PRs welcome! The most valuable contribution is schedule-page samples and parse feedback from your school — use "Export diagnostic report" in the app. See [CONTRIBUTING.md](CONTRIBUTING.md).

### License

[MIT](LICENSE)
