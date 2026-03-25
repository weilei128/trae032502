@echo off
setlocal enabledelayedexpansion

set "server=49.235.161.106"
set "sshUser=root"
set "remoteDir=/opt/apps/dogFooding-app"
set "localJar=target/dogFooding.jar"
set "localDockerfile=dogFooding_Dockerfile"
set "imageName=dogFooding-app:1.0.0"
set "containerName=dogFooding-app"
set "port=10011"

echo === 开始部署 dogFooding-app ===
echo.

echo [1/8] 检查本地文件...
if not exist "%localJar%" (
    echo 错误: %localJar% 不存在！
    exit /b 1
)
if not exist "%localDockerfile%" (
    echo 错误: %localDockerfile% 不存在！
    exit /b 1
)
echo 本地文件检查完成
echo.

echo [2/8] 测试服务器连接...
ssh -o BatchMode=yes -o ConnectTimeout=10 %sshUser%@%server% "echo '连接成功'" 2>nul
if errorlevel 1 (
    echo 错误: 无法连接到服务器 %server%，请检查SSH密钥配置
    exit /b 1
)
echo 服务器连接成功
echo.

echo [3/8] 服务器前置检查...
echo 检查Docker运行状态...
for /f "delims=" %%a in ('ssh %sshUser%@%server% "systemctl is-active docker 2>/dev/null || echo 'not-running'"') do set "dockerStatus=%%a"
if not "%dockerStatus%"=="active" (
    echo 错误: Docker 未在服务器上运行！状态: %dockerStatus%
    exit /b 1
)
echo Docker 运行状态: 正常

echo 创建/检查目录权限...
ssh %sshUser%@%server% "mkdir -p %remoteDir% && chown -R root:root %remoteDir% && chmod 755 %remoteDir%"
echo 目录权限检查/修复完成

echo 检查端口%port%占用...
for /f "delims=" %%a in ('ssh %sshUser%@%server% "lsof -i :%port% -t 2>/dev/null | head -1"') do set "portInfo=%%a"
if not "!portInfo!"=="" (
    echo 端口 %port% 被占用，检查是否为容器进程...
    for /f "delims=" %%a in ('ssh %sshUser%@%server% "docker ps -q --filter ""publish=%port%"" 2>/dev/null"') do set "containerCheck=%%a"
    if not "!containerCheck!"=="" (
        echo 端口 %port% 被容器占用，准备停止并删除容器...
        ssh %sshUser%@%server% "docker stop %containerName% 2>/dev/null; docker rm %containerName% 2>/dev/null"
        echo 容器已停止并删除
    ) else (
        echo 错误: 端口 %port% 被非容器进程占用！PID: !portInfo!
        exit /b 1
    )
) else (
    echo 端口 %port% 检查: 可用
)
echo.

echo [4/8] 清理旧文件并上传...
ssh %sshUser%@%server% "rm -rf %remoteDir%/dogFooding.jar %remoteDir%/dogFooding_Dockerfile"
echo 旧文件已清理

echo 上传文件...
scp "%localJar%" %sshUser%@%server%:%remoteDir%/
if errorlevel 1 (
    echo 错误: 上传 jar 文件失败！
    exit /b 1
)
scp "%localDockerfile%" %sshUser%@%server%:%remoteDir%/
if errorlevel 1 (
    echo 错误: 上传 Dockerfile 文件失败！
    exit /b 1
)
echo 文件上传完成
echo.

echo [5/8] 清理旧容器和镜像...
ssh %sshUser%@%server% "docker stop %containerName% 2>/dev/null; docker rm %containerName% 2>/dev/null; docker rmi %imageName% 2>/dev/null; echo '清理完成'"
echo 旧容器和镜像清理尝试完成
echo.

echo [6/8] 构建Docker镜像...
ssh %sshUser%@%server% "cd %remoteDir% && docker build -f dogFooding_Dockerfile -t %imageName% ."
if errorlevel 1 (
    echo 错误: Docker镜像构建失败！
    exit /b 1
)
echo 镜像构建成功
echo.

echo [7/8] 启动容器...
ssh %sshUser%@%server% "docker run -d --name %containerName% --restart=always --memory=512m --cpus=0.5 -p %port%:%port% %imageName%"
if errorlevel 1 (
    echo 错误: 容器启动失败！
    exit /b 1
)
echo 容器启动命令已执行
echo.

echo [8/8] 验证服务状态...
echo 等待15秒让服务启动...
timeout /t 15 /nobreak >nul

for /f "delims=" %%a in ('ssh %sshUser%@%server% "curl -s -o /dev/null -w '%%{http_code}' http://127.0.0.1:%port% 2>/dev/null || echo '000'"') do set "response=%%a"
if "%response%"=="200" (
    echo.
    echo === 部署成功 ===
    echo 访问地址: http://%server%:%port%
    echo 状态码: %response%
    exit /b 0
) else (
    echo.
    echo === 部署失败 ===
    echo 状态码: %response%
    echo.
    echo 容器日志:
    ssh %sshUser%@%server% "docker logs --tail 50 %containerName% 2>&1"
    exit /b 1
)
