# IntelliJ IDEA Ordered Dark 配置

一套偏低噪音、强层级、可回滚的 IntelliJ IDEA 配置。以长期内置的 `Darcula` 为兼容基底，不要求 IDEA 提供 `Islands Dark`，支持 Windows、Linux 和 macOS。

## 配置内容

- `Ordered Dark`：基于 `Darcula` 的更深冷灰编辑器主题
- IDEA 整体 UI 强制使用 `Darcula`，不跟随 Windows 浅色模式
- JetBrains Mono 14px，编辑器行距 1.2
- 显示行号、缩进导线、右边界、尾随空格和 Sticky Lines
- 关闭悬浮快速文档、动画滚动和预览标签自动替换
- 显示完整路径、修改标记、搜索预览和工具窗口名称
- 项目级 `.editorconfig` 模板

仓库不包含运行配置、账号、数据库口令、证书、BASE64 变量或本机绝对路径。

## Windows 安装

先完全退出 IntelliJ IDEA，再打开 PowerShell：

```powershell
cd $HOME
git clone https://github.com/lizhicheng00/file.git idea-settings
powershell -ExecutionPolicy Bypass -File "$HOME\idea-settings\install.ps1"
```

脚本会自动选择 `%APPDATA%\JetBrains` 下版本号最新的 IDEA 配置目录。

也可以明确指定目录：

```powershell
powershell -ExecutionPolicy Bypass `
  -File "$HOME\idea-settings\install.ps1" `
  -Target "$env:APPDATA\JetBrains\IntelliJIdea2026.1"
```

安装后重新启动 IDEA，菜单、设置页、工具窗口和编辑器都应为深色。

## Linux / macOS 安装

先完全退出 IntelliJ IDEA。

### 方式一：克隆后自动安装

```bash
git clone https://github.com/lizhicheng00/file.git
cd file
bash install.sh
```

脚本会自动选择最新的 `IntelliJIdea*` 或 `IdeaIC*` 配置目录。

### 方式二：在 IDEA 配置目录中覆盖

```bash
cd ~/.config/JetBrains/IntelliJIdea2026.1
bash /path/to/file/install.sh --target .
```

macOS 的配置目录通常位于：

```text
~/Library/Application Support/JetBrains/IntelliJIdea2026.1
```

### 同时给项目安装 `.editorconfig`

```bash
bash install.sh --project /path/to/your-project
```

## 恢复

安装结束时会输出备份目录。使用该目录恢复：

```bash
bash restore.sh "/path/to/ordered-dark-backups/日期时间"
```

恢复前同样需要完全退出 IntelliJ IDEA。

Windows PowerShell：

```powershell
powershell -ExecutionPolicy Bypass `
  -File "$HOME\idea-settings\restore.ps1" `
  -Backup "安装时输出的备份目录"
```

## 脚本实际覆盖的文件

```text
options/laf.xml
options/ui.lnf.xml
options/editor.xml
options/colors.scheme.xml
colors/Ordered Dark.icls
```

脚本不会覆盖 `workspace.xml`、运行配置、插件配置、快捷键或 JDK 设置。
