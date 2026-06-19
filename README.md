# launch-engine-libs

各平台原生静态库的**构建工厂**——为私有源码仓 launch-master 产出 `onnxruntime` + `sherpa-onnx`
静态库（语音 ASR / 嵌入 / 视觉 需要）。

本仓 **public**，故 GitHub Actions 全免费（含 macOS、Windows ARM）。构建脚本从上游
（microsoft/onnxruntime、k2-fsa/sherpa-onnx）clone 源码编译，**不含任何专有或受版权内容**。

## 用法

1. Actions → **Build Native Libs** → Run workflow → 选 `platform`（先 `darwin-arm64` 验证整链路）。
2. 跑完在该 run 页面底部下载 artifact `native-libs-<platform>`。
3. 解压，把里面的 `deps/...` 覆盖到私有仓 `launch-master/deps/` 对应位置，提交进 launch-master。

平台 → runner：darwin-arm64=macos-14、darwin-amd64=macos-13、windows-amd64/arm64=windows-latest
（arm64 经 `amd64_arm64` 交叉编译）。

⚠️ onnxruntime 源码编译每平台 1–3 小时。先单平台验证再扩 Windows（Windows 首跑多半要按日志迭代）。

## 产物对应关系（解压后 → 提交到 launch-master）

| artifact 内路径 | 提交到 launch-master |
|---|---|
| `deps/go-onnxruntime/lib/<platform>/` | 同路径 |
| `deps/go-sherpa-asr/lib/<platform>/` | 同路径 |
| `deps/go-onnxruntime/include/`、`*_c_api.h`、`c-api.h` | 同路径（各平台一致，覆盖即可） |
