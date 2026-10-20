====================================
 PCL 2.99.0  原版下载功能 解锁补丁
====================================

【这是什么】

PCL 2.99.0.0 官方版移除了「下载 Minecraft」功能（release 说明：为遵守相关法律法规）。
但这个功能没有被删除代码，只是被一个编译期开关整体短路了。
本补丁把那一个方法的 IL 改回官方源码里原本的写法，从而恢复：

    下载 -> 原版游戏  ->  版本列表 / 安装原版 MC

除了这一个方法，程序其余部分逐方法完全不变。


【怎么用】

方式一（推荐）
    把本文件夹里的所有文件解压出来，双击「一键解锁.bat」。
    如果 PCL 主程序和补丁在同一目录，会自动找到它。
    找不到时，会弹出一个文件选择框，让你手动选 Plain Craft Launcher 2.exe。

方式二（最省事）
    把 "Plain Craft Launcher 2.exe" 直接拖到「一键解锁.bat」的图标上。

方式三（高级）
    在 PowerShell 里执行：
    .\unlock.ps1 -ExePath "D:\你的PCL目录\Plain Craft Launcher 2.exe"

脚本会自动完成：版本校验 -> 状态检查 -> 备份 -> 打补丁 -> 自校验 -> 替换。
全程无需手动操作，最后会打印新的 SHA256。


【备份与回滚】

打补丁前会自动把原程序备份为：
    Plain Craft Launcher 2.exe.bak

想恢复官方原版，把 .bak 文件改名回 "Plain Craft Launcher 2.exe" 覆盖即可。
重复运行补丁不会重复备份，也不会重复打补丁（会提示"已经是解锁版"）。


【注意事项】

1. 只支持 2.99.0.0。其他版本脚本会直接拒绝，不会动你的文件。
2. PCL 的自动更新会把补丁覆盖掉。更新后重新跑一次本脚本即可。
3. 只能恢复「原版游戏」。整合包安装的代码在官方版里被彻底删除了（不是开关问题），
   本补丁无法恢复，需要重写整个方法才行。
4. 部分杀毒软件可能对"被修改过的启动器"报警（因为文件哈希变了、没有数字签名）。
   加白名单即可，程序本身没有联网行为改动。
5. 运行时 PCL 必须关闭。脚本会检测，并询问是否自动关闭。


【技术细节（给好奇的人）】

限制源点（官方开源仓库 Meloong-Git/PCL）：
    Modules/ModSecret.vb:18
    Public Const RestrictMcDownload As Boolean = True

因为是 Const，编译器把所有 If RestrictMcDownload 折叠掉，
PageDownloadInstall.LoaderInit() 里只剩下一个"立即抛异常"的假 LoaderTask，
真实分支（调用 DlClientListLoader）被当成死代码删除。

但下载引擎本身完好：PCL.ModDownload::DlClientListLoader 这个静态字段
（在 .cctor 里 New LoaderTask(...) 初始化）一直都在。

补丁做的事：
把构造假 LoaderTask 的 13 条 IL 指令，整段替换成一条
    ldsfld PCL.ModDownload::DlClientListLoader
等价于恢复到源码里原本的：
    PageLoaderInit(LoadMinecraft, PanLoad, PanAllBack, Nothing,
                   DlClientListLoader, AddressOf LoadMinecraft_OnFinish)

栈平衡：被删区间净效应 +1，ldsfld 净效应 +1，衔接点完全一致。

验证过的结果（A/B 对照）：
    补丁版：DlClientListLoader -> Loading -> Finished，界面渲染出真实版本号
    原版  ：假 LoaderTask -> Failed，界面显示"为遵守相关法律法规……"


【文件清单】

    一键解锁.bat        双击入口
    unlock.ps1          主控脚本（定位/校验/备份/替换）
    apply_patch.ps1     IL 补丁核心（含 7 项自校验，可单独跑）
    Mono.Cecil.dll      IL 读写库（0.11.5）
    使用说明.txt        本文件

需要 Windows + PowerShell 5.1（Win10/11 自带）。
