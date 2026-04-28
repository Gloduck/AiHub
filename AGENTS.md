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
+ 正常情况下不允许直接读取 `env.ini` 文件获取环境变量；如需加载其中的环境变量，只能通过 `${AiHub Path}/script/load_env.sh` 或 `${AiHub Path}/script/load_env.bat` 完成，并且在加载环境变量后，也尽量不要打印获取环境变量的内容，避免泄露敏感信息。对于有些脚本，如果支持使用环境变量作为参数，也可以优先尝试通过这两个脚本来加载环境变量。
+ 对需要 `source` 或 `call` 的脚本，执行时必须使用正确方式，不能用错误解释器直接运行
