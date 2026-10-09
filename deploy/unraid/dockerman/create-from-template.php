<?php
// 用 dockerMan 自己的 xmlToCommand 把模板转成 docker 命令。
// 目的：在 Unraid 上按 Docker 界面完全相同的路径部署 hideck 容器，
// 生成的容器带 net.unraid.docker.managed=dockerman 标签，界面里可直接“编辑”。
// 本脚本只打印命令，不创建、不启动、不删除任何容器。
$docroot = '/usr/local/emhttp';
require_once "$docroot/plugins/dynamix.docker.manager/include/DockerClient.php";

$custom = DockerUtil::custom();
$subnet = DockerUtil::network($custom);
$driver = DockerUtil::driver($custom);
global $var;
$var['timeZone'] = $var['timeZone'] ?? 'Asia/Shanghai';
$var['NAME'] = $var['NAME'] ?? 'Tower';

$templatePath = $argv[1] ?? '';
if (!$templatePath || !is_readable($templatePath)) {
    fwrite(STDERR, "用法: php create-from-template.php <模板xml路径> [run|create]\n");
    exit(2);
}
if (simplexml_load_file($templatePath) === false) {
    fwrite(STDERR, "模板解析失败: $templatePath\n");
    exit(2);
}

// 本站 Helpers.php 的 xmlToVar 只接受模板文件路径；传 SimpleXMLElement 会得到空模板。
[$cmd, $name, $repository] = xmlToCommand($templatePath, false);
$mode = $argv[2] ?? 'create';
if ($mode === 'run') {
    $cmd = str_replace('/docker create ', '/docker run -d ', $cmd);
}
echo $cmd, "\n";
