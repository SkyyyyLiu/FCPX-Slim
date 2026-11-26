# FCPX Slim

## [⬇ 下载 FCPX Slim 0.9.6](https://github.com/SkyyyyLiu/FCPX-Slim/releases/download/v0.9.6/FCPX-Slim-0.9.6-arm64.zip)

Apple 芯片版 ZIP，需 macOS 14 或更新版本。解压后将 `FCPX Slim.app` 拖到「应用程序」。[首次打开说明](INSTALL.md) · [版本发布页](https://github.com/SkyyyyLiu/FCPX-Slim/releases/tag/v0.9.6)

FCPX Slim 是胡子盖制作的专为 Final Cut Pro 工程文件进行瘦身的工具。它在 Mac 上扫描 `.fcpbundle`，列出渲染文件、转码缓存和可替换为库外链接的重复原始素材。

## 安装

参见[下载与首次打开说明](INSTALL.md)。

## 使用

需要搭载 Apple 芯片且运行 macOS 14 或更新版本的 Mac。

1. 将资源库拖到窗口，或点击「加载」选择资源库或工程文件夹。
2. 点击「扫描」，展开「明细」核对勾选项。扫描只读取文件。
3. 选择「清理」将所选项目移到系统废纸篓。「撤销清理」可恢复清理批次。使用「永久删除」前请核对确认面板中的项目。
4. 用「导入 FCP」在 Final Cut Pro 中打开所选资源库。

分析文件保留。重复素材仅在库外找到唯一、内容一致的副本时才会列为可处理项。关闭 Final Cut Pro 后才能执行清理或恢复。

## 从源码构建

安装 Apple Command Line Tools 后，在仓库目录运行：

```sh
zsh build.sh
zsh test.sh
```

构建产物位于 `build/FCPX Slim.app`，使用本地临时签名。测试中的「导入 FCP」集成检查需要本机安装 Final Cut Pro。

本工具在本机处理文件。页脚的作者链接使用系统浏览器或邮件应用打开。点阵字形来源见 [第三方素材声明](THIRD_PARTY_NOTICES.md)。
