# VPS SSH 登录钉钉安全提醒（私人仓库版）

适用于 **Debian / Ubuntu + OpenSSH + PAM**。通过 SSH 成功打开会话时，异步发送钉钉群机器人通知：服务器、登录账号、来源 IP、地理归属、运营商 / ASN、可信 IP 白名单判断、北京时间。

> **告警≠入侵结论**：标记为“陌生公网 IP”仅表示来源**不在手工白名单**；白名单 IP 也不保证登录者就是本人。工具只告警，不会封禁地址、修改 SSH 认证策略或替代 fail2ban、审计日志。

## 部署（通过 ZeeTerm 操作）

1. 在你自己登录 GitHub 后，从**私人仓库**下载 `install-ssh-dingtalk.sh` 到电脑；不要使用公开 `raw.githubusercontent.com/...` 一键安装，因为私人仓库不会提供无认证的公开链接。
2. 用 ZeeTerm 文件传输功能，将脚本上传到 VPS 的 `/tmp/install-ssh-dingtalk.sh`。
3. 保留当前 SSH 会话，在该 VPS 执行：

   ```bash
   sudo bash /tmp/install-ssh-dingtalk.sh
   ```

4. 按提示输入 Webhook（隐藏输入，不留在 Shell 历史）、加签密钥（如果机器人启用加签）、自定义关键词、服务器名称与**一个你明确知道属于自己的常用 IP**（可以跳过，之后再添加）。脚本会测试钉钉发送。
5. 保留原窗口，在 ZeeTerm 新建一个 SSH 会话，观察真实登录通知。

该脚本**不需 pip**、不需重启 SSH；只在 `/etc/pam.d/sshd` 添加一条可选 PAM `open_session` 钩子。若钉钉或归属地 API 失联，不会因为告警发送失败而拒绝登录。首次安装会对 PAM 文件备份，再次安装不重复添加钩子。仅在 SSH 启用 `UsePAM yes` 时可用。

## 管理常用 IP

> 下列 `203.0.113.10` 是文档示例地址，**请替换为你自己的实际 SSH 来源 IP**。未知 IP 不能自动加入白名单，尤其不能自动相信“首次 SSH 登录来源”。

```bash
# 查看白名单
sudo python3 /usr/local/sbin/ssh-login-dingtalk.py trust list

# 将确认为自己使用的固定出口 IP 加白（更推荐单个 IP /32 或 /128）
sudo python3 /usr/local/sbin/ssh-login-dingtalk.py trust add 203.0.113.10 '公司网络'

# Tailscale IPv4 也可以加白，但默认并不自动信任 Tailscale 网段
sudo python3 /usr/local/sbin/ssh-login-dingtalk.py trust add 100.88.208.14 '我的 Tailscale'

# 验证某 IP 是否匹配白名单
sudo python3 /usr/local/sbin/ssh-login-dingtalk.py trust check 203.0.113.10

# 移除旧 IP
sudo python3 /usr/local/sbin/ssh-login-dingtalk.py trust remove 203.0.113.10
```

允许 CIDR 网段，但不建议为动态家庭公网 IP 加过宽的 `/24` 白名单。存在 NAT、代理、VPN、跳板机时，**来源 IP 表示服务器看到的连接出口**，不一定能对应到真实设备。归属地通常也只能近似定位，不能精确定位个人位置。

## 日志与测试

```bash
sudo python3 /usr/local/sbin/ssh-login-dingtalk.py test
sudo journalctl -t ssh-login-dingtalk -n 30 --no-pager
```

安装后文件：

- `/usr/local/sbin/ssh-login-dingtalk.py`：发送器 + 白名单管理；root 所有。
- `/usr/local/sbin/ssh-login-dingtalk-hook.sh`：PAM 异步触发器。
- `/etc/ssh-login-dingtalk.json`：**本机机密文件（权限 0600）**，包含 Webhook、加签密钥、服务器名称、可信 IP 白名单。**绝不上传到 GitHub**。
- `/var/cache/ssh-login-dingtalk/`：公网 IP 归属地缓存（24 小时、仅 root 访问），减少 API 请求。
- `/var/backups/ssh-login-dingtalk/`：原 PAM 配置与旧安装脚本的本地备份，仅 root 访问。

## IP 归属地查询与隐私

默认仅对**公网 IP**使用 `https://ipwho.is/{IP}` 做 HTTPS 查询，读取国家、地区、城市、运营商、ASN；免费接口可能限流、超时、归属地出错，也不提供免费的威胁信誉评分。查询失败时仍发送 SSH 登录通知。查询会将来源公网 IP 传给第三方服务。如不希望发送此信息：

```bash
sudo python3 /usr/local/sbin/ssh-login-dingtalk.py geo off
# 需要再次开启：... geo on
```

Tailscale / 私网 / 保留地址不会调用公网 IP 归属地查询；也**不会自动加入白名单**。

## 中文服务器名与终端编码（2026-11-23 修复）

如果旧版安装器在填写中文服务器名称后报 `UnicodeEncodeError: surrogates not allowed`，这是 SSH 客户端输入字节编码和 Python UTF-8 保存不匹配。最新版安装器会检测并尝试恢复 GBK/GB18030 输入；仍建议将 ZeeTerm SSH 终端字符集设为 UTF-8。**必须重新上传新版 `install-ssh-dingtalk.sh` 覆盖 VPS 上 `/tmp/install-ssh-dingtalk.sh` 再执行**，仅重复执行旧文件无效。遇到不可识别的编码时，安装会停止并给出中文提示，不会将异常字符保存到配置。

安装器会先保存配置，成功后才插入 SSH PAM 钩子，所以旧版配置保存失败不会修改 SSH 登录行为。WebHook 与加签密钥仍按原步骤输入，不要在聊天中公开。

## 更新与卸载

保留本机凭据、IP 白名单情况下重复运行最新版安装器即可。强制重新输入机器人信息（仍保留原可信 IP）：

```bash
sudo bash /tmp/install-ssh-dingtalk.sh --reconfigure
```

停用并移除 PAM 触发器（**保留**本机密钥、可信 IP）：

```bash
sudo bash /tmp/install-ssh-dingtalk.sh --uninstall
```

钉钉群机器人对消息发送有频率限制（通常每分钟 20 条）；此工具对每次真实 SSH 会话打开都尝试发送，没有隐式合并，因此高频登录时可能遇到钉钉限流。`sshd` 的 SFTP/SCP 会话也可能触发 `open_session`。3X-UI **网页后台登录**不在这个工具的监控范围内。**登录失败**也不会触发此版本通知。

## GitHub 私人仓库安全建议

- 必须是个人账号下的 **Private** 仓库，并且没有额外的 Collaborators。
- 检查 `Settings → Collaborators`；GitHub App / OAuth 第三方应用可能另有授权访问，请检查自己授予过的仓库权限。
- Webhook / 加签密钥、真实 IP 白名单、任何服务器凭据或 SSH 私钥都不应进入代码仓库，**即使是私人仓库**。
- 本仓库仅包含安装器、说明文档及离线单元测试。可运行 `python3 -m unittest discover -s tests -v` 做离线功能检查。

## 创建独立私人 GitHub 仓库

1. 登录自己的 GitHub 账号 `jiaxinzi1212`，打开 https://github.com/new。
2. Repository name 填 `vps-ssh-security-alert`；**Owner 选择你的个人账户**，Visibility 选择 **Private**；勾选初始化 README（便于后续通过 GitHub 连接器上传文件），点击 Create repository。
3. 确认地址栏的仓库属于你本人且有 Private 标记。在 **Settings → Collaborators** 检查没有邀请其他用户。若 ChatGPT 的 GitHub 连接器看不到新仓库，需要到 GitHub 安装的应用权限中，将该仓库授权给连接器，上传完成后可撤销。
4. 上传本安装器与 README、.gitignore、测试代码。**不要**上传 `/etc/ssh-login-dingtalk.json`、真实可信 IP、SSH 密钥及任何 Webhook。

私人 GitHub 仓库默认只有获授权的人和应用能访问；你未邀请其他协作者并不代表 GitHub 平台及获授权的第三方应用不能接触内容。