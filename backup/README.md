# 备份目录示例结构

此目录包含 Docker 容器备份的元数据文件示例。

**重要安全提示**: 备份目录可能包含敏感信息，包括：

- 环境变量和密码
- 容器配置信息
- 网络配置
- 挂载信息

## 目录结构

```text
backup/
├── YYYYMMDD_HHMMSS/          # 备份时间戳命名的目录
│   └── meta/                 # 元数据目录
│       ├── container_config.json  # 容器配置 (可能含敏感信息)
│       ├── env.list          # 环境变量 (通常含密码等敏感数据)
│       ├── extra_hosts.txt   # 主机映射
│       ├── mounts.txt        # 挂载信息
│       ├── networks.txt      # 网络配置
│       └── ports.txt         # 端口映射
└── README.md                 # 此文件
```

## 安全建议

1. **永远不要将备份目录提交到版本控制系统**
2. **在分享代码前请检查并清理敏感信息**
3. **使用 .gitignore 确保备份目录被忽略**
4. **定期清理旧的备份文件**

## 示例环境变量文件清理

原始文件可能包含：

```env
ADMIN_PASSWORD=实际密码
JWT_SECRET=真实密钥
REDIS_PASSWORD=Redis密码
```

应该创建示例文件 `env.list.example`：

```env
ADMIN_PASSWORD=your_admin_password_here
JWT_SECRET=your_jwt_secret_key_here
REDIS_PASSWORD=your_redis_password_here
```
