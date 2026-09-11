# QuickSave

macOS 菜单栏小工具：随时选中一段文字，按 `⌘⌥S`，文本立即保存为 `.txt` 到 `~/docs`（目录不存在会自动创建）。也可以把剪贴板里的文本一键存为文档。

保存成功后屏幕右上角会弹出提示条并伴随提示音（不依赖系统通知权限），菜单栏图标短暂变为 ✅。

## 下载安装

**方式一：下载编译好的版本**（无需 Xcode）

1. 到 [Releases](https://github.com/snowbitx/QuickSave/releases) 下载 `QuickSave.zip`，解压得到 `QuickSave.app`，拖入「应用程序」文件夹。
2. 首次打开：应用未做公证，直接双击会被 Gatekeeper 拦截。在「应用程序」里**右键 → 打开 → 再点打开**；或在终端执行：
   ```bash
   xattr -cr /Applications/QuickSave.app
   ```
3. 首次启动会自动跳转到系统授权面板，在 **系统设置 → 隐私与安全性 → 辅助功能** 中勾选 QuickSave（读取选中文本必需）。

**方式二：从源码构建**

```bash
git clone https://github.com/snowbitx/QuickSave.git
cd QuickSave
make launch
```

## 使用

1. `make launch` 启动（或双击 `build/QuickSave.app`），菜单栏出现 📄 图标。
2. 在任意应用中选中文字，按 `⌘⌥S`。
3. 系统通知提示保存结果；点击菜单栏图标可查看最近保存的文件名、打开存储目录。

菜单项：

| 菜单项 | 作用 |
|---|---|
| 保存目录：~/docs | 显示当前存储目录（不可点击） |
| 立即捕捉选中文本（⌘⌥S） | 等价于全局快捷键 |
| 将剪贴板文本存为文档 | 保存剪贴板文本，不覆盖剪贴板 |
| 最近保存：… | 上一次保存的文件名 |
| 打开存储目录 | 在访达中打开 ~/docs |
| 开机自动启动 | 开关登录项（SMAppService） |
| 授权辅助功能权限… | 打开系统设置授权面板 |
| 通知设置… | 打开系统设置通知面板（可选，开启系统通知） |
| 退出 QuickSave | ⌘Q |

## 工作原理

保存一条文本时按优先级尝试两种方式：

1. **辅助功能 API**（`kAXSelectedTextAttribute`）：直接读取当前焦点控件中的选中文本，不碰剪贴板。适用于大部分原生应用（TextEdit、Safari、备忘录等）。
2. **剪贴板回退**：模拟 `⌘C`，轮询剪贴板变化后读取，并恢复原有剪贴板内容。适用于 Chrome、微信等不暴露选中文本的应用（这类应用要求输入焦点在文本框内）。

文件命名：`yyyy-MM-dd_HHmmss_首行前20字.txt`，同名自动追加 `_2`、`_3` 序号。非法文件名字符会被替换为空格。

需要权限：**系统设置 → 隐私与安全性 → 辅助功能** 中勾选 QuickSave（首次启动会自动打开该面板）。

## 构建

依赖：Xcode Command Line Tools（`swiftc`）。

```bash
make          # 编译到 build/QuickSave.app（ad-hoc 签名）
make launch   # 编译并启动
make install  # 安装到 /usr/local/bin（PREFIX 可覆盖）
make clean
```

## 配置

存储目录名默认 `docs`，可通过 UserDefaults 修改后重启应用：

```bash
defaults write com.wangxiaoyu.quicksave saveDirName Documents
```

快捷键固定为 `⌘⌥S`；如需修改，改 `Sources/main.swift` 中的 `hotKeyCode` / `hotKeyModifiers` 后重新 `make`。

## 调试

无需键盘即可触发一次捕捉（用于自动化测试）：

```bash
notifyutil -p com.wangxiaoyu.quicksave.capture
```

## 项目结构

```
QuickSave/
├── Sources/main.swift   # 全部逻辑：菜单栏、捕捉、保存、热键
├── Resources/Info.plist # LSUIElement（不显示 Dock 图标）
└── Makefile             # swiftc 直接编译，无 Xcode 工程依赖
```
