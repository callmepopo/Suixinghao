# Linux VPS 推送中继

这是发布者部署入口，不需要 HiDeck、模块驱动、音频设备或 Apple 私钥之外的第三方 SDK。当前部署状态与验收见 [推送中继](../../docs/push-relay.md)。

先通过 `server/build.sh --require-clean` 构建冻结的 Linux amd64 产物，保留其 source.json。将二进制作为 voice-web 与可信系统 CA 证书合集 ca-certificates.crt 放进独立构建上下文，复制本目录 Dockerfile 构建镜像。不要把源码工作区、env 或私钥作为 Docker 构建上下文。

运行时使用独立 Docker 网络、不映射宿主端口，由已有 HTTPS 反代接入该网络。设置只读根文件系统、no-new-privileges、cap-drop ALL、内存/CPU/PID 限制及自动重启。私有数据目录归 UID/GID 65532、权限 0700，挂载 /data；私钥只读挂载 /run/secrets/apns.p8，权限 0600 且运行用户可读。配置采用 [发布者示例](../unraid/examples/publisher-relay.env.example)，容器内监听 0.0.0.0:7582，数据目录 /data。运行目录、授权及密钥不得映射为网站静态文件。

反代只开放 /push-relay/，其余路径返回 404；使用有效 HTTPS 证书，限制请求体为 1 KiB、来源请求速率和连接数，关闭访问日志及敏感错误日志。先备份当前反代配置，通过 nginx -t 后平滑重载，不重启无关服务。独立域名首次上线先验证真实 TLS，再添加 DNS；未验证 IPv6 时只发布 A 记录。

使用同一镜像、数据目录和运行用户串行执行 relay-issue/relay-revoke 管理后端授权，详情见接口文档。production 和 sandbox 使用独立进程、授权和 Apple 密钥；Production 密钥不能给 Debug/sandbox 包推送。

上线验证必须区分：容器健康、公开 HTTPS、拒绝未授权请求、授权隔离与撤销、Apple 实发、真机锁屏、短信和 TestFlight。健康接口不发送通知，不能证明手机会响。

回退：先停用新增 DNS/反代入口并通过 nginx -t 后重载，再停止独立中继容器；保留私有授权和原始备份。恢复旧镜像时沿用当前数据，不回退客户后续授权。不中断其他站点，不回滚用户的模块或电话服务。
