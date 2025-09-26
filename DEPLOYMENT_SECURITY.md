# 部署安全指南

## 📋 概述

本项目包含安全配置文件，用于防止敏感信息（如密码、API 密钥等）被意外提交到版本控制系统。

## 🔐 敏感信息处理

### 已移除的文件

以下文件已从 Git 历史记录中完全移除，因为它们包含硬编码的敏感信息：

- `deploy-local.sh` - 包含 Redis 密码和管理员密码
- `docker-compose.local.yml` - 包含 Redis 连接密码

### 安全的配置文件

现在使用以下安全的示例文件：

- ✅ `deploy-local.sh.example` - 使用环境变量的部署脚本模板
- ✅ `docker-compose.local.yml.example` - 使用环境变量的 Docker Compose 配置模板

## 🚀 本地部署设置

### 步骤 1: 复制配置文件

```bash
# 复制部署脚本
cp deploy-local.sh.example deploy-local.sh

# 复制 Docker Compose 配置
cp docker-compose.local.yml.example docker-compose.local.yml
```

### 步骤 2: 设置环境变量

创建 `.env` 文件（已在 .gitignore 中排除）：

```bash
# Redis 配置
REDIS_PASSWORD=your_secure_redis_password_here

# 管理员配置
ADMIN_PASSWORD=your_secure_admin_password_here
```

### 步骤 3: 修改配置文件

编辑复制的文件，将环境变量占位符替换为实际值，或确保环境变量已正确设置。

## ⚠️ 安全注意事项

### 重要提醒

- 🚫 **永远不要**将包含真实密码的配置文件提交到 Git
- ✅ **始终使用**环境变量或安全的配置管理工具
- 📝 **定期更换**生产环境密码
- 🔍 **定期检查** `.gitignore` 确保敏感文件被正确排除

### 被忽略的文件类型

以下文件类型已在 `.gitignore` 中配置，不会被提交：

```gitignore
# 本地部署文件
deploy-local.sh
docker-compose.local.yml

# 环境变量文件
.env
.env.*
!.env.example

# 备份文件
backup/
*.backup*
```

## 🔄 更新现有部署

如果您已经有本地部署运行：

1. 停止所有服务
2. 按照上述步骤重新配置
3. 使用新的安全配置重新启动服务

## 📞 支持

如果您在设置过程中遇到问题，请：

1. 检查环境变量是否正确设置
2. 确认文件权限正确
3. 查看应用日志以获取详细错误信息

---

**记住：安全配置不仅保护您的应用，也保护您的用户数据。始终优先考虑安全最佳实践。**
