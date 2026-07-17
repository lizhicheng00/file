# IntelliJ IDEA Ordered Dark 配置

一套偏低噪音、强层级、可回滚的 IntelliJ IDEA 配置。当前版本基于 IntelliJ IDEA 2026.1，适用于 Linux；脚本同时兼容 macOS 常见配置目录。

## 配置内容

- `Ordered Dark`：基于 `Islands Dark` 的冷灰深色主题
- JetBrains Mono 14px，编辑器行距 1.2
- 显示行号、缩进导线、右边界、尾随空格和 Sticky Lines
- 关闭悬浮快速文档、动画滚动和预览标签自动替换
- 显示完整路径、修改标记、搜索预览和工具窗口名称
- 项目级 `.editorconfig` 模板

仓库不包含运行配置、账号、数据库口令、证书、BASE64 变量或本机绝对路径。

## 安装

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

## 脚本实际覆盖的文件

```text
options/ui.lnf.xml
options/editor.xml
options/colors.scheme.xml
colors/Ordered Dark.icls
```

脚本不会覆盖 `workspace.xml`、运行配置、插件配置、快捷键或 JDK 设置。
