# HiDeck DockerMan 模板

将 [my-hideck.xml](my-hideck.xml) 导入 Unraid 的用户模板目录，核对配置、数据与日志路径后在 Docker 界面创建。固定镜像 `yibaiba/hideck:2.1.23`；与 Compose 二选一，不能同时占用模块。

模板使用 host 网络、特权模式和 `/dev` 透传，沿用已验证部署形态。HiDeck 的 7577 端口限制在可信局域网/反代可达范围；不直接映射公网。随行号录音和 App Key 由独立宿主服务保存，不映射到 HiDeck 容器。

`create-from-template.php` 只使用 Unraid 自带 DockerMan 库渲染命令，不启动容器。必须在 Unraid `/usr/local/emhttp` 下运行，参数为模板文件路径与 `create` 或 `run`。先渲染检查，再由维护者决定应用；不要把渲染出的实际私有路径上传。

完整部署步骤、配置与回退见 [上级说明](../README.md)。
