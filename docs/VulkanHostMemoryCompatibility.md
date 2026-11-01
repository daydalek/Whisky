# 32 位 Vulkan 内存导入兼容

Bottle 图形设置中的“32 位 Vulkan 内存导入兼容”写入
`graphicsConfig.shadowImportedHostMemory`，默认关闭。开启后，启动环境增加
`MVK_CONFIG_SHADOW_IMPORTED_HOST_MEMORY=1`。旧元数据自动采用关闭的默认值。
GPUI 通过共享配置 schema 显示此项，SwiftUI 入口同步接入。

适用情形为 Vulkan / DXVK 导入宿主内存时发生黑屏、Metal 命令执行失败和设备丢失。
MoltenVK 将导入内存映射至额外的 Metal 缓冲区，并在提交等操作中同步数据；
额外复制带来性能开销，因此按 Bottle 选择启用。运行库需要包含 shadow-import 补丁。
Steam 及游戏应完整退出后重新启动，以继承新的启动环境。
自定义程序环境变量依照现有环境优先级规则覆盖 Bottle 管理值。

## 旧“32 位 Vulkan 内存导入优化”开关的评估

旧字段 `graphicsConfig.hostMemoryImport` 默认开启；关闭时传入
`MVK_CONFIG_EXTERNAL_MEMORY_HOST=0`。该变量来自 Whisky 早期自定义的
`patches/moltenvk/0001-mvk-config-external-memory-host.patch`，作用是隐藏
`VK_EXT_external_memory_host` 扩展，使 Wine 选择其它映射路径。

当前 ge-proton-macos-wine-poc 的 shadow-import 构建脚本引入 shadow-import 补丁。
2026-10-31 检查本机已安装 dylib，发现 shadow-import 配置字符串；旧变量的配置
字符串缺失。旧界面选项在当前运行库中的有效性因而缺乏支持，应退出日常设置界面。
旧字段的序列化和启动环境逻辑继续保留，为旧运行库、既有 Bottle 和回滚提供兼容。
新开关保持独立字段与默认值；旧开关的历史选择继续按原值保存。

两种机制的关系：旧开关控制是否允许宿主内存导入，新开关控制导入后的 Metal
缓冲实现。支持旧变量的运行库关闭导入后，shadow-import 的适用前提随之消失。
当前运行库优先验证“内存导入兼容”开关。

本机 Aokana 对照日志位于 ge-proton-macos-wine-poc 的
`outputs/aokana-investigation-20261031`：开启 shadow-import 后记录了 1066 次
Vulkan 画面提交和零次设备丢失。具体画面内容及主菜单交互仍需用户验收。

## 自动验证

- WhiskyCore ConfigurationFileTests：平台过滤、默认关闭、写入读回、保留旧字段。
- WhiskyKit EnvironmentVariablesTests：旧元数据解码、序列化往返及环境变量生成。
- GPUI config 测试：图形分组、布尔控件类型及 macOS 平台过滤。
