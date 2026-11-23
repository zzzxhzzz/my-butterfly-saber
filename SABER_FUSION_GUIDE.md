# Butterfly + Saber 融合学习版 (Saber Fusion)

基于开源项目 **Linwood Butterfly (`develop`)**，保留其原有的无限画布、图层（Layers）、区域导出（Areas）、WebDAV/Nextcloud 同步与 `.bfly` 文件格式，同时融合 **Saber** 与教材/试卷深度学习工作流的核心能力，适用于 **Windows 电脑** 与 **Android 平板/手机**。

---

## 已融合的 6 大核心功能

1. **智能护眼反色与纸面滤镜（仿 Saber Smart Dark Mode）**
   - 原色纸面、护眼深色反色（白底黑字反转同时保留彩色批注色相）、纯黑反色（OLED）、暖黄护眼纸四种模式一键循环切换。
   - 仅作用于屏幕显示，不污染 `.bfly` 原文件颜色，也不影响 AI 框选截图的原色清晰度。
2. **不遮字荧光笔（Perfect Highlighter）**
   - 采用 `BlendMode.multiply` 正片叠底混合，搭配 Butterfly 原生 `combineId` 笔画防重叠机制：反复涂抹不加深、不发灰，黑色试卷印刷字保持 100% 锐利可读。
3. **PDF 导入增强：教材/试卷快速预设 + 草稿留白 + 大文件懒加载**
   - 内置**原样导入**、**刷卷模式（+50% 右侧草稿区、15% 底部区、48px 页间距）**、**厚教材模式（独立分页 + 35% 笔记栏）**三个一键预设。
   - 支持自定义右侧/底部草稿边距、连续页间距及导出区域是否包含草稿区。
   - 超过 20 页的大型教材 PDF 自动启用按需懒加载缩略图与 LRU 内存释放，秒开不卡顿。
4. **Saber 风格极简刷题工具栏**
   - 一键切换为底部悬浮胶囊笔盒：内置黑/蓝/红/灰草稿笔、黄/绿/粉不遮字荧光笔、橡皮擦、套索、抓手、撤销/重做、上下页快翻，并自动折叠繁杂的辅助栏。
5. **厚教材阅读增强面板（目录 / 页码 / 全文搜题）**
   - **目录（TOC）**：解析 PDF 原生书签树，点击直达对应页面。
   - **页码缩略图**：支持输入页码直达与懒加载页面网格预览。
   - **全文搜题**：后台检索 PDF 内嵌文本并高亮展示摘要片段，点击定位。
6. **AI 框选讲题 + 公式渲染 + 本地错题本**
   - 点击「框选题目问 AI」直接在画布上拖动截图（自动获取原色高清图）。
   - 支持配置 OpenAI / 通义千问 VL / 硅基流动 / Gemini（OpenAI 兼容）/ 本地 Ollama 等多模态视觉模型，API Key 加密保存于系统安全存储。
   - 支持预设提问（分步讲解 / 只给提示 / 批改解答 / 提取考点）与 LaTeX 公式渲染，支持一键**「贴到试卷旁」**（生成可拖动 Markdown 卡片）或**「存入错题本」**（按科目与掌握度分类管理，支持导出 Markdown 或随时贴回画布复习）。
7. **双端局域网同步账号 + 上次页数历史记忆**
   - Windows 与 Android 连入同一 Wi-Fi 后，只需登录同一个「同步账号名 + 同步密码」（无需任何外网服务器），即可通过 UDP 自动发现或手动 IP:端口配对。
   - 任意一端编辑、批注、翻页或存入错题，均可自动/手动双向同步至另一端（离线双端同改会自动保留 `.conflict-...` 备份，不丢批注；错题本按 ID 智能合并）。
   - 自动记录并同步每本教材的**上次阅读页数、页面名与缩放视野**，支持跨端历史记忆列表一键打开续读，同一文档同时打开时还支持远程实时刷新与同步跳转。

---

## 如何用 GitHub Actions 云端打包（本机无需装 Flutter/Android SDK）

仓库中已内置自动化编译工作流：`.github/workflows/saber-fusion-build.yml`。

### 第 1 步：在 GitHub 创建自己的仓库并推送 `saber-fusion` 分支

1. 登录你的 GitHub 账号，新建一个仓库（例如 `my-butterfly-saber`）。
2. 在本机进入 `e:\antigravtiy work\Butterfly` 目录，将远程仓库改为你自己的仓库并推送：

```powershell
cd "e:\antigravtiy work\Butterfly"
git remote set-url origin https://github.com/<你的用户名>/<你的仓库名>.git
git push -u origin saber-fusion
```

### 第 2 步：查看云端编译并下载安装包

1. 打开你的 GitHub 仓库页面，点击顶部 **Actions** 标签页。
2. 等待 **Saber Fusion Build (Windows & Android)** 工作流跑完（约 8~15 分钟，依次执行 `verify` 代码检查测试 -> 并行构建 Android 与 Windows）。
3. 点击已完成的运行记录，拉到页面底部的 **Artifacts** 下载：
   - **`saber-fusion-android-apk`**：内含 `butterfly-saber-fusion-android-arm64.apk`（主流安卓手机/平板推荐，体积更小）与 `butterfly-saber-fusion-android-universal.apk`（通用兼容版）。
   - **`saber-fusion-windows-x64`**：内含 `butterfly-saber-fusion-windows-x64.zip`，解压后直接运行里面的 `butterfly.exe`（或 `start.bat` 便携模式）即可使用。

> 提示：你也可以在 GitHub Actions 页面随时点击 **Run workflow** 手动触发重新打包。
