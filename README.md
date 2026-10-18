# iPaste

macOS 菜单栏小工具：在其它应用里用 **⌘C** 复制成功后，在光标旁闪一下格斗游戏式的「暴击」。

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS 13+](https://img.shields.io/badge/macOS-13%2B-black.svg)](https://github.com/BianYanhui/iPaste/releases)

**下载：** [最新 Release（iPaste.zip）](https://github.com/BianYanhui/iPaste/releases/latest) · 当前 **v0.1.0**

没有 Dock 图标。菜单栏闪电图标即 iPaste。纯 Swift / AppKit，无第三方依赖。

## 它做什么

选中文字或图片，按下并**松开** ⌘C。系统剪贴板的 `changeCount` 真的增加之后，光标上方会短暂炸开一圈「暴击 / CRIT」（大约 0.7 秒），然后消失。

效果是一块不接收鼠标、不能成为键盘焦点的面板，不会把你正在用的应用切走。

这次复制如果没有改变剪贴板（例如没选中任何东西），不会闪。iPaste 自己写入剪贴板时会打上标记，也不会闪。菜单里的「写入剪贴板（不触发暴击）」就是这条路径。

## 安装

1. 从 [Releases](https://github.com/BianYanhui/iPaste/releases/latest) 下载 `iPaste.zip`，解压。
2. 把 `iPaste.app` 拖到「应用程序」。
3. 应用未公证。第一次打开：在 Finder 里**右键 → 打开**，或在终端执行  
   `xattr -dr com.apple.quarantine /Applications/iPaste.app`
4. 点菜单栏闪电图标。若提示需要权限，按下一节打开「输入监视」，然后**退出并重新打开** iPaste。

## 权限

| 能力 | 需要的权限 | 说明 |
| --- | --- | --- |
| 看见 ⌘C 松开 | **输入监视** | 只读的全局事件 tap（listen-only）。不记录其它按键 |
| 确认复制成功 | 不需要辅助功能 | 只看 `NSPasteboard.general.changeCount` 和类型标记 |
| 菜单栏、退出、预览效果 | 不需要 | 普通 `NSStatusItem` |
| 辅助功能 | **MVP 不申请** | 选区坐标、右键菜单「拷贝」留到下一阶段 |

iPaste 不会在启动时弹出权限框。需要时从菜单选「启用 ⌘C 监听…」，说明原因后再调用系统的输入监视请求。

授权对象认的是**代码签名**。用稳定自签证书打出来的 Release，更新后一般不用重新勾选。Xcode 直接 Run 是 ad-hoc 签名，每次重新编译可能都要再勾一次。正式使用请装 Release 包。

路径：**系统设置 → 隐私与安全性 → 输入监视**。

## 本地开发

用 Xcode 16+ 打开 `iPaste.xcodeproj`，scheme 选 **iPaste**，Run。要求 macOS 13+。

```bash
python3 Support/scripts/selftest_update_logic.py
xcodebuild -project iPaste.xcodeproj -scheme iPaste -configuration Debug -destination 'platform=macOS' build
```

跑起来之后：

1. 菜单栏出现闪电，Dock 里没有图标。
2. 「预览暴击效果」应在当前光标旁闪一下，焦点仍留在原来的应用。
3. 在任意应用里选中文字或图片，按下并松开 ⌘C。剪贴板变化后出现暴击。
4. 「写入剪贴板（不触发暴击）」会改掉剪贴板，但不会出现暴击。紧接着的一次真正 ⌘C 仍会闪。

本地调试签名是 ad-hoc。要用稳定身份，把 `docs/CODE_SIGNING.md` 里的证书导入登录钥匙串后：

```bash
codesign --force --deep --sign "iPaste Self-Signed" --timestamp=none /path/to/iPaste.app
```

## 更新

菜单「检查更新…」从本仓库的 GitHub Releases 下载 `iPaste.zip`。

替换正在运行的 `.app` 会拆掉进程背后的文件，随后系统回调可能 SIGBUS（iReader 遇到过的问题）。iPaste 的安装脚本会：

1. 先把新版本解到临时目录并核对 Bundle ID 与版本号，不碰正在运行的包。
2. 等 iPaste 进程完全退出，再多等 1.5 秒。
3. 把新包放到旁边的 `iPaste.app.new`，然后改名换上。
4. 保留 CI 打上的签名，不再 ad-hoc 重签（重签会换掉 cdhash，「输入监视」就丢了）。

从 `/var/folders`、`/tmp` 或 App Translocation 启动时，新版本会装到 `/Applications`（没有写权限则装到 `~/Applications`）。

手动覆盖时也一样：**先退出 iPaste，再替换** `.app`。日志在 `~/Library/Logs/iPaste-update.log`。

版本号要一起改两处（Debug / Release 保持相同）：

- `MARKETING_VERSION` → `CFBundleShortVersionString`（例如 `0.1.0`）
- `CURRENT_PROJECT_VERSION` → `CFBundleVersion`（例如 `1`）

都在 `iPaste.xcodeproj/project.pbxproj`。

## 发版

和 HisCopy 一样：合并到 `main` 之后打 `v*` 标签，GitHub Actions 构建通用二进制、签名、打成 `iPaste.zip` 并挂到 Release。这个 PR 本身不打标签。

先配好签名密钥（没有密钥时，**标签构建会失败**，避免发出 ad-hoc 包）：

| Secret | 内容 |
| --- | --- |
| `IPASTE_SIGNING_CERTIFICATE_P12` | 证书 PKCS#12 的 base64。证书 CN 必须是 `iPaste Self-Signed` |
| `IPASTE_SIGNING_CERTIFICATE_PASSWORD` | 导出该 `.p12` 时你自己设的密码 |

生成方法和轮换步骤见 [docs/CODE_SIGNING.md](docs/CODE_SIGNING.md)。仓库里没有、也不应该有真实的证书或密码。

```bash
# 两个版本号都改完并合并到 main 之后
git tag v0.1.0
git push origin v0.1.0
```

Actions 会在该标签上创建 Release，附件名为 `iPaste.zip`。

## 代码签名

Release 使用稳定自签身份 **`iPaste Self-Signed`**，不是每次都变的 ad-hoc。这样「输入监视」可以在更新后继续认同一份应用。细节见 [docs/CODE_SIGNING.md](docs/CODE_SIGNING.md)。

未公证。第一次打开用右键「打开」，或清掉 quarantine 扩展属性（见上面的安装步骤）。

## 这一版没做

- **辅助功能选区坐标**（阶段 2）：暴击目前跟 `NSEvent.mouseLocation`（光标），不是选中文字的包围盒。
- **右键菜单里的「拷贝」**：只认键盘 ⌘C 松开，不追菜单命令。
- 开机启动、复制历史、自定义效果。

## License

MIT
