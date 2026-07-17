# IntelliJ IDEA 2025.3 Islands Dark

这是仅面向 Windows 与 IntelliJ IDEA 2025.3 的干净主题脚本。

它只做四件事：

1. 固定 IDEA 界面主题为内置 `Islands Dark`。
2. 固定编辑器配色为内置 `Islands Dark`。
3. 关闭跟随 Windows 明暗模式。
4. 备份原文件，并清理旧版脚本创建的 `Ordered Dark` 配色文件。

不会修改快捷键、插件、JDK、项目、运行配置或代码格式。

## 安装

先启动一次 IntelliJ IDEA 2025.3，让它生成配置目录，然后完全退出 IDEA。

打开 PowerShell：

```powershell
cd $HOME
git clone https://github.com/lizhicheng00/file.git idea-2025.3-theme
cd idea-2025.3-theme
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

脚本固定写入：

```text
%APPDATA%\JetBrains\IntelliJIdea2025.3
```

如果你的目录不同，可以明确指定：

```powershell
powershell -ExecutionPolicy Bypass `
  -File .\install.ps1 `
  -Target "D:\path\to\IntelliJIdea2025.3"
```

安装成功后脚本会显示配置目录、备份目录，以及两个经过校验的主题名称。

## 恢复

完全退出 IDEA，然后执行：

```powershell
powershell -ExecutionPolicy Bypass `
  -File .\restore.ps1 `
  -Backup "安装时显示的备份目录"
```

## 手动确认

启动 IDEA 后打开 `Settings`：

```text
Appearance & Behavior → Appearance
Theme: Islands Dark
Sync with OS: Off
Editor color scheme: Islands Dark
```

IntelliJ IDEA 2025.3 官方说明确认该版本引入 Islands 并将其作为默认主题；界面主题和编辑器配色是两个独立设置：

- https://www.jetbrains.com/idea/whatsnew/2025-3/
- https://www.jetbrains.com/help/idea/configuring-colors-and-fonts.html
