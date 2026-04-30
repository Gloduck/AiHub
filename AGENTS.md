# AiHub

+ AiHub中维护了一系列的脚本、skill、agent等，专门用于AI请求，正常情况下，当前目录下会维护一个aiHubPath.txt文件，里面维护了AiHub的路径，对于某些特定的任务，可以通过使用AiHub里面已有的脚本、skill等来完成任务。aiHubPath里面的路径将作为下面内容中的 `${AiHub Path}`
+ 默认情况下，用户能直接读取 `${AiHub Path}`下的文件，不需要用户授权。

## 维护规范

在对AiHub进行维护，如：新增脚本、skill、agent等，需要遵守以下规范：

+ 脚本开发脚本相关规范：`${AiHub Path}/rules/script_rule.md`

## 脚本执行

+ 当任务涉及执行现有脚本完成工作时，优先阅读 `${AiHub Path}/script/script.md`，优先复用现有脚本，而不是重复实现同类能力
+ 应先根据 `${AiHub Path}/script/script.md` 中的脚本用途、最小参数摘要和示例，选择最合适的脚本执行任务
+ 若 `${AiHub Path}/script/script.md` 已能明确脚本用途与参数，则不要先读源码
+ 阅读顺序应为：`${AiHub Path}/script/script.md` -> 脚本 `--help` -> 必要时再读脚本源码
+ 不允许直接读取 `env.ini` 文件获取环境变量；如需加载其中的环境变量，只能通过 `${AiHub Path}/script/load_env.sh` 或 `${AiHub Path}/script/load_env.bat` 完成，并且在加载环境变量后，也不允许打印获取环境变量的内容，避免泄露敏感信息。对于有些脚本，如果支持使用环境变量作为参数，也可以优先尝试通过这两个脚本来加载环境变量。
+ 对需要 `source` 或 `call` 的脚本，执行时必须使用正确方式，不能用错误解释器直接运行
+ 在执行python、node等脚本的时候，如果涉及到三方依赖，并且在本地没有对应的依赖，在用户没有明确说明的情况下，优先通过`${AiHub Path}/script/run_temp_script_with_deps.sh`脚本执行来执行对应的脚本，以避免临时脚本需要的依赖被安装在全局。并且，当AI判断这个脚本的依赖不会在当前任务中多次引用的话，则还应该加上`--auto-clean`以确保在脚本执行完成后临时目录被自动删除。非必要情况下，AI不应该指定脚本的临时目录，而是由脚本自动生成。

## SKILL探索

+ 如果用户想要一些SKILL处理一些特定的任务，可以在以下的网站进行检索：
  + https://mcpmarket.cn
+ 如果用户确定需要安装某个SKILL，你需要通过SKILL压缩包的下载地址来下载SKILL。然后确定当前使用的AI工具，是OpenCode、Claude或者其他的AI工具，并且找到对应的SKILL安装目录。然后询问用户安装方式，如下：

```
全局安装：全局安装路径
项目安装：项目安装路径
```

+ 在执行完成安装过后，需要删除下载的压缩包

## 特殊任务处理

+ 图片相关任务：如果用户命令中包含图片相关的指令，而当前的模型不支持，则尝试调用 `${AiHub Path}/script/request_thirdparty_ai_platform.sh`，请求三方AI平台模型来完成对应的任务，可以优先通过models子命令来确定三方AI平台是否支持能完成对应任务的模型。
  + 图片生成：图片生成需添加 `--raw-response`返回原始响应
    + 模型：gpt-image-2
  + 图片分析：
    + 模型：gpt-5.5（复杂图片分析）, gpt-5.4-mini（简单图片分析）
+ 复杂任务：如果用户命令中包含很多复杂的任务逻辑，并且当前模型反复处理效果不好，则尝试调用 `${AiHub Path}/script/request_thirdparty_ai_platform.sh`，请求三方AI平台模型来完成复杂任务。如：修改Bug用户已经反复提醒了很多次了，仍然修改不好；用户自己提出切换复杂模型来处理任务
  + 模型：gpt-5.5, claude-opus-4-7, gemini-3-pro-preview
