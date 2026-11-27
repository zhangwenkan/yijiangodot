# 逸剑 Godot 核心代码

无名岛与游仙村的 Godot 场景复原代码，包含场景装配、角色行走、碰撞与导航适配、环境动画、房屋状态、材质、Shader、灯光和后期渲染。

**本仓库只保存核心代码和小型运行配置，不包含完整模型、贴图、音频、Blender 源文件或分析资料。克隆后需要补齐配套资源才能运行完整地图。** 资产准备见 [本地资源说明](docs/LOCAL_RESOURCES.md)，版本清单见 [资源清单](docs/local-assets-manifest.json)。完整本地工作区位于 `F:/逸剑godot`，与《孤屿霜尘》工程分离。

## 代码结构

- `project/project.godot`、`project/worlds.tscn`：项目和场景入口。
- `project/scripts/`：地图装配、角色、碰撞、导航、动态环境、状态及验证脚本。
- `project/shaders/`：场景材质和基础 Shader。
- `project/*_candidate/`：渲染模块及小型参数数据。多个目录已被默认路径使用，保留其原名称以避免破坏引用。
- `tools/launch_godot_world.ps1`：独立启动器，自动检查和导入本地资源。
- `AGENTS.md`：制作约束、当前状态与尚未复原的差异。

## 本地运行

使用 Godot **4.7.2 标准单精度桌面版、Forward+**。资源补齐后：

- `试玩Godot无名岛.cmd` / `试玩Godot游仙村.cmd`：进入对应 Godot 地图。
- `打开Godot工程.cmd`：打开编辑器。
- `原图布局校对.cmd`：自由观察入口。

WASD／方向键行走，F 自由观察，Home 回码头，Tab 隐藏界面。引擎需放入 `tools/godot/`；也可用同版本编辑器直接打开 `project/project.godot`。启动日志保存在本地 `artifacts/wandering-original-worlds-review/launch-logs/`。

## Git 范围

`.gitignore` 排除 `artifacts/`、`workbench/`、`migration/`、运行大资产、Blender 源文件、引擎程序和 `.godot/` 缓存。它只控制提交范围，不删除本地文件。脚本 `.uid`、Shader 导入设置、相关第三方许可证和代码所需的小型配置均保留。

本次核心代码提交不需要 Git LFS。后续如果决定把模型、贴图和音频纳入版本管理，应单独确定资产范围与存储方式。

## 当前状态

当前可在完整本地工作区试玩两张地图，但尚未达到一比一复原或美术验收。原 TLV 与阴影、反射卷积、透明景深、原细分与部分顶点属性、剧情与动物行为、全图通行和长期性能仍有缺口。

2026-11-26 新增原动物部分路径处理并修正游仙村门口短暂下陷。验证范围和保留问题见 [本轮进展](docs/RESTORATION_PROGRESS_20261126.md)。

2026-11-27 修正两图地形权重导入数据，复核脚步选材并刷新天空漫反射/反射缓存；游仙村地形受光漂移仍在定位。验证结果与诊断边界见 [地形专项进展](docs/LANDSCAPE_PROGRESS_20261127.md)。

数据分析基于用户本地发行版的 cooked 资源、编译 Shader 与原生程序，不是原游戏的开发工程源码。现有第三方代码的许可证保留在对应模块内。
