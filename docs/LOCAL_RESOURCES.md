# 本地资源与运行

Git 仓库保存核心代码和小型渲染配置，不包含完整场景资产。只克隆仓库会缺少模型、贴图、环境帧图、音频、地图数据和碰撞资源，不能直接进入完整地图。

## 恢复运行环境

1. 使用与本代码版本配套的本地 `project/assets/` 目录，保持所有子目录和文件名。`local-assets-manifest.json` 记录首次代码提交时的相对路径、大小及 SHA256，用来识别配套版本；清单本身不包含资源内容。
2. 使用 Godot 4.7.2 标准单精度 Windows 桌面版，将 `Godot_v4.7.2-stable_win64.exe` 与 `Godot_v4.7.2-stable_win64_console.exe` 放入 `tools/godot/`。也可用同版本编辑器直接导入 `project/project.godot`。
3. 双击根目录的 Godot 试玩入口。首次运行会重新导入资源，`.godot/` 缓存不需要从原电脑复制。默认渲染器为 Forward+。

Godot 试玩不需要启动原 UE EXE。根目录的两个原版对照入口、原版观景存档和安装包均不在此代码仓库。

## 保留在本地的内容

| 路径 | 用途 |
|---|---|
| `project/assets/` | 实际地图及运行资源 |
| `project/source/` | Blender 制作源文件与历史自动备份；Godot 试玩不直接读取 |
| `artifacts/` | 提取资料、原版对照入口、截图录像、历史验证与报告 |
| `workbench/` | 制作工作区和候选实验 |
| `migration/` | 迁移前快照及操作核验 |
| `tools/godot/`、`tools/extraction/` | 本机引擎与提取工具 |

Blender 源文件依赖本地 `artifacts/wandering-full-scene-study-20261123/exports-textured/` 中的 66 张贴图。需要模型编辑时应同时保存源文件与这些贴图；Git 核心代码提交不包含这条制作资源链。几何制作继续遵循 Blender MCP 约定。

渲染模块中的小型 `.bin`、`.res`、`.bgra8`、`.rgba16f` 与 JSON 配置属于对应代码的运行输入，已随核心代码保留，不要按扩展名全局删除。`*_candidate` 中多个目录也已进入默认渲染路径。

诊断与启动日志写入本地被忽略的 `artifacts/`。历史研究报告未上传，根 `AGENTS.md` 中相关路径只在完整本地工作区可用。
